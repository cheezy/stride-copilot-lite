#!/usr/bin/env bash
# test-stride-copilot-lite-hook.sh — Smoke test for the bash hook executor.
#
# Covers every routing branch of the three .stride_lite.md triggers, the
# runtime-native boundary intercept and its near-misses, env-var derivation and
# metacharacter inertness, the orchestrator-marker gate and its override, the
# exit-code and permissionDecision contracts, and cross-runtime field-name
# handling (Claude Code snake_case `tool_name` vs Copilot CLI camelCase
# `toolName`).
#
# It also runs the CROSS-EXECUTOR PARITY check: a shared fixture set through both
# this executor and the .ps1, with the emitted JSON diffed. Where pwsh is absent
# that reports a skip WITH A REASON rather than passing silently.
#
# Every fixture command is inert (`true`, `false`, `echo`, a `printf` into the
# sandbox) and confined to a temp directory the suite creates and removes. There
# are deliberately NO timing assertions — they would only add flakes.
#
# Run the .ps1 mirror too; the two exercise independent implementations of one
# contract and each has caught bugs the other could not see.
#
# Usage: bash test-stride-copilot-lite-hook.sh
# Exit:  0 = all assertions passed; 1 = one or more failed.

set -u  # NOT set -e — keep running after a failure to surface all problems

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/stride-copilot-lite-hook.sh"
REPO_ROOT_GUESS="$(cd "$SCRIPT_DIR/.." && pwd)"

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

# Every case below simulates a tool call made INSIDE a workflow run, so each
# scratch project needs a fresh orchestrator marker (W2023). Without one the hook
# correctly stands down — which is what the dedicated gate cases assert.
write_marker() {
  mkdir -p "$1/.stride-copilot-lite"
  printf '{"session_id":"harness","started_at":"%s","pid":%d}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" > "$1/.stride-copilot-lite/.orchestrator_active"
}
write_marker "$SCRATCH"
write_marker "$FAIL_SCRATCH"

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

# The marker route writes .stride-copilot-lite/lite-boundary-fired so Claude Code's Agent
# dispatch can stand down. Clear it between cases that don't test that handshake.
clear_fired() { rm -f "$1/.stride-copilot-lite/lite-boundary-fired" 2>/dev/null; }

MARKER_CC='{"tool_name":"Write","tool_input":{"file_path":"/p/.stride-copilot-lite/lite-boundary","content":"stride-lite-boundary:before_task"}}'
MARKER_COP_BEFORE='{"toolName":"create","toolArgs":"{\"file_path\":\"/p/.stride-copilot-lite/lite-boundary\",\"content\":\"stride-lite-boundary:before_task\"}"}'
MARKER_COP_AFTER='{"toolName":"edit","toolArgs":"{\"file_path\":\".stride-copilot-lite/lite-boundary\",\"content\":\"stride-lite-boundary:after_task\"}"}'

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
out=$(run_hook pre '{"toolName":"create","toolArgs":"{\"file_path\":\"/p/.stride-copilot-lite/lite-boundary\",\"content\":\"just some text\"}"}')
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
write_marker "$DEDUPE_SCRATCH"
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
write_marker "$SEQ_SCRATCH"
seq_log=""
capture() { seq_log="${seq_log}$(run_hook_dir "$SEQ_SCRATCH" "$1" "$2" | grep -o '"hook":"[a-z_]*"')"$'\n'; }
capture pre  "$MARKER_CC"                                                                              # Step 2 marker
capture pre  '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-copilot-lite:task-explorer"}}' # Step 3 dispatch
capture pre  '{"tool_name":"Write","tool_input":{"file_path":"/p/.stride-copilot-lite/lite-boundary","content":"stride-lite-boundary:after_task"}}'
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

# ==================================================================
# Hook environment injection (W2022) — the nine exported keys.
# ==================================================================

# A scratch project with a real goal directory, plus hook sections that dump the
# exported environment to a probe file. A probe file is used rather than stdout
# because the executors forward command output to stderr, and the point of these
# cases is the VALUES the child received, not where its output went.
ENV_SCRATCH=$(mktemp -d)
ENV_PROBE="$ENV_SCRATCH/probe.txt"
mkdir -p "$ENV_SCRATCH/docs/implementation/PENDING/add-notifications"
printf '# Add real-time notifications\n\nbody\n' \
  > "$ENV_SCRATCH/docs/implementation/PENDING/add-notifications/goal.md"
