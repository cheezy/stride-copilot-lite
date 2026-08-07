#!/usr/bin/env bash
# test-stride-copilot-lite-hook.sh — Smoke test for the bash hook executor.
#
# Exercises the three .stride_lite.md trigger conditions plus the env-var
# defaulted-fallback and the cross-runtime field-name handling
# (Claude Code snake_case `tool_name` vs Copilot CLI camelCase `toolName`).
#
# Not a full test suite — intentionally compact for the v0.1.0 release.
# The stride-copilot/hooks/test-stride-hook.sh harness (60k lines, ~100 cases)
# is the heavier reference if we need expanded coverage later.
#
# Usage: bash test-stride-copilot-lite-hook.sh
# Exit:  0 = all assertions passed; 1 = one or more failed.

set -u  # NOT set -e — keep running after a failure to surface all problems

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/stride-copilot-lite-hook.sh"

if [ ! -x "$HOOK_SCRIPT" ]; then
  echo "test-stride-copilot-lite-hook.sh: $HOOK_SCRIPT not executable" >&2
  exit 1
fi

PASS=0
FAIL=0

ok() {
  PASS=$(( PASS + 1 ))
  echo "  PASS  $1"
}

nope() {
  FAIL=$(( FAIL + 1 ))
  echo "  FAIL  $1" >&2
  [ -n "${2:-}" ] && echo "        $2" >&2
}

# --- Setup: scratch project dir with a working .stride_lite.md ---
SCRATCH=$(mktemp -d)
# Separate scratch dir for the failing-command fixtures so they never perturb
# the success-path .stride_lite.md above.
FAIL_SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH" "$FAIL_SCRATCH"' EXIT

cat > "$SCRATCH/.stride_lite.md" <<'EOF'
## before_task

```bash
echo "before_task fired"
```

## after_task

```bash
echo "after_task fired"
```

## after_goal

```bash
echo "after_goal fired"
```
EOF

# A .stride_lite.md whose three sections each run a failing command — drives the
# exit-code contract cases below. `false` (exit 1), NOT `exit 3`, is deliberate:
# the executor evals each command in-process, so `exit N` would terminate the
# hook before it could emit its failure JSON.
cat > "$FAIL_SCRATCH/.stride_lite.md" <<'EOF'
## before_task

```bash
false
```

## after_task

```bash
false
```

## after_goal

```bash
false
```
EOF

run_hook() {
  local phase="$1"
  local stdin_json="$2"
  printf '%s' "$stdin_json" | CLAUDE_PROJECT_DIR="$SCRATCH" "$HOOK_SCRIPT" "$phase" 2>/dev/null
}

# Same as run_hook but against a caller-supplied project dir, so the failing-
# command fixture drives the hook without touching the success-path scratch.
# The pipeline is the function's last command, so `rc=$?` in the caller captures
# the hook's real exit code (no masking subshell).
run_hook_dir() {
  local dir="$1"
  local phase="$2"
  local stdin_json="$3"
  printf '%s' "$stdin_json" | CLAUDE_PROJECT_DIR="$dir" "$HOOK_SCRIPT" "$phase" 2>/dev/null
}

# --- Case 1: missing .stride_lite.md → silent no-op (exit 0, no stdout) ---
echo "Case 1: missing .stride_lite.md"
EMPTY_SCRATCH=$(mktemp -d)
out=$(printf '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-copilot-lite:task-explorer"}}' \
  | CLAUDE_PROJECT_DIR="$EMPTY_SCRATCH" "$HOOK_SCRIPT" pre 2>/dev/null)
rc=$?
rm -rf "$EMPTY_SCRATCH"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  ok "missing .stride_lite.md → exit 0 + no stdout"
else
  nope "missing .stride_lite.md" "rc=$rc, stdout='$out'"
fi

# --- Case 2: Claude Code snake_case + Agent + task-explorer → fires before_task ---
echo "Case 2: Claude Code snake_case payload triggers before_task"
out=$(run_hook pre '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-copilot-lite:task-explorer"}}')
if echo "$out" | grep -q '"hook":"before_task"' && echo "$out" | grep -q '"status":"success"'; then
  ok "Claude Code snake_case → before_task fires"
else
  nope "Claude Code snake_case → before_task" "stdout='$out'"
fi

