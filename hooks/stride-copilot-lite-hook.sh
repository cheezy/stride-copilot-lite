#!/usr/bin/env bash
# stride-copilot-lite-hook.sh — Bridges harness hooks to stride-copilot-lite .stride_lite.md hook execution.
#
# Called by the harness's PreToolUse/PostToolUse hooks (configured in hooks.json).
# Receives the hook JSON on stdin, determines whether the tool call is one of the
# three stride-copilot-lite trigger conditions, and if so executes the corresponding
# `## before_task` / `## after_task` / `## after_goal` section from .stride_lite.md.
#
# Trigger conditions:
#   pre  + (Edit|edit|Write|create) + file_path ~ */.stride/lite-boundary + body contains
#                             "stride-lite-boundary:before_task" → before_task (blocking)
#                             "stride-lite-boundary:after_task"  → after_task  (blocking)
#   pre  + Agent + subagent_type == "stride-copilot-lite:task-explorer" → before_task  (blocking)
#   pre  + Agent + subagent_type == "stride-copilot-lite:task-reviewer" → after_task   (blocking)
#   post + (Edit|edit|Write|create) + file_path ~ */goal.md + body contains
#                                                 "## Completion Summary"  → after_goal  (advisory)
#
# The boundary-marker route is the RUNTIME-NATIVE intercept (W2021). Copilot CLI emits no
# skill/agent dispatch event (see stride-copilot/docs/HOOK_RESEARCH.md), so before_task and
# after_task cannot key on one. Instead the workflow skill writes a one-line marker file at
# each task boundary and the write itself is the interceptable event — a tool call Copilot
# DOES emit. Routing requires BOTH the exact marker path AND the exact boundary token, so a
# write to some other path, or a marker carrying neither token, fires nothing.
#
# The Agent route is retained unchanged for Claude Code. To keep each boundary firing exactly
# once on a runtime that emits both events, the marker route records the boundary it fired in
# .stride/lite-boundary-fired and the Agent route consumes that record instead of re-firing.
# A pre-W2021 workflow skill writes no marker, leaves no record, and so still fires via Agent.
#
# Harness compatibility:
#   - Claude Code (PascalCase tool names: Agent, Edit, Write; stdin field "tool_name").
#   - GitHub Copilot CLI (lowercase tool names: edit, create; stdin field "toolName"; toolArgs
#     is a JSON-encoded string — substring-based field extraction still locates "file_path",
#     the boundary token and "## Completion Summary" inside the encoded args).
#
# Usage: echo '<hook-json>' | stride-copilot-lite-hook.sh <pre|post>
#
# Exit codes:
#   0 — success, no-op, or non-trigger
#   2 — blocking PreToolUse failure (only meaningful for pre + before_task/after_task)
#
# Blocking contract (dual-runtime). Claude Code blocks a PreToolUse tool call on exit 2.
# Copilot CLI ignores exit codes and blocks on a stdout {"permissionDecision":"deny"} object.
# A blocking failure therefore emits BOTH: the permissionDecision keys are added to the same
# single-line failure JSON this script already emits (Copilot reads them; every other consumer
# ignores the extra keys) AND the process exits 2. Emitting only one of the two would let a
# failing before_task stop the workflow on one runtime while the other silently continued.
#
# Cross-platform parity contract: this script and stride-copilot-lite-hook.ps1 MUST detect
# the same three trigger conditions, produce equivalent single-line JSON results
# for the same input, and apply the same exit-code contract.

set -uo pipefail

PHASE="${1:-}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
STRIDE_LITE_MD="$PROJECT_DIR/.stride_lite.md"

# Boundary-marker route (W2021). The marker path is plugin-owned and fixed; the
# fired-record is transient session state. Both live under .stride/, which the
# plugin's .gitignore already excludes.
BOUNDARY_FIRED_FILE="$PROJECT_DIR/.stride/lite-boundary-fired"

# --- Platform detection: delegate to PowerShell on native Windows ---
# Git Bash (OSTYPE=msys*) and WSL have full bash — run directly.
# Native Windows without bash (COMSPEC set, no OSTYPE) → delegate to .ps1
_delegate_to_ps1=false
if [ -z "${OSTYPE:-}" ] && [ -n "${COMSPEC:-}" ]; then
  _delegate_to_ps1=true
fi