# The title deliberately carries shell metacharacters — see the inertness case.
printf '# Subscribe $(id) `whoami` ${HOME}\n\nbody\n' \
  > "$ENV_SCRATCH/docs/implementation/PENDING/add-notifications/task2.md"
cat > "$ENV_SCRATCH/.stride_lite.md" <<ENVEOF
## before_task

\`\`\`bash
printf '%s\n' "HOOK_NAME=\$HOOK_NAME" "AGENT_NAME=\$AGENT_NAME" "TASK_FILE=\$TASK_FILE" "TASK_NUMBER=\$TASK_NUMBER" "TASK_TITLE=\$TASK_TITLE" "GOAL_DIR=\$GOAL_DIR" "GOAL_FILE=\$GOAL_FILE" "GOAL_SLUG=\$GOAL_SLUG" "GOAL_TITLE=\$GOAL_TITLE" > "$ENV_PROBE"
\`\`\`

## after_goal

\`\`\`bash
printf '%s\n' "HOOK_NAME=\$HOOK_NAME" "TASK_NUMBER=\$TASK_NUMBER" "GOAL_SLUG=\$GOAL_SLUG" "GOAL_TITLE=\$GOAL_TITLE" > "$ENV_PROBE"
\`\`\`
ENVEOF
write_marker "$ENV_SCRATCH"

TASKREL="docs/implementation/PENDING/add-notifications/task2.md"
probe() { grep -m1 "^$1=" "$ENV_PROBE" 2>/dev/null | cut -d= -f2-; }

# --- Case 27: every documented key reaches the executed command ---
echo "Case 27: all nine exported keys reach the command"
rm -f "$ENV_PROBE"
run_hook_dir "$ENV_SCRATCH" pre \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/p/.stride-copilot-lite/lite-boundary\",\"content\":\"stride-lite-boundary:before_task:$TASKREL\"}}" >/dev/null 2>&1
missing=""
for k in HOOK_NAME AGENT_NAME TASK_FILE TASK_NUMBER TASK_TITLE GOAL_DIR GOAL_FILE GOAL_SLUG GOAL_TITLE; do
  grep -q "^$k=" "$ENV_PROBE" 2>/dev/null || missing="$missing $k"
done
if [ -z "$missing" ] \
  && [ "$(probe HOOK_NAME)" = "before_task" ] \
  && [ "$(probe AGENT_NAME)" = "stride-copilot-lite" ] \
  && [ "$(probe TASK_NUMBER)" = "2" ] \
  && [ "$(probe GOAL_SLUG)" = "add-notifications" ] \
  && [ "$(probe GOAL_TITLE)" = "Add real-time notifications" ]; then
  ok "all nine keys exported; TASK_NUMBER=2, GOAL_SLUG and GOAL_TITLE derived"
else
  nope "exported key set incomplete or wrong" "missing='$missing' number='$(probe TASK_NUMBER)' slug='$(probe GOAL_SLUG)' goaltitle='$(probe GOAL_TITLE)'"
fi

# --- Case 28: a metacharacter-bearing title is inert ---
# The title contains $(id), backticks and ${HOME}. It must arrive as literal
# bytes: exported as an environment VALUE, never spliced into command text.
echo "Case 28: shell metacharacters in a task title are inert"
title=$(probe TASK_TITLE)
if [ "$title" = 'Subscribe $(id) `whoami` ${HOME}' ]; then
  ok "title reached the command verbatim; nothing expanded or executed"
else
  nope "title must arrive literal" "got='$title'"
fi

# --- Case 29: a marker with no task path → task keys empty, hook still fires ---
echo "Case 29: marker without a task path → empty task keys, unchanged exit code"
rm -f "$ENV_PROBE"
out=$(run_hook_dir "$ENV_SCRATCH" pre '{"tool_name":"Write","tool_input":{"file_path":"/p/.stride-copilot-lite/lite-boundary","content":"stride-lite-boundary:before_task"}}' 2>/dev/null)
rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q '"status":"success"' \
  && [ -z "$(probe TASK_FILE)" ] && [ -z "$(probe TASK_NUMBER)" ] && [ -z "$(probe TASK_TITLE)" ] \
  && grep -q '^TASK_FILE=' "$ENV_PROBE" 2>/dev/null; then
  ok "undeterminable keys export as defined-but-empty; hook fires, exit 0"
else
  ok_detail="rc=$rc file='$(probe TASK_FILE)' number='$(probe TASK_NUMBER)'"
  nope "missing task path must degrade, not fail" "$ok_detail"
fi

# --- Case 30: a path escaping the project directory is rejected ---
echo "Case 30: task path outside the project directory is rejected"
rm -f "$ENV_PROBE"
run_hook_dir "$ENV_SCRATCH" pre \
  '{"tool_name":"Write","tool_input":{"file_path":"/p/.stride-copilot-lite/lite-boundary","content":"stride-lite-boundary:before_task:../../../../../../etc/passwd"}}' >/dev/null 2>&1
if [ -z "$(probe TASK_FILE)" ] && [ -z "$(probe TASK_TITLE)" ]; then
  ok "traversal path rejected → TASK_FILE and TASK_TITLE empty"
else
  nope "path outside the project must be rejected" "file='$(probe TASK_FILE)'"
fi

# --- Case 31: after_goal derives goal context and no task context ---
echo "Case 31: after_goal exports goal keys and empty task keys"
rm -f "$ENV_PROBE"
run_hook_dir "$ENV_SCRATCH" post \
  '{"tool_name":"Edit","tool_input":{"file_path":"docs/implementation/PENDING/add-notifications/goal.md","new_string":"## Completion Summary"}}' >/dev/null 2>&1
if [ "$(probe HOOK_NAME)" = "after_goal" ] \
  && [ "$(probe GOAL_SLUG)" = "add-notifications" ] \
  && [ "$(probe GOAL_TITLE)" = "Add real-time notifications" ] \
  && [ -z "$(probe TASK_NUMBER)" ]; then
  ok "after_goal → goal keys derived, task keys empty"
else
  nope "after_goal goal-context derivation" "hook='$(probe HOOK_NAME)' slug='$(probe GOAL_SLUG)' number='$(probe TASK_NUMBER)'"
fi

# --- Case 32: the failure JSON key set is unchanged (no env leakage) ---
# A user's hook may reference secrets, so no derived value may appear in the
# result JSON. Its key set must be exactly what it was before env injection.
echo "Case 32: failure JSON carries no exported environment values"
ENVFAIL_SCRATCH=$(mktemp -d)
mkdir -p "$ENVFAIL_SCRATCH/g"
printf '# Secret Goal Title\n' > "$ENVFAIL_SCRATCH/g/goal.md"
printf '# Secret Task Title\n' > "$ENVFAIL_SCRATCH/g/task2.md"
printf '## before_task\n\n```bash\nfalse\n```\n' > "$ENVFAIL_SCRATCH/.stride_lite.md"
write_marker "$ENVFAIL_SCRATCH"
out=$(run_hook_dir "$ENVFAIL_SCRATCH" pre '{"tool_name":"Write","tool_input":{"file_path":"/p/.stride-copilot-lite/lite-boundary","content":"stride-lite-boundary:before_task:g/task2.md"}}')
rm -rf "$ENVFAIL_SCRATCH"
if echo "$out" | grep -q '"status":"failed"' \
  && ! echo "$out" | grep -q 'Secret Task Title' \
  && ! echo "$out" | grep -q 'Secret Goal Title' \
  && ! echo "$out" | grep -q 'TASK_TITLE' \
  && ! echo "$out" | grep -q 'GOAL_SLUG'; then
  ok "failure JSON contains no derived env values"
else
  nope "failure JSON must not carry env values" "stdout='$out'"
fi

# --- Case 33: cross-executor parity — both export the identical key set/values ---
# The parity contract is normative and this is the assertion that enforces it for
# the exported environment: the same payload through the .sh and the .ps1 must
# produce byte-identical probe output. Skipped, not failed, where pwsh is absent
# (the plugin's own CI is the place that has both).
echo "Case 33: .sh and .ps1 export an identical key set and values"
if command -v pwsh > /dev/null 2>&1; then
  PARITY_PAYLOAD="{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/p/.stride-copilot-lite/lite-boundary\",\"content\":\"stride-lite-boundary:before_task:$TASKREL\"}}"
  rm -f "$ENV_PROBE"
  printf '%s' "$PARITY_PAYLOAD" | CLAUDE_PROJECT_DIR="$ENV_SCRATCH" "$HOOK_SCRIPT" pre >/dev/null 2>&1
  sh_probe=$(cat "$ENV_PROBE" 2>/dev/null)
  rm -f "$ENV_PROBE" "$ENV_SCRATCH/.stride-copilot-lite/lite-boundary-fired"
  printf '%s' "$PARITY_PAYLOAD" | CLAUDE_PROJECT_DIR="$ENV_SCRATCH" \
    pwsh -NoProfile -File "$SCRIPT_DIR/stride-copilot-lite-hook.ps1" pre >/dev/null 2>&1
  ps_probe=$(cat "$ENV_PROBE" 2>/dev/null)
  if [ -n "$sh_probe" ] && [ "$sh_probe" = "$ps_probe" ]; then
    ok "both executors exported byte-identical values for the same payload"
  else
    nope "executors diverged on the exported environment" "sh='$sh_probe' ps1='$ps_probe'"
  fi
else
  ok "cross-executor parity SKIPPED — pwsh not installed on this machine"
fi

rm -rf "$ENV_SCRATCH"

# ==================================================================
# Orchestrator activation gate (W2023) — fresh / missing / stale /
# override, for a blocking trigger and the advisory trigger.
# ==================================================================

GATE_SCRATCH=$(mktemp -d)
printf '## before_task\n\n```bash\necho GATE_BEFORE\n```\n\n## after_goal\n\n```bash\necho GATE_AFTER_GOAL\n```\n' \
  > "$GATE_SCRATCH/.stride_lite.md"
GATE_MARKER="$GATE_SCRATCH/.stride-copilot-lite/.orchestrator_active"
GATE_BLOCKING='{"tool_name":"Write","tool_input":{"file_path":"/p/.stride-copilot-lite/lite-boundary","content":"stride-lite-boundary:before_task"}}'
GATE_ADVISORY='{"tool_name":"Edit","tool_input":{"file_path":"g/goal.md","new_string":"## Completion Summary"}}'

# Write a marker whose started_at is N seconds in the past. The mtime is aged to
# match so the mtime fallback cannot mask a started_at the gate should reject.
write_marker_aged() {
  local _dir="$1" _age="$2" _iso _stamp
  mkdir -p "$_dir/.stride-copilot-lite"
  if _iso=$(date -u -d "@$(( $(date -u +%s) - _age ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null); then :
  else _iso=$(date -u -r $(( $(date -u +%s) - _age )) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null); fi
  printf '{"session_id":"harness","started_at":"%s","pid":1}\n' "$_iso" \
    > "$_dir/.stride-copilot-lite/.orchestrator_active"
  # touch -t interprets its stamp in LOCAL time, so format it in local time —
  # a -u stamp would age the file by the timezone offset instead of by _age.
  if _stamp=$(date -d "@$(( $(date -u +%s) - _age ))" +%Y%m%d%H%M.%S 2>/dev/null); then :
  else _stamp=$(date -r $(( $(date -u +%s) - _age )) +%Y%m%d%H%M.%S 2>/dev/null); fi
  [ -n "$_stamp" ] && touch -t "$_stamp" "$_dir/.stride-copilot-lite/.orchestrator_active" 2>/dev/null
}

# --- Case 34: fresh marker → the section runs exactly as before ---
echo "Case 34: fresh marker → blocking trigger runs its section"
write_marker_aged "$GATE_SCRATCH" 0
out=$(run_hook_dir "$GATE_SCRATCH" pre "$GATE_BLOCKING")
if echo "$out" | grep -q '"hook":"before_task"' && echo "$out" | grep -q '"status":"success"'; then
  ok "fresh marker → before_task runs"
else
  nope "fresh marker must run the section" "stdout='$out'"
fi

# --- Case 35: no marker → blocking trigger runs nothing, exit 0, empty stdout ---
# Critically it must NOT block: exit 2 here would make ordinary editing outside a
# workflow start failing under the widened matcher.
echo "Case 35: no marker → blocking trigger stands down, exit 0, empty stdout"
rm -rf "$GATE_SCRATCH/.stride-copilot-lite"
out=$(run_hook_dir "$GATE_SCRATCH" pre "$GATE_BLOCKING")
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  ok "missing marker → nothing runs, exit 0 (tool call not blocked)"
else
  nope "missing marker must stand down without blocking" "rc=$rc stdout='$out'"
fi

# --- Case 36: stale marker (older than 4h) → stands down ---
echo "Case 36: marker older than 4 hours → stands down"
write_marker_aged "$GATE_SCRATCH" 14500      # 4h + 100s
out=$(run_hook_dir "$GATE_SCRATCH" pre "$GATE_BLOCKING")
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  ok "stale marker → nothing runs, exit 0"
else
  nope "a marker past the freshness window must not arm hooks" "rc=$rc stdout='$out'"
fi

# --- Case 37: a marker just inside the window still fires ---
# Guards the boundary in the other direction, so the window cannot silently
# collapse to "only brand-new markers count".
echo "Case 37: marker just inside the 4-hour window still fires"
write_marker_aged "$GATE_SCRATCH" 14000      # ~3h53m
out=$(run_hook_dir "$GATE_SCRATCH" pre "$GATE_BLOCKING")
if echo "$out" | grep -q '"hook":"before_task"'; then
  ok "marker inside the window → section runs"
else
  nope "a marker inside the window must still fire" "stdout='$out'"
fi

# --- Case 38: override bypasses the gate entirely ---
echo "Case 38: STRIDE_COPILOT_LITE_ALLOW_DIRECT=1 bypasses a missing marker"
rm -rf "$GATE_SCRATCH/.stride-copilot-lite"
out=$(printf '%s' "$GATE_BLOCKING" | STRIDE_COPILOT_LITE_ALLOW_DIRECT=1 \
  CLAUDE_PROJECT_DIR="$GATE_SCRATCH" "$HOOK_SCRIPT" pre 2>/dev/null)
if echo "$out" | grep -q '"hook":"before_task"'; then
  ok "override → section runs with no marker present"
else
  nope "override must bypass the gate" "stdout='$out'"
fi

# --- Case 39: the advisory trigger is gated too ---
echo "Case 39: advisory after_goal trigger is gated on the same marker"
rm -rf "$GATE_SCRATCH/.stride-copilot-lite"
gated_out=$(run_hook_dir "$GATE_SCRATCH" post "$GATE_ADVISORY")
gated_rc=$?
write_marker_aged "$GATE_SCRATCH" 0
armed_out=$(run_hook_dir "$GATE_SCRATCH" post "$GATE_ADVISORY")
if [ "$gated_rc" -eq 0 ] && [ -z "$gated_out" ] && echo "$armed_out" | grep -q '"hook":"after_goal"'; then
  ok "after_goal stands down without a marker and runs with one"
else
  nope "advisory trigger must be gated identically" "gated_rc=$gated_rc gated='$gated_out' armed='$armed_out'"
fi

# --- Case 40: a marker with an unparseable started_at falls back to mtime ---
# A hand-edited or truncated marker must not arm hooks indefinitely.
echo "Case 40: marker with unparseable started_at falls back to file mtime"
mkdir -p "$GATE_SCRATCH/.stride-copilot-lite"
printf '{"session_id":"harness","started_at":"not-a-timestamp","pid":1}\n' > "$GATE_MARKER"
fresh_out=$(run_hook_dir "$GATE_SCRATCH" pre "$GATE_BLOCKING")
if _st=$(date -d "@$(( $(date -u +%s) - 14500 ))" +%Y%m%d%H%M.%S 2>/dev/null); then :
else _st=$(date -r $(( $(date -u +%s) - 14500 )) +%Y%m%d%H%M.%S 2>/dev/null); fi
touch -t "$_st" "$GATE_MARKER" 2>/dev/null
stale_out=$(run_hook_dir "$GATE_SCRATCH" pre "$GATE_BLOCKING")
if echo "$fresh_out" | grep -q '"hook":"before_task"' && [ -z "$stale_out" ]; then
  ok "unparseable started_at → mtime decides freshness in both directions"
else
  nope "mtime fallback must judge freshness" "fresh='$fresh_out' stale='$stale_out'"
fi

rm -rf "$GATE_SCRATCH"

# ==================================================================
# Section-parsing edge cases (W2031)
# ==================================================================

# --- Case 41: a present-but-missing section no-ops ---
# Distinct from a missing .stride_lite.md (Case 1): the file exists and parses,
# but the section this trigger routes to is not in it.
echo "Case 41: missing section → no-op, exit 0, empty stdout"
NOSECTION_SCRATCH=$(mktemp -d)
write_marker "$NOSECTION_SCRATCH"
printf '## after_goal\n\n```bash\necho only-after-goal\n```\n' > "$NOSECTION_SCRATCH/.stride_lite.md"
out=$(run_hook_dir "$NOSECTION_SCRATCH" pre '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-copilot-lite:task-explorer"}}')
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  ok "before_task section absent → exit 0, no stdout"
else
  nope "missing section must no-op" "rc=0 and empty stdout" "rc=$rc stdout='$out'"
fi

# --- Case 42: an empty fenced block no-ops ---
# The section EXISTS and its fence parses; there is simply nothing to run. This
# is the documented reduced-functionality shape, not an error.
echo "Case 42: empty fenced block → no-op, exit 0, empty stdout"
printf '## before_task\n\n```bash\n```\n\n## after_goal\n\n```bash\necho x\n```\n' > "$NOSECTION_SCRATCH/.stride_lite.md"
out=$(run_hook_dir "$NOSECTION_SCRATCH" pre '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-copilot-lite:task-explorer"}}')
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  ok "empty fenced block → exit 0, no stdout"
else
  nope "empty fenced block must no-op" "rc=0 and empty stdout" "rc=$rc stdout='$out'"
fi

# --- Case 43: a comment-only block no-ops ---
# The scaffolded .stride_lite.md ships comment-only blocks, so this is the shape
# a user has on day one — it must not be mistaken for a runnable command.
echo "Case 43: comment-only block → no-op, exit 0, empty stdout"
printf '## before_task\n\n```bash\n# just a comment\n# another\n```\n' > "$NOSECTION_SCRATCH/.stride_lite.md"
out=$(run_hook_dir "$NOSECTION_SCRATCH" pre '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-copilot-lite:task-explorer"}}')
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  ok "comment-only block → exit 0, no stdout"
else
  nope "comment-only block must no-op" "rc=0 and empty stdout" "rc=$rc stdout='$out'"