# --- Case 3: Claude Code snake_case + Agent + task-reviewer → fires after_task ---
echo "Case 3: Claude Code snake_case payload triggers after_task"
out=$(run_hook pre '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-copilot-lite:task-reviewer"}}')
if echo "$out" | grep -q '"hook":"after_task"' && echo "$out" | grep -q '"status":"success"'; then
  ok "Claude Code snake_case → after_task fires"
else
  nope "Claude Code snake_case → after_task" "stdout='$out'"
fi

# --- Case 4: Copilot camelCase toolName fallback → fires before_task ---
echo "Case 4: Copilot camelCase toolName triggers before_task via fallback"
out=$(run_hook pre '{"toolName":"Agent","tool_input":{"subagent_type":"stride-copilot-lite:task-explorer"}}')
if echo "$out" | grep -q '"hook":"before_task"'; then
  ok "Copilot camelCase toolName → before_task fires"
else
  nope "Copilot camelCase toolName" "stdout='$out'"
fi

# --- Case 5: post + Edit + goal.md + Completion Summary → fires after_goal ---
echo "Case 5: PostToolUse Edit on goal.md with Completion Summary → after_goal"
out=$(run_hook post '{"tool_name":"Edit","tool_input":{"file_path":"docs/implementation/PENDING/some-goal/goal.md","new_string":"... ## Completion Summary ..."}}')
if echo "$out" | grep -q '"hook":"after_goal"'; then
  ok "Edit + goal.md + Completion Summary → after_goal fires"
else
  nope "Edit + goal.md + Completion Summary" "stdout='$out'"
fi

# --- Case 6: Copilot lowercase 'edit' + goal.md + Completion Summary → fires after_goal ---
echo "Case 6: Copilot lowercase 'edit' triggers after_goal"
out=$(run_hook post '{"toolName":"edit","tool_input":{"file_path":"goal.md","new_string":"## Completion Summary"}}')
if echo "$out" | grep -q '"hook":"after_goal"'; then
  ok "Copilot 'edit' + goal.md + Completion Summary → after_goal fires"
else
  nope "Copilot 'edit'" "stdout='$out'"
fi

# --- Case 7: post + Edit on goal.md WITHOUT Completion Summary → no-op ---
echo "Case 7: PostToolUse Edit on goal.md WITHOUT Completion Summary → no-op"
out=$(run_hook post '{"tool_name":"Edit","tool_input":{"file_path":"goal.md","new_string":"some other change"}}')
if [ -z "$out" ]; then
  ok "Edit + goal.md WITHOUT Completion Summary → no-op (no stdout)"
else
  nope "Edit + goal.md WITHOUT Completion Summary should no-op" "stdout='$out'"
fi

# --- Case 8: env-var fallback (CLAUDE_PROJECT_DIR unset) → uses cwd ---
echo "Case 8: env-var defaulted-fallback when CLAUDE_PROJECT_DIR unset"
out=$(cd "$SCRATCH" && unset CLAUDE_PROJECT_DIR && \
  printf '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-copilot-lite:task-explorer"}}' \
  | "$HOOK_SCRIPT" pre 2>/dev/null)
if echo "$out" | grep -q '"hook":"before_task"'; then
  ok "Unset CLAUDE_PROJECT_DIR + cwd .stride_lite.md → before_task fires"
else
  nope "Unset CLAUDE_PROJECT_DIR fallback" "stdout='$out'"
fi

# --- Case 9: non-matching tool (e.g., Bash) → no-op ---
echo "Case 9: non-matching tool name (Bash) → no-op"
out=$(run_hook pre '{"tool_name":"Bash","tool_input":{"command":"ls"}}')
if [ -z "$out" ]; then
  ok "Bash tool name → no-op (no stdout)"
else
  nope "Bash tool name should no-op" "stdout='$out'"
fi

# --- Case 10: subagent dispatch to a NON-stride-copilot-lite subagent → no-op ---
echo "Case 10: Agent with other subagent_type → no-op"
out=$(run_hook pre '{"tool_name":"Agent","tool_input":{"subagent_type":"Explore"}}')
if [ -z "$out" ]; then
  ok "Agent + non-matching subagent_type → no-op"
else
  nope "Agent + non-matching subagent_type should no-op" "stdout='$out'"
fi