if [ "$_delegate_to_ps1" = "true" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  PS1_SCRIPT="$SCRIPT_DIR/stride-copilot-lite-hook.ps1"
  if [ ! -f "$PS1_SCRIPT" ]; then
    echo "stride-copilot-lite-hook.sh: Windows detected but stride-copilot-lite-hook.ps1 not found at $PS1_SCRIPT" >&2
    exit 2
  fi
  if ! command -v powershell.exe > /dev/null 2>&1; then
    echo "stride-copilot-lite-hook.sh: Windows detected but powershell.exe not found in PATH" >&2
    exit 2
  fi
  exec powershell.exe -ExecutionPolicy Bypass -File "$PS1_SCRIPT" "$PHASE"
fi

# --- Pure-bash JSON value extractor (no jq dependency) ---
# Extracts the first string value for the given key. Handles whitespace between
# colon and value, but does NOT handle escaped quotes inside values — fine for
# our use (tool_name, subagent_type, file_path are all simple identifiers/paths).
# Empty on miss.
_extract_string() {
  local key="$1"
  local input="$2"
  local tmp="${input#*\"$key\"}"
  if [ "$tmp" = "$input" ]; then
    printf ''
    return
  fi
  tmp="${tmp#*:}"
  tmp="${tmp#"${tmp%%[![:space:]]*}"}"
  case "$tmp" in
    \"*)
      tmp="${tmp#\"}"
      # Stop at first unescaped quote — for our keys this is sufficient.
      printf '%s' "${tmp%%\"*}"
      ;;
    *)
      printf ''
      ;;
  esac
}

# --- Unescaped view of the payload, for Copilot CLI's encoded toolArgs ---
# Copilot delivers tool arguments as a JSON-ENCODED STRING, so the fields inside
# arrive escaped: \"file_path\":\"...\". _extract_string looks for a real quote,
# finds the backslash, and returns empty — which is why every Copilot payload
# silently routed to nothing before W2021 (after_goal included, despite the docs
# claiming otherwise). One flat unescaped copy is cheaper than teaching the
# extractor two grammars, and the Claude Code path still matches on the raw pass.
_unescape_json_string() {
  local _s="$1"
  printf '%s' "${_s//\\\"/\"}"
}

# Extract a key from the raw payload, falling back to the unescaped view.
_extract_string_any() {
  local _key="$1" _raw="$2" _unesc="${3:-}" _v
  _v=$(_extract_string "$_key" "$_raw")
  if [ -z "$_v" ] && [ -n "$_unesc" ]; then
    _v=$(_extract_string "$_key" "$_unesc")
  fi
  printf '%s' "$_v"
}

# --- JSON string escape (no jq) ---
# Escapes backslash, double quote, and common control chars. Sufficient for
# emitting command strings, exit messages, and stdout/stderr tails.
_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# --- JSON array builder from a newline-delimited list ---
# Reads stdin one line per element, emits a compact JSON array literal.
_json_array_from_lines() {
  local first=1
  local line
  printf '['
  while IFS= read -r line; do
    if [ "$first" -eq 1 ]; then
      first=0
    else
      printf ','
    fi
    printf '"%s"' "$(_json_escape "$line")"
  done
  printf ']'
}

# --- Boundary fired-record (marker route ↔ Agent route de-duplication) ---
# Claude Code emits BOTH the marker write and the Agent dispatch for one boundary.
# The marker route fires first and records which boundary it handled; the Agent
# route then consumes that record and stands down, so the boundary fires once.
# Consuming (rather than merely reading) is what makes the next iteration of the
# same boundary — the reviewer loop re-running after_task — fire again correctly.
_boundary_consume_fired() {
  local _want="$1"
  [ -f "$BOUNDARY_FIRED_FILE" ] || return 1
  local _last
  _last=$(cat "$BOUNDARY_FIRED_FILE" 2>/dev/null) || return 1
  [ "$_last" = "$_want" ] || return 1
  rm -f "$BOUNDARY_FIRED_FILE" 2>/dev/null
  return 0
}

_boundary_record_fired() {
  mkdir -p "$(dirname "$BOUNDARY_FIRED_FILE")" 2>/dev/null || return 0
  printf '%s' "$1" > "$BOUNDARY_FIRED_FILE" 2>/dev/null || true
}

# --- Parse and execute one .stride_lite.md hook section ---
# Mirrors stride-hook.sh:run_stride_section but reads .stride_lite.md, dispatches
# on the three stride-lite section names, and emits JSON without jq.
#
# Returns:
#   0 — section missing OR empty fenced block OR all commands succeeded
#   2 — first command failed; structured failure JSON emitted on stdout
run_stride_lite_section() {
  local _section="$1"
  local _blocking="${2:-0}"
  local _commands=""
  local _found=0
  local _capture=0
  local _line _heading

  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in
      "## "*)
        [ "$_found" -eq 1 ] && break
        _heading="${_line#\#\# }"
        _heading="${_heading%"${_heading##*[![:space:]]}"}"
        [ "$_heading" = "$_section" ] && _found=1
        continue
        ;;
    esac
    if [ "$_found" -eq 1 ]; then
      case "$_line" in
        '```bash'*) _capture=1; continue ;;
        '```'*)     [ "$_capture" -eq 1 ] && break; continue ;;
      esac
      [ "$_capture" -eq 1 ] && _commands="${_commands}${_line}