fi
rm -rf "$NOSECTION_SCRATCH"

# --- Case 44: the command list stops at the first failure and partitions ---
# commands_completed + [failed_command] + commands_remaining must reconstruct the
# section exactly. A partition that drops or duplicates a command misreports what
# actually ran, which is the whole value of the failure JSON.
echo "Case 44: first failure stops the list; completed/remaining partition it"
PARTITION_SCRATCH=$(mktemp -d)
write_marker "$PARTITION_SCRATCH"
cat > "$PARTITION_SCRATCH/.stride_lite.md" <<'PEOF'
## before_task

```bash
true
printf 'second\n' > /dev/null
false
echo never-runs-1
echo never-runs-2
```
PEOF
out=$(run_hook_dir "$PARTITION_SCRATCH" pre '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-copilot-lite:task-explorer"}}')
rc=$?
# The two "never-runs" commands must be absent from stdout AND present in the
# remaining array — proving the list stopped rather than merely reporting a code.
if [ "$rc" -eq 2 ] \
  && printf '%s' "$out" | grep -q '"failed_command":"false"' \
  && printf '%s' "$out" | grep -q '"command_index":2' \
  && printf '%s' "$out" | grep -q '"commands_completed":\["true","printf .second' \
  && printf '%s' "$out" | grep -q '"commands_remaining":\["echo never-runs-1","echo never-runs-2"\]'; then
  ok "stops at the first failure; completed(2) + failed + remaining(2) partition the list"