# --- Case 11: before_task failing command → blocking exit 2 + failure JSON ---
echo "Case 11: before_task failing command → blocking exit 2 + failure JSON"
out=$(run_hook_dir "$FAIL_SCRATCH" pre '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-copilot-lite:task-explorer"}}')
rc=$?
if [ "$rc" -eq 2 ] && echo "$out" | grep -q '"hook":"before_task"' && echo "$out" | grep -q '"status":"failed"'; then
  ok "before_task failing command → exit 2 (blocking) + failed-status JSON"
else
  nope "before_task failing command → exit 2 + failed JSON" "rc=$rc, stdout='$out'"
fi

# --- Case 12: after_task failing command → blocking exit 2 + failure JSON ---
echo "Case 12: after_task failing command → blocking exit 2 + failure JSON"
out=$(run_hook_dir "$FAIL_SCRATCH" pre '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-copilot-lite:task-reviewer"}}')
rc=$?
if [ "$rc" -eq 2 ] && echo "$out" | grep -q '"hook":"after_task"' && echo "$out" | grep -q '"status":"failed"'; then
  ok "after_task failing command → exit 2 (blocking) + failed-status JSON"
else
  nope "after_task failing command → exit 2 + failed JSON" "rc=$rc, stdout='$out'"
fi

# --- Case 13: after_goal failing command → advisory exit 0 + failure JSON ---
# PostToolUse cannot roll back the write, so a failing after_goal command must
# still exit 0 (advisory) while emitting its failure JSON for the user.
echo "Case 13: after_goal failing command → advisory exit 0 + failure JSON"
out=$(run_hook_dir "$FAIL_SCRATCH" post '{"tool_name":"Edit","tool_input":{"file_path":"docs/implementation/PENDING/some-goal/goal.md","new_string":"... ## Completion Summary ..."}}')
rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q '"hook":"after_goal"' && echo "$out" | grep -q '"status":"failed"'; then
  ok "after_goal failing command → exit 0 (advisory) + failed-status JSON"
else
  nope "after_goal failing command → exit 0 + failed JSON" "rc=$rc, stdout='$out'"
fi

# ==================================================================
# Boundary-marker route (W2021) — the runtime-native before_task /
# after_task intercept that replaces the dependence on an Agent event.
# ==================================================================

# The marker route writes .stride/lite-boundary-fired so Claude Code's Agent
# dispatch can stand down. Clear it between cases that don't test that handshake.
clear_fired() { rm -f "$1/.stride/lite-boundary-fired" 2>/dev/null; }

MARKER_CC='{"tool_name":"Write","tool_input":{"file_path":"/p/.stride/lite-boundary","content":"stride-lite-boundary:before_task"}}'
MARKER_COP_BEFORE='{"toolName":"create","toolArgs":"{\"file_path\":\"/p/.stride/lite-boundary\",\"content\":\"stride-lite-boundary:before_task\"}"}'
MARKER_COP_AFTER='{"toolName":"edit","toolArgs":"{\"file_path\":\".stride/lite-boundary\",\"content\":\"stride-lite-boundary:after_task\"}"}'

# --- Case 14: Copilot CLI marker write → before_task ---
echo "Case 14: Copilot CLI boundary marker triggers before_task"
clear_fired "$SCRATCH"
out=$(run_hook pre "$MARKER_COP_BEFORE")
if echo "$out" | grep -q '"hook":"before_task"' && echo "$out" | grep -q '"status":"success"'; then
  ok "Copilot marker (create + encoded toolArgs) → before_task fires"
else
  nope "Copilot marker → before_task" "stdout='$out'"
fi

# --- Case 15: Copilot CLI marker write → after_task, relative path ---
echo "Case 15: Copilot CLI boundary marker triggers after_task"
clear_fired "$SCRATCH"
out=$(run_hook pre "$MARKER_COP_AFTER")
if echo "$out" | grep -q '"hook":"after_task"' && echo "$out" | grep -q '"status":"success"'; then
  ok "Copilot marker (edit, relative path) → after_task fires"
else
  nope "Copilot marker → after_task" "stdout='$out'"
fi

# --- Case 16: Claude Code marker write → before_task (same route, both runtimes) ---
echo "Case 16: Claude Code boundary marker triggers before_task"
clear_fired "$SCRATCH"
out=$(run_hook pre "$MARKER_CC")
if echo "$out" | grep -q '"hook":"before_task"' && echo "$out" | grep -q '"status":"success"'; then
  ok "Claude Code marker (Write + tool_input) → before_task fires"