"
    fi
  done < "$STRIDE_LITE_MD"

  if [ -z "$_commands" ]; then
    return 0
  fi

  local _cmd _trimmed
  local _cmd_list=()
  while IFS= read -r _cmd; do
    _trimmed="${_cmd#"${_cmd%%[![:space:]]*}"}"
    [ -z "$_trimmed" ] && continue
    case "$_trimmed" in \#*) continue ;; esac
    _cmd_list+=("$_trimmed")
  done <<< "$_commands"

  if [ ${#_cmd_list[@]} -eq 0 ]; then
    return 0
  fi

  cd "$PROJECT_DIR"
  local _completed_file
  _completed_file=$(mktemp)
  local _start_secs
  _start_secs=$(date +%s)
  local _cmd_index=0
  local _cmd_total=${#_cmd_list[@]}
  local _cmd_stdout_file _cmd_stderr_file _cmd_exit _cmd_stdout _cmd_stderr
  local _remaining_file _completed_json _remaining_json _end_secs _duration _i _deny_json

  for _trimmed in "${_cmd_list[@]}"; do
    _cmd_stdout_file=$(mktemp)
    _cmd_stderr_file=$(mktemp)

    # Relax `set -u` and `pipefail` for the user's command so a reference to an
    # unset env var doesn't silently abort eval before the actual command runs.
    set +uo pipefail
    eval "$_trimmed" > "$_cmd_stdout_file" 2> "$_cmd_stderr_file"
    _cmd_exit=$?
    set -uo pipefail

    if [ "$_cmd_exit" -eq 0 ]; then
      echo "$_trimmed" >> "$_completed_file"
      cat "$_cmd_stdout_file" >&2
      cat "$_cmd_stderr_file" >&2
    else
      _cmd_stdout=$(tail -50 "$_cmd_stdout_file")
      _cmd_stderr=$(tail -50 "$_cmd_stderr_file")
      rm -f "$_cmd_stdout_file" "$_cmd_stderr_file"

      _remaining_file=$(mktemp)
      if [ $((_cmd_index + 1)) -lt $_cmd_total ]; then
        for ((_i = _cmd_index + 1; _i < _cmd_total; _i++)); do
          echo "${_cmd_list[$_i]}" >> "$_remaining_file"
        done
      fi

      _completed_json=$(_json_array_from_lines < "$_completed_file")
      _remaining_json=$(_json_array_from_lines < "$_remaining_file")

      # Copilot CLI blocks a PreToolUse call on a stdout permissionDecision object,
      # not on the exit code. Carry those keys inside this same failure object for
      # blocking hooks so BOTH runtimes stop; consumers that don't know the keys
      # ignore them. Advisory hooks (after_goal) never deny.
      _deny_json=""
      if [ "$_blocking" -eq 1 ]; then
        _deny_json=$(printf ',"permissionDecision":"deny","permissionDecisionReason":"%s"' \
          "$(_json_escape "stride-copilot-lite $_section hook failed on command $((_cmd_index + 1))/$_cmd_total: $_trimmed")")
      fi

      printf '{"hook":"%s","status":"failed","failed_command":"%s","command_index":%d,"exit_code":%d,"stdout":"%s","stderr":"%s","commands_completed":%s,"commands_remaining":%s%s}\n' \
        "$(_json_escape "$_section")" \
        "$(_json_escape "$_trimmed")" \
        "$_cmd_index" \
        "$_cmd_exit" \
        "$(_json_escape "$_cmd_stdout")" \
        "$(_json_escape "$_cmd_stderr")" \
        "$_completed_json" \
        "$_remaining_json" \
        "$_deny_json"

      echo "stride-copilot-lite $_section hook failed on command $((_cmd_index + 1))/$_cmd_total: $_trimmed" >&2
      [ -n "$_cmd_stderr" ] && echo "$_cmd_stderr" >&2
      rm -f "$_completed_file" "$_remaining_file"
      return 2
    fi

    rm -f "$_cmd_stdout_file" "$_cmd_stderr_file"
    _cmd_index=$((_cmd_index + 1))
  done

  _end_secs=$(date +%s)
  _duration=$((_end_secs - _start_secs))

  _completed_json=$(_json_array_from_lines < "$_completed_file")

  printf '{"hook":"%s","status":"success","commands_completed":%s,"duration_seconds":%d}\n' \
    "$(_json_escape "$_section")" \
    "$_completed_json" \
    "$_duration"

  rm -f "$_completed_file"
  return 0
}

# --- Main flow ---
# Early exits placed after function definitions so tests can source this script
# and invoke run_stride_lite_section in isolation.

if [ -z "$PHASE" ]; then
  return 0 2>/dev/null || exit 0
fi
if [ ! -f "$STRIDE_LITE_MD" ]; then
  return 0 2>/dev/null || exit 0
fi

INPUT=$(cat)
if [ -z "$INPUT" ]; then
  exit 0
fi

# Unescaped view for Copilot CLI's JSON-encoded toolArgs (see _unescape_json_string).
INPUT_UNESC=$(_unescape_json_string "$INPUT")

# Try Claude Code's snake_case field first, fall back to Copilot CLI's camelCase.
TOOL_NAME=$(_extract_string_any "tool_name" "$INPUT" "$INPUT_UNESC")
if [ -z "$TOOL_NAME" ]; then
  TOOL_NAME=$(_extract_string_any "toolName" "$INPUT" "$INPUT_UNESC")
fi

HOOK_NAME=""
BLOCKING=0
MARKER_ROUTE=0

case "$PHASE" in
  pre)
    # Agent is Claude Code's subagent-dispatch tool name. Copilot CLI emits no
    # equivalent event (HOOK_RESEARCH), so this branch fires only under Claude
    # Code — where it stands down if the marker route already handled the
    # boundary, keeping each boundary to exactly one firing.
    if [ "$TOOL_NAME" = "Agent" ]; then
      SUBAGENT_TYPE=$(_extract_string_any "subagent_type" "$INPUT" "$INPUT_UNESC")
      case "$SUBAGENT_TYPE" in
        stride-copilot-lite:task-explorer) HOOK_NAME="before_task"; BLOCKING=1 ;;
        stride-copilot-lite:task-reviewer) HOOK_NAME="after_task";  BLOCKING=1 ;;
      esac
      if [ -n "$HOOK_NAME" ] && _boundary_consume_fired "$HOOK_NAME"; then
        exit 0
      fi
    else
      # Runtime-native boundary intercept: the workflow skill's write of the
      # boundary marker. Requires BOTH the exact plugin-owned path AND an exact
      # boundary token in the written body — either alone routes to nothing.
      case "$TOOL_NAME" in
        Edit|Write|edit|create)
          FILE_PATH=$(_extract_string_any "file_path" "$INPUT" "$INPUT_UNESC")
          # Normalize Windows separators so one pattern serves both platforms.
          FILE_PATH="${FILE_PATH//\\//}"
          case "$FILE_PATH" in
            */.stride/lite-boundary|.stride/lite-boundary)
              if printf '%s' "$INPUT" | grep -q 'stride-lite-boundary:before_task'; then
                HOOK_NAME="before_task"; BLOCKING=1; MARKER_ROUTE=1
              elif printf '%s' "$INPUT" | grep -q 'stride-lite-boundary:after_task'; then
                HOOK_NAME="after_task";  BLOCKING=1; MARKER_ROUTE=1
              fi
              ;;
          esac
          ;;
      esac
    fi
    ;;
  post)
    case "$TOOL_NAME" in
      Edit|Write|edit|create)
        FILE_PATH=$(_extract_string_any "file_path" "$INPUT" "$INPUT_UNESC")
        case "$FILE_PATH" in
          */goal.md|goal.md)
            # "## Completion Summary" detection — scan the entire hook JSON.
            # In goal.md edits, this string only appears in the Edit new_string
            # or Write content body, so a substring grep is reliable across
            # Claude Code's tool_input.new_string and Copilot CLI's toolArgs
            # JSON-encoded string.
            if printf '%s' "$INPUT" | grep -q '## Completion Summary'; then
              HOOK_NAME="after_goal"
              BLOCKING=0
            fi
            ;;
        esac
        ;;
    esac
    ;;
esac

if [ -z "$HOOK_NAME" ]; then
  exit 0
fi

run_stride_lite_section "$HOOK_NAME" "$BLOCKING"
RC=$?

# Record the boundary so Claude Code's Agent dispatch, which follows the marker
# write for the same boundary, stands down instead of firing the section twice.
if [ "$MARKER_ROUTE" -eq 1 ]; then
  _boundary_record_fired "$HOOK_NAME"
fi

# PostToolUse cannot roll back the tool call — never block with exit 2 there.
# PreToolUse blocking failures propagate as exit 2 so the dispatch is aborted.
if [ "$BLOCKING" -eq 1 ] && [ "$RC" -ne 0 ]; then
  exit "$RC"
fi

exit 0