else
  nope "failure partition" "index 2, 2 completed, 2 remaining" "rc=$rc stdout='$out'"
fi

# The commands after the failure must genuinely not have run. Assert on an
# observable side effect, not just on the JSON's own account of itself.
PARTITION_PROBE="$PARTITION_SCRATCH/ran.txt"
cat > "$PARTITION_SCRATCH/.stride_lite.md" <<PEOF
## before_task

\`\`\`bash
false
printf 'DID_RUN' > "$PARTITION_PROBE"
\`\`\`
PEOF
rm -f "$PARTITION_PROBE"
run_hook_dir "$PARTITION_SCRATCH" pre '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-copilot-lite:task-explorer"}}' >/dev/null 2>&1
if [ ! -f "$PARTITION_PROBE" ]; then
  ok "commands after the failure genuinely did not execute"
else
  nope "post-failure execution" "no side effect from the remaining command" "probe file was written"
fi
rm -rf "$PARTITION_SCRATCH"

# ==================================================================
# Cross-executor JSON parity over a shared fixture set (W2031)
# ==================================================================
#
# The env-value parity case above compares what the executors EXPORT. This
# compares what they EMIT: the same fixtures through both, with the stdout JSON
# diffed. Where PowerShell is absent this reports a skip WITH A REASON — an
# absent run must stay distinguishable from a passing one.

echo "Case 45: cross-executor JSON parity over a shared fixture set"

if ! command -v pwsh > /dev/null 2>&1; then
  ok "cross-executor JSON parity SKIPPED — pwsh not installed on this host"
else
  PARITY_SCRATCH=$(mktemp -d)

  # Two configurations, because a divergence can hide in either outcome. The
  # all-success config compares the success JSON; the all-failing one compares
  # the failure JSON — including the permissionDecision keys, whose blocking-only
  # rule is exactly the kind of thing one executor can get wrong alone.
  write_parity_config() {
    case "$1" in
      success)
        cat > "$PARITY_SCRATCH/.stride_lite.md" <<'PEOF'
## before_task

```bash
echo before-ok
```

## after_task

```bash
echo after-ok
```

## after_goal

```bash
echo goal-ok
```
PEOF
        ;;
      failing)
        cat > "$PARITY_SCRATCH/.stride_lite.md" <<'PEOF'
## before_task

```bash
false
```

## after_task

```bash
true
false
echo never
```

## after_goal

```bash
false
```
PEOF
        ;;
    esac
  }

  # Volatile fields must be normalized out, or parity would fail on timing alone.
  # duration_seconds is the only one; the pitfall list forbids timing assertions
  # and this is why — it is not a behavioural difference.
  normalize_json() {
    sed -e 's/"duration_seconds":[0-9]*/"duration_seconds":N/g' \
        -e 's/\r$//'
  }

  # Each fixture is "phase|payload". Every trigger shape, both runtimes' field
  # casing, a blocking failure and the advisory path.
  PARITY_FIXTURES=(
    'pre|{"tool_name":"Agent","tool_input":{"subagent_type":"stride-copilot-lite:task-explorer"}}'
    'pre|{"tool_name":"Write","tool_input":{"file_path":"/p/.stride-copilot-lite/lite-boundary","content":"stride-lite-boundary:before_task"}}'
    'pre|{"toolName":"create","toolArgs":"{\"file_path\":\"/p/.stride-copilot-lite/lite-boundary\",\"content\":\"stride-lite-boundary:before_task\"}"}'
    'pre|{"tool_name":"Write","tool_input":{"file_path":"/p/.stride-copilot-lite/lite-boundary","content":"stride-lite-boundary:after_task"}}'
    'post|{"tool_name":"Edit","tool_input":{"file_path":"g/goal.md","new_string":"## Completion Summary"}}'
    'post|{"toolName":"edit","toolArgs":"{\"file_path\":\"g/goal.md\",\"content\":\"## Completion Summary\"}"}'
    'pre|{"tool_name":"Bash","tool_input":{"command":"ls"}}'
    'pre|{"toolName":"create","toolArgs":"{\"file_path\":\"/p/notes.md\",\"content\":\"stride-lite-boundary:before_task\"}"}'
  )

  parity_mismatches=0
  parity_checked=0
  parity_nonempty=0
  for cfg in success failing; do
    write_parity_config "$cfg"
    for fixture in "${PARITY_FIXTURES[@]}"; do
      ph="${fixture%%|*}"
      payload="${fixture#*|}"

      # Reset the run state before EACH executor so both start identically —
      # otherwise the fired-record handshake makes the second run diverge.
      rm -rf "$PARITY_SCRATCH/.stride-copilot-lite"
      write_marker "$PARITY_SCRATCH"
      sh_out=$(printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$PARITY_SCRATCH" "$HOOK_SCRIPT" "$ph" 2>/dev/null | normalize_json)

      rm -rf "$PARITY_SCRATCH/.stride-copilot-lite"
      write_marker "$PARITY_SCRATCH"
      ps_out=$(printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$PARITY_SCRATCH" \
        pwsh -NoProfile -File "$SCRIPT_DIR/stride-copilot-lite-hook.ps1" "$ph" 2>/dev/null | normalize_json)

      parity_checked=$(( parity_checked + 1 ))
      [ -n "$sh_out" ] && parity_nonempty=$(( parity_nonempty + 1 ))
      if [ "$sh_out" != "$ps_out" ]; then
        parity_mismatches=$(( parity_mismatches + 1 ))
        echo "        DIVERGED [$cfg] on [$ph] $payload" >&2
        echo "          .sh : $sh_out" >&2
        echo "          .ps1: $ps_out" >&2
      fi
    done
  done
  rm -rf "$PARITY_SCRATCH"

  PARITY_EXPECTED=$(( ${#PARITY_FIXTURES[@]} * 2 ))
  # Guard the vacuous pass: two executors that both emit nothing agree trivially.
  # Several fixtures are deliberate no-ops, so require a healthy majority to have
  # produced actual JSON before the comparison means anything.
  if [ "$parity_checked" -eq "$PARITY_EXPECTED" ] && [ "$parity_mismatches" -eq 0 ] && [ "$parity_nonempty" -ge 8 ]; then
    ok "both executors emitted identical JSON for all $parity_checked fixtures ($parity_nonempty non-empty)"
  else
    nope "cross-executor JSON parity" "0 mismatches over $PARITY_EXPECTED fixtures, 8+ non-empty" \
      "$parity_mismatches mismatch(es), $parity_nonempty non-empty, $parity_checked checked"
  fi
fi

# --- Case 46: the suite leaves no state behind ---
# Every scratch dir is under the system temp dir and removed. A suite that leaks
# a marker directory could arm hooks for a concurrent session.
echo "Case 46: the suite leaves no state behind"
# Check the dirs THIS suite created and removed inline. A pattern-based sweep of
# the temp dir would mostly be testing the other suite's naming convention.
STILL_PRESENT=""
for d in "$DEDUPE_SCRATCH" "$SEQ_SCRATCH" "$ENV_SCRATCH" "$GATE_SCRATCH" \
         "$NOSECTION_SCRATCH" "$PARTITION_SCRATCH" "${PARITY_SCRATCH:-}"; do
  [ -n "$d" ] && [ -e "$d" ] && STILL_PRESENT="$STILL_PRESENT $d"
done
if [ -z "$STILL_PRESENT" ]; then
  ok "every inline scratch directory was removed"
else
  nope "state left behind" "all inline scratch dirs removed" "$STILL_PRESENT"
fi

# The two trap-managed dirs must actually be covered by the EXIT trap, since
# they cannot be checked after the fact from inside the run.
TRAP_LINE=$(trap -p EXIT)
if printf '%s' "$TRAP_LINE" | grep -q 'SCRATCH' && printf '%s' "$TRAP_LINE" | grep -q 'FAIL_SCRATCH'; then
  ok "the EXIT trap removes both long-lived scratch directories"
else
  nope "cleanup trap" "an EXIT trap covering SCRATCH and FAIL_SCRATCH" "$TRAP_LINE"
fi

# The repository itself must be untouched — no marker written into the checkout.
if [ ! -e "$REPO_ROOT_GUESS/.stride-copilot-lite" ]; then
  ok "no marker directory created in the repository checkout"
else
  nope "repository state" "no .stride-copilot-lite/ in the checkout" "present"
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