else
  nope "Claude Code marker → before_task" "stdout='$out'"
fi

# --- Case 17: NEAR-MISS — marker path, no boundary token → no-op ---
echo "Case 17: NEAR-MISS marker path without a boundary token → no-op"
clear_fired "$SCRATCH"
out=$(run_hook pre '{"toolName":"create","toolArgs":"{\"file_path\":\"/p/.stride/lite-boundary\",\"content\":\"just some text\"}"}')
if [ -z "$out" ]; then
  ok "marker path + no token → no-op (no stdout)"
else
  nope "marker path without token should no-op" "stdout='$out'"
fi

# --- Case 18: NEAR-MISS — boundary token, non-marker path → no-op ---
# This is the false-positive bound that matters most: the token appearing in
# ordinary file content must never fire a hook.
echo "Case 18: NEAR-MISS boundary token written to some other file → no-op"
clear_fired "$SCRATCH"
out=$(run_hook pre '{"toolName":"create","toolArgs":"{\"file_path\":\"/p/docs/notes.md\",\"content\":\"stride-lite-boundary:before_task\"}"}')
if [ -z "$out" ]; then
  ok "boundary token + non-marker path → no-op (no stdout)"
else
  nope "boundary token outside the marker path should no-op" "stdout='$out'"
fi

# --- Case 19: NEAR-MISS — marker payload in the post phase → no-op ---
echo "Case 19: NEAR-MISS marker payload on PostToolUse → no-op"
clear_fired "$SCRATCH"
out=$(run_hook post "$MARKER_COP_BEFORE")
if [ -z "$out" ]; then
  ok "marker payload + post phase → no-op (no stdout)"
else
  nope "marker payload in post phase should no-op" "stdout='$out'"
fi

# --- Case 20: NEAR-MISS — boundary token inside a bash command → no-op ---
# The token is not a Bash sentinel: echoing it must not fire a hook.
echo "Case 20: NEAR-MISS boundary token inside a bash command → no-op"
clear_fired "$SCRATCH"
out=$(run_hook pre '{"toolName":"bash","toolArgs":"{\"command\":\"echo stride-lite-boundary:before_task\"}"}')
if [ -z "$out" ]; then
  ok "boundary token in a bash command → no-op (no stdout)"
else
  nope "boundary token in a bash command should no-op" "stdout='$out'"
fi

# --- Case 21: marker route then Agent dispatch → boundary fires exactly once ---
# Claude Code emits both events for one boundary. The marker route fires and
# records; the Agent route consumes the record and stands down.
echo "Case 21: marker write + Agent dispatch → before_task fires exactly once"
DEDUPE_SCRATCH=$(mktemp -d)
cp "$SCRATCH/.stride_lite.md" "$DEDUPE_SCRATCH/.stride_lite.md"
first=$(run_hook_dir "$DEDUPE_SCRATCH" pre "$MARKER_CC")
second=$(run_hook_dir "$DEDUPE_SCRATCH" pre '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-copilot-lite:task-explorer"}}')
if echo "$first" | grep -q '"hook":"before_task"' && [ -z "$second" ]; then
  ok "marker fires, following Agent dispatch stands down → exactly one firing"
else
  nope "marker+Agent should fire exactly once" "first='$first' second='$second'"
fi

# --- Case 22: record is consumed, so the next boundary fires again ---
# The reviewer loop re-runs after_task for the same task; a record that were
# merely read rather than consumed would suppress that legitimate second firing.
echo "Case 22: fired-record is consumed, so a later Agent dispatch fires again"
third=$(run_hook_dir "$DEDUPE_SCRATCH" pre '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-copilot-lite:task-explorer"}}')
rm -rf "$DEDUPE_SCRATCH"
if echo "$third" | grep -q '"hook":"before_task"'; then
  ok "record consumed → next Agent dispatch fires normally"
else
  nope "record should be consumed, not sticky" "third='$third'"
fi

# --- Case 23: blocking marker failure → exit 2 AND permissionDecision deny ---
# Claude Code blocks on exit 2; Copilot CLI blocks on the stdout deny object.
# Both must be present or one runtime silently continues past a failed hook.
echo "Case 23: blocking marker failure → exit 2 + permissionDecision deny"
clear_fired "$FAIL_SCRATCH"
out=$(run_hook_dir "$FAIL_SCRATCH" pre "$MARKER_COP_BEFORE")
rc=$?
if [ "$rc" -eq 2 ] \
  && echo "$out" | grep -q '"status":"failed"' \
  && echo "$out" | grep -q '"permissionDecision":"deny"' \
  && echo "$out" | grep -q '"permissionDecisionReason":'; then
  ok "blocking failure → exit 2 AND permissionDecision deny (both runtimes stop)"
else
  nope "blocking failure must emit exit 2 + deny" "rc=$rc, stdout='$out'"
fi

# --- Case 24: advisory after_goal failure must NOT deny ---
# after_goal is advisory on both runtimes; emitting a deny there would newly
# block a write that has always been allowed to proceed.
echo "Case 24: advisory after_goal failure → no permissionDecision"
out=$(run_hook_dir "$FAIL_SCRATCH" post '{"tool_name":"Edit","tool_input":{"file_path":"g/goal.md","new_string":"## Completion Summary"}}')
rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q '"status":"failed"' && ! echo "$out" | grep -q 'permissionDecision'; then
  ok "advisory after_goal failure → exit 0 and NO deny"
else
  nope "after_goal must not deny" "rc=$rc, stdout='$out'"
fi

# --- Case 25: after_goal fires on a Copilot-shaped payload ---
# Regression guard: before W2021 the bash extractor could not read Copilot's
# JSON-encoded toolArgs, so EVERY Copilot payload — after_goal included —
# silently routed to nothing while the docs claimed it worked.
echo "Case 25: after_goal fires on a Copilot CLI encoded-toolArgs payload"
out=$(run_hook post '{"toolName":"edit","toolArgs":"{\"file_path\":\"/p/g/goal.md\",\"content\":\"## Completion Summary\"}"}')
if echo "$out" | grep -q '"hook":"after_goal"' && echo "$out" | grep -q '"status":"success"'; then
  ok "Copilot encoded toolArgs → after_goal fires"
else
  nope "Copilot encoded toolArgs → after_goal" "stdout='$out'"
fi

# --- Case 26: full simulated workflow pass → each hook fires exactly once, in order ---
# Drives the whole Claude Code event sequence for a one-task goal and asserts the
# three sections fire once each in lifecycle order. This is the case that would
# catch a regression where the dedupe handshake leaks a duplicate firing.
echo "Case 26: full workflow pass → before_task, after_task, after_goal once each, in order"
SEQ_SCRATCH=$(mktemp -d)
cp "$SCRATCH/.stride_lite.md" "$SEQ_SCRATCH/.stride_lite.md"
seq_log=""
capture() { seq_log="${seq_log}$(run_hook_dir "$SEQ_SCRATCH" "$1" "$2" | grep -o '"hook":"[a-z_]*"')"$'\n'; }
capture pre  "$MARKER_CC"                                                                              # Step 2 marker
capture pre  '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-copilot-lite:task-explorer"}}' # Step 3 dispatch
capture pre  '{"tool_name":"Write","tool_input":{"file_path":"/p/.stride/lite-boundary","content":"stride-lite-boundary:after_task"}}'
capture pre  '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-copilot-lite:task-reviewer"}}' # Step 6 dispatch
capture post '{"tool_name":"Edit","tool_input":{"file_path":"g/goal.md","new_string":"## Completion Summary"}}'
rm -rf "$SEQ_SCRATCH"
seq_actual=$(printf '%s' "$seq_log" | grep -c 'hook' || true)
seq_order=$(printf '%s' "$seq_log" | grep -o '"hook":"[a-z_]*"' | sed 's/"hook":"//;s/"//' | tr '\n' ' ')
if [ "$seq_actual" -eq 3 ] && [ "$seq_order" = "before_task after_task after_goal " ]; then
  ok "full workflow pass → 3 firings in order: $seq_order"
else
  nope "full workflow pass should fire each hook once, in order" "count=$seq_actual order='$seq_order'"
fi

# --- Summary ---
echo ""
echo "------------------------------------------------------------------"
echo "$PASS passed, $FAIL failed"
if [ "$FAIL" -eq 0 ]; then
  exit 0
else
  exit 1
fi
