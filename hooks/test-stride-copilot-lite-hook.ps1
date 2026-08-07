# test-stride-copilot-lite-hook.ps1 — Smoke test for the PowerShell hook executor.
#
# Mirrors the bash harness case-for-case against the PowerShell executor. The two
# exercise independent implementations of one contract, and each has caught bugs
# the other could not see — run both.
#
# Every fixture command is inert and confined to a temp directory the suite
# creates and removes. No timing assertions, by design.
#
# Usage: pwsh test-stride-copilot-lite-hook.ps1
# Exit:  0 = all assertions passed; 1 = one or more failed.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$HookScript = Join-Path $ScriptDir 'stride-copilot-lite-hook.ps1'

if (-not (Test-Path $HookScript)) {
    Write-Error "stride-copilot-lite-hook.ps1 not found at $HookScript"
    exit 1
}

$Pass = 0
$Fail = 0

function Ok($label) {
    $script:Pass++
    Write-Host "  PASS  $label"
}

function Nope($label, $detail) {
    $script:Fail++
    Write-Host "  FAIL  $label" -ForegroundColor Red
    if ($detail) { Write-Host "        $detail" -ForegroundColor Red }
}

# --- Setup: scratch project dir with a working .stride_lite.md ---
$Scratch = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "stride-copilot-lite-test-$([System.Guid]::NewGuid())")
New-Item -ItemType Directory -Force -Path $Scratch | Out-Null

# Every case below simulates a tool call made INSIDE a workflow run, so each
# scratch project needs a fresh orchestrator marker (W2023). Without one the hook
# correctly stands down — which is what the dedicated gate cases assert.
function Write-Marker {
    param([string]$Dir, [int]$AgeSeconds = 0)
    $md = Join-Path $Dir '.stride-copilot-lite'
    New-Item -ItemType Directory -Force -Path $md | Out-Null
    $when = [datetime]::UtcNow.AddSeconds(-$AgeSeconds)
    $iso = $when.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $f = Join-Path $md '.orchestrator_active'
    # Direct .NET I/O rather than Set-Content/Get-Item: the provider cmdlets are
    # unreliable for dot-prefixed names here, and the mtime must be aged too so
    # the executor's mtime fallback cannot mask a started_at it should reject.
    [System.IO.File]::WriteAllText($f, "{`"session_id`":`"harness`",`"started_at`":`"$iso`",`"pid`":1}")
    [System.IO.File]::SetLastWriteTimeUtc($f, $when)
}
function Remove-Marker {
    param([string]$Dir)
    Remove-Item -Recurse -Force (Join-Path $Dir '.stride-copilot-lite') -ErrorAction SilentlyContinue
}

@'
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
'@ | Set-Content -Path (Join-Path $Scratch '.stride_lite.md')
Write-Marker $Scratch

# --- Failing-command fixture: three sections that each run a failing command
# (`false`, exit 1) — drives the exit-code contract cases below. Kept in its own
# scratch dir so it never perturbs the success-path .stride_lite.md above. ---
$FailScratch = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "stride-copilot-lite-fail-$([System.Guid]::NewGuid())")
New-Item -ItemType Directory -Force -Path $FailScratch | Out-Null
Write-Marker $FailScratch

@'
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
'@ | Set-Content -Path (Join-Path $FailScratch '.stride_lite.md')

function Run-Hook($phase, $stdinJson) {
    $env:CLAUDE_PROJECT_DIR = $Scratch
    $result = $stdinJson | pwsh -NoProfile -File $HookScript $phase 2>$null
    return $result
}

# Same as Run-Hook but against a caller-supplied project dir, so the failing-
# command fixture drives the hook without touching the success-path scratch.
# pwsh is the function's last external command, so $LASTEXITCODE in the caller
# reflects the hook's real exit code.
function Run-Hook-Dir($dir, $phase, $stdinJson) {
    $env:CLAUDE_PROJECT_DIR = $dir
    $result = $stdinJson | pwsh -NoProfile -File $HookScript $phase 2>$null
    return $result
}

# --- Case 1: missing .stride_lite.md → silent no-op ---
Write-Host "Case 1: missing .stride_lite.md"
$emptyScratch = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "stride-copilot-lite-empty-$([System.Guid]::NewGuid())")
New-Item -ItemType Directory -Force -Path $emptyScratch | Out-Null
$env:CLAUDE_PROJECT_DIR = $emptyScratch
$out = '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-copilot-lite:task-explorer"}}' | pwsh -NoProfile -File $HookScript pre 2>$null
$rc = $LASTEXITCODE
Remove-Item -Recurse -Force $emptyScratch
if ($rc -eq 0 -and -not $out) { Ok "missing .stride_lite.md → exit 0 + no stdout" }
else { Nope "missing .stride_lite.md" "rc=$rc, stdout='$out'" }

# --- Case 2: Claude Code snake_case + Agent + task-explorer → before_task ---
Write-Host "Case 2: Claude Code snake_case payload triggers before_task"
$out = Run-Hook 'pre' '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-copilot-lite:task-explorer"}}'
if ($out -match '"hook":"before_task"' -and $out -match '"status":"success"') {
    Ok "Claude Code snake_case → before_task fires"
} else { Nope "Claude Code snake_case → before_task" "stdout='$out'" }

# --- Case 3: Claude Code snake_case + Agent + task-reviewer → after_task ---
Write-Host "Case 3: Claude Code snake_case payload triggers after_task"
$out = Run-Hook 'pre' '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-copilot-lite:task-reviewer"}}'
if ($out -match '"hook":"after_task"' -and $out -match '"status":"success"') {
    Ok "Claude Code snake_case → after_task fires"
} else { Nope "Claude Code snake_case → after_task" "stdout='$out'" }

# --- Case 4: Copilot camelCase toolName fallback → before_task ---
Write-Host "Case 4: Copilot camelCase toolName triggers before_task via fallback"
$out = Run-Hook 'pre' '{"toolName":"Agent","tool_input":{"subagent_type":"stride-copilot-lite:task-explorer"}}'
if ($out -match '"hook":"before_task"') {
    Ok "Copilot camelCase toolName → before_task fires"
} else { Nope "Copilot camelCase toolName" "stdout='$out'" }

# --- Case 5: post + Edit + goal.md + Completion Summary → after_goal ---
Write-Host "Case 5: PostToolUse Edit on goal.md with Completion Summary → after_goal"
$out = Run-Hook 'post' '{"tool_name":"Edit","tool_input":{"file_path":"docs/implementation/PENDING/some-goal/goal.md","new_string":"... ## Completion Summary ..."}}'
if ($out -match '"hook":"after_goal"') {
    Ok "Edit + goal.md + Completion Summary → after_goal fires"
} else { Nope "Edit + goal.md + Completion Summary" "stdout='$out'" }

# --- Case 6: post + Edit on goal.md WITHOUT Completion Summary → no-op ---
Write-Host "Case 6: PostToolUse Edit on goal.md WITHOUT Completion Summary → no-op"
$out = Run-Hook 'post' '{"tool_name":"Edit","tool_input":{"file_path":"goal.md","new_string":"some other change"}}'
if (-not $out) {
    Ok "Edit + goal.md WITHOUT Completion Summary → no-op"
} else { Nope "Edit + goal.md WITHOUT Completion Summary should no-op" "stdout='$out'" }

# --- Case 7: non-matching tool → no-op ---
Write-Host "Case 7: non-matching tool name (Bash) → no-op"
$out = Run-Hook 'pre' '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
if (-not $out) {
    Ok "Bash tool name → no-op"
} else { Nope "Bash tool name should no-op" "stdout='$out'" }

# --- Case 8: before_task failing command → blocking exit 2 + failure JSON ---
Write-Host "Case 8: before_task failing command → blocking exit 2 + failure JSON"
$out = Run-Hook-Dir $FailScratch 'pre' '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-copilot-lite:task-explorer"}}'
$rc = $LASTEXITCODE
if ($rc -eq 2 -and $out -match '"hook":"before_task"' -and $out -match '"status":"failed"') {
    Ok "before_task failing command → exit 2 (blocking) + failed-status JSON"
} else { Nope "before_task failing command → exit 2 + failed JSON" "rc=$rc, stdout='$out'" }

# --- Case 9: after_task failing command → blocking exit 2 + failure JSON ---
Write-Host "Case 9: after_task failing command → blocking exit 2 + failure JSON"
$out = Run-Hook-Dir $FailScratch 'pre' '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-copilot-lite:task-reviewer"}}'
$rc = $LASTEXITCODE
if ($rc -eq 2 -and $out -match '"hook":"after_task"' -and $out -match '"status":"failed"') {
    Ok "after_task failing command → exit 2 (blocking) + failed-status JSON"
} else { Nope "after_task failing command → exit 2 + failed JSON" "rc=$rc, stdout='$out'" }

# --- Case 10: after_goal failing command → advisory exit 0 + failure JSON ---
# PostToolUse cannot roll back the write, so a failing after_goal command must
# still exit 0 (advisory) while emitting its failure JSON for the user.
Write-Host "Case 10: after_goal failing command → advisory exit 0 + failure JSON"
$out = Run-Hook-Dir $FailScratch 'post' '{"tool_name":"Edit","tool_input":{"file_path":"docs/implementation/PENDING/some-goal/goal.md","new_string":"... ## Completion Summary ..."}}'
$rc = $LASTEXITCODE
if ($rc -eq 0 -and $out -match '"hook":"after_goal"' -and $out -match '"status":"failed"') {
    Ok "after_goal failing command → exit 0 (advisory) + failed-status JSON"
} else { Nope "after_goal failing command → exit 0 + failed JSON" "rc=$rc, stdout='$out'" }

# ==================================================================
# Boundary-marker route (W2021) — mirrors cases 14-25 of the bash
# harness. The parity contract requires the same routing decisions.
# ==================================================================

function Clear-Fired($dir) {
    Remove-Item -Force (Join-Path (Join-Path $dir '.stride-copilot-lite') 'lite-boundary-fired') -ErrorAction SilentlyContinue
}

$MarkerCC = '{"tool_name":"Write","tool_input":{"file_path":"/p/.stride-copilot-lite/lite-boundary","content":"stride-lite-boundary:before_task"}}'
$MarkerCopBefore = '{"toolName":"create","toolArgs":"{\"file_path\":\"/p/.stride-copilot-lite/lite-boundary\",\"content\":\"stride-lite-boundary:before_task\"}"}'
$MarkerCopAfter = '{"toolName":"edit","toolArgs":"{\"file_path\":\".stride-copilot-lite/lite-boundary\",\"content\":\"stride-lite-boundary:after_task\"}"}'

# --- Case 11: Copilot CLI marker write → before_task ---
Write-Host "Case 11: Copilot CLI boundary marker triggers before_task"
Clear-Fired $Scratch
$out = Run-Hook 'pre' $MarkerCopBefore
if ($out -match '"hook":"before_task"' -and $out -match '"status":"success"') {
    Ok "Copilot marker (create + encoded toolArgs) → before_task fires"
} else { Nope "Copilot marker → before_task" "stdout='$out'" }

# --- Case 12: Copilot CLI marker write → after_task, relative path ---
Write-Host "Case 12: Copilot CLI boundary marker triggers after_task"
Clear-Fired $Scratch
$out = Run-Hook 'pre' $MarkerCopAfter
if ($out -match '"hook":"after_task"' -and $out -match '"status":"success"') {
    Ok "Copilot marker (edit, relative path) → after_task fires"
} else { Nope "Copilot marker → after_task" "stdout='$out'" }

# --- Case 13: Claude Code marker write → before_task ---
Write-Host "Case 13: Claude Code boundary marker triggers before_task"
Clear-Fired $Scratch
$out = Run-Hook 'pre' $MarkerCC
if ($out -match '"hook":"before_task"' -and $out -match '"status":"success"') {
    Ok "Claude Code marker (Write + tool_input) → before_task fires"
} else { Nope "Claude Code marker → before_task" "stdout='$out'" }

# --- Case 14: NEAR-MISS — marker path, no boundary token → no-op ---
Write-Host "Case 14: NEAR-MISS marker path without a boundary token → no-op"
Clear-Fired $Scratch
$out = Run-Hook 'pre' '{"toolName":"create","toolArgs":"{\"file_path\":\"/p/.stride-copilot-lite/lite-boundary\",\"content\":\"just some text\"}"}'
if (-not $out) { Ok "marker path + no token → no-op (no stdout)" }
else { Nope "marker path without token should no-op" "stdout='$out'" }

# --- Case 15: NEAR-MISS — boundary token, non-marker path → no-op ---
Write-Host "Case 15: NEAR-MISS boundary token written to some other file → no-op"
Clear-Fired $Scratch
$out = Run-Hook 'pre' '{"toolName":"create","toolArgs":"{\"file_path\":\"/p/docs/notes.md\",\"content\":\"stride-lite-boundary:before_task\"}"}'
if (-not $out) { Ok "boundary token + non-marker path → no-op (no stdout)" }
else { Nope "boundary token outside the marker path should no-op" "stdout='$out'" }

# --- Case 16: NEAR-MISS — marker payload in the post phase → no-op ---
Write-Host "Case 16: NEAR-MISS marker payload on PostToolUse → no-op"
Clear-Fired $Scratch
$out = Run-Hook 'post' $MarkerCopBefore
if (-not $out) { Ok "marker payload + post phase → no-op (no stdout)" }
else { Nope "marker payload in post phase should no-op" "stdout='$out'" }

# --- Case 17: NEAR-MISS — boundary token inside a bash command → no-op ---
Write-Host "Case 17: NEAR-MISS boundary token inside a bash command → no-op"
Clear-Fired $Scratch
$out = Run-Hook 'pre' '{"toolName":"bash","toolArgs":"{\"command\":\"echo stride-lite-boundary:before_task\"}"}'
if (-not $out) { Ok "boundary token in a bash command → no-op (no stdout)" }
else { Nope "boundary token in a bash command should no-op" "stdout='$out'" }

# --- Case 18: marker route then Agent dispatch → fires exactly once ---
Write-Host "Case 18: marker write + Agent dispatch → before_task fires exactly once"
$DedupeScratch = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "stride-copilot-lite-dedupe-$([System.Guid]::NewGuid())")
New-Item -ItemType Directory -Force -Path $DedupeScratch | Out-Null
Copy-Item (Join-Path $Scratch '.stride_lite.md') (Join-Path $DedupeScratch '.stride_lite.md')
Write-Marker $DedupeScratch
$first = Run-Hook-Dir $DedupeScratch 'pre' $MarkerCC
$second = Run-Hook-Dir $DedupeScratch 'pre' '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-copilot-lite:task-explorer"}}'
if ($first -match '"hook":"before_task"' -and -not $second) {
    Ok "marker fires, following Agent dispatch stands down → exactly one firing"
} else { Nope "marker+Agent should fire exactly once" "first='$first' second='$second'" }

# --- Case 19: record is consumed, so the next boundary fires again ---
Write-Host "Case 19: fired-record is consumed, so a later Agent dispatch fires again"
$third = Run-Hook-Dir $DedupeScratch 'pre' '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-copilot-lite:task-explorer"}}'
Remove-Item -Recurse -Force $DedupeScratch -ErrorAction SilentlyContinue
if ($third -match '"hook":"before_task"') {
    Ok "record consumed → next Agent dispatch fires normally"
} else { Nope "record should be consumed, not sticky" "third='$third'" }

# --- Case 20: blocking marker failure → exit 2 AND permissionDecision deny ---
Write-Host "Case 20: blocking marker failure → exit 2 + permissionDecision deny"
Clear-Fired $FailScratch
$out = Run-Hook-Dir $FailScratch 'pre' $MarkerCopBefore
$rc = $LASTEXITCODE
if ($rc -eq 2 -and $out -match '"status":"failed"' -and $out -match '"permissionDecision":"deny"' -and $out -match '"permissionDecisionReason":') {
    Ok "blocking failure → exit 2 AND permissionDecision deny (both runtimes stop)"
} else { Nope "blocking failure must emit exit 2 + deny" "rc=$rc, stdout='$out'" }

# --- Case 21: advisory after_goal failure must NOT deny ---
Write-Host "Case 21: advisory after_goal failure → no permissionDecision"
$out = Run-Hook-Dir $FailScratch 'post' '{"tool_name":"Edit","tool_input":{"file_path":"g/goal.md","new_string":"## Completion Summary"}}'
$rc = $LASTEXITCODE
if ($rc -eq 0 -and $out -match '"status":"failed"' -and $out -notmatch 'permissionDecision') {
    Ok "advisory after_goal failure → exit 0 and NO deny"
} else { Nope "after_goal must not deny" "rc=$rc, stdout='$out'" }

# --- Case 22: after_goal fires on a Copilot-shaped payload ---
Write-Host "Case 22: after_goal fires on a Copilot CLI encoded-toolArgs payload"
$out = Run-Hook 'post' '{"toolName":"edit","toolArgs":"{\"file_path\":\"/p/g/goal.md\",\"content\":\"## Completion Summary\"}"}'
if ($out -match '"hook":"after_goal"' -and $out -match '"status":"success"') {
    Ok "Copilot encoded toolArgs → after_goal fires"
} else { Nope "Copilot encoded toolArgs → after_goal" "stdout='$out'" }

# --- Case 23: full simulated workflow pass → each hook fires exactly once, in order ---
Write-Host "Case 23: full workflow pass → before_task, after_task, after_goal once each, in order"
$SeqScratch = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "stride-copilot-lite-seq-$([System.Guid]::NewGuid())")
New-Item -ItemType Directory -Force -Path $SeqScratch | Out-Null
Copy-Item (Join-Path $Scratch '.stride_lite.md') (Join-Path $SeqScratch '.stride_lite.md')
Write-Marker $SeqScratch
$seqEvents = @(
    @('pre',  $MarkerCC),
    @('pre',  '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-copilot-lite:task-explorer"}}'),
    @('pre',  '{"tool_name":"Write","tool_input":{"file_path":"/p/.stride-copilot-lite/lite-boundary","content":"stride-lite-boundary:after_task"}}'),
    @('pre',  '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-copilot-lite:task-reviewer"}}'),
    @('post', '{"tool_name":"Edit","tool_input":{"file_path":"g/goal.md","new_string":"## Completion Summary"}}')
)
$fired = @()
foreach ($ev in $seqEvents) {
    # A stood-down route returns nothing; [regex]::Matches would throw on null.
    $o = Run-Hook-Dir $SeqScratch $ev[0] $ev[1]
    if ($o) {
        foreach ($m in [regex]::Matches([string]$o, '"hook":"([a-z_]+)"')) { $fired += $m.Groups[1].Value }
    }
}
Remove-Item -Recurse -Force $SeqScratch -ErrorAction SilentlyContinue
$seqOrder = ($fired -join ' ')
if ($fired.Count -eq 3 -and $seqOrder -eq 'before_task after_task after_goal') {
    Ok "full workflow pass → 3 firings in order: $seqOrder"
} else { Nope "full workflow pass should fire each hook once, in order" "count=$($fired.Count) order='$seqOrder'" }

# ==================================================================
# Hook environment injection (W2022) — mirrors bash cases 27-32.
# ==================================================================

$EnvScratch = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "stride-copilot-lite-env-$([System.Guid]::NewGuid())")
$GoalRel = 'docs/implementation/PENDING/add-notifications'
New-Item -ItemType Directory -Force -Path (Join-Path $EnvScratch $GoalRel) | Out-Null
$EnvProbe = Join-Path $EnvScratch 'probe.txt'
Set-Content -LiteralPath (Join-Path $EnvScratch "$GoalRel/goal.md") -Value "# Add real-time notifications`n`nbody" -Encoding UTF8
Set-Content -LiteralPath (Join-Path $EnvScratch "$GoalRel/task2.md") -Value '# Subscribe $(id) `whoami` ${HOME}' -Encoding UTF8

$probeCmd = 'printf ''%s\n'' "HOOK_NAME=$HOOK_NAME" "AGENT_NAME=$AGENT_NAME" "TASK_FILE=$TASK_FILE" "TASK_NUMBER=$TASK_NUMBER" "TASK_TITLE=$TASK_TITLE" "GOAL_DIR=$GOAL_DIR" "GOAL_FILE=$GOAL_FILE" "GOAL_SLUG=$GOAL_SLUG" "GOAL_TITLE=$GOAL_TITLE" > "' + $EnvProbe + '"'
$goalCmd  = 'printf ''%s\n'' "HOOK_NAME=$HOOK_NAME" "TASK_NUMBER=$TASK_NUMBER" "GOAL_SLUG=$GOAL_SLUG" "GOAL_TITLE=$GOAL_TITLE" > "' + $EnvProbe + '"'
Set-Content -LiteralPath (Join-Path $EnvScratch '.stride_lite.md') -Encoding UTF8 -Value @"
## before_task

``````bash
$probeCmd
``````

## after_goal

``````bash
$goalCmd
``````
"@

function Get-Probe($key) {
    if (-not (Test-Path -LiteralPath $EnvProbe)) { return '' }
    foreach ($l in (Get-Content -LiteralPath $EnvProbe -Encoding UTF8)) {
        if ($l.StartsWith("$key=")) { return $l.Substring($key.Length + 1) }
    }
    return ''
}

Write-Marker $EnvScratch

$TaskRel = "$GoalRel/task2.md"

# --- Case 24: every documented key reaches the executed command ---
Write-Host "Case 24: all nine exported keys reach the command"
Remove-Item -LiteralPath $EnvProbe -ErrorAction SilentlyContinue
$null = Run-Hook-Dir $EnvScratch 'pre' "{`"tool_name`":`"Write`",`"tool_input`":{`"file_path`":`"/p/.stride-copilot-lite/lite-boundary`",`"content`":`"stride-lite-boundary:before_task:$TaskRel`"}}"
$missing = @()
foreach ($k in @('HOOK_NAME','AGENT_NAME','TASK_FILE','TASK_NUMBER','TASK_TITLE','GOAL_DIR','GOAL_FILE','GOAL_SLUG','GOAL_TITLE')) {
    if (-not (Test-Path -LiteralPath $EnvProbe)) { $missing += $k; continue }
    if (-not ((Get-Content -LiteralPath $EnvProbe -Encoding UTF8) -match "^$k=")) { $missing += $k }
}
if ($missing.Count -eq 0 -and (Get-Probe 'HOOK_NAME') -eq 'before_task' -and (Get-Probe 'AGENT_NAME') -eq 'stride-copilot-lite' `
    -and (Get-Probe 'TASK_NUMBER') -eq '2' -and (Get-Probe 'GOAL_SLUG') -eq 'add-notifications' `
    -and (Get-Probe 'GOAL_TITLE') -eq 'Add real-time notifications') {
    Ok "all nine keys exported; TASK_NUMBER=2, GOAL_SLUG and GOAL_TITLE derived"
} else { Nope "exported key set incomplete or wrong" "missing='$($missing -join ',')' number='$(Get-Probe 'TASK_NUMBER')' slug='$(Get-Probe 'GOAL_SLUG')'" }

# --- Case 25: a metacharacter-bearing title is inert ---
Write-Host "Case 25: shell metacharacters in a task title are inert"
$t = Get-Probe 'TASK_TITLE'
if ($t -eq 'Subscribe $(id) `whoami` ${HOME}') {
    Ok "title reached the command verbatim; nothing expanded or executed"
} else { Nope "title must arrive literal" "got='$t'" }

# --- Case 26: a marker with no task path → task keys empty, hook still fires ---
Write-Host "Case 26: marker without a task path → empty task keys, unchanged exit code"
Remove-Item -LiteralPath $EnvProbe -ErrorAction SilentlyContinue
$out = Run-Hook-Dir $EnvScratch 'pre' '{"tool_name":"Write","tool_input":{"file_path":"/p/.stride-copilot-lite/lite-boundary","content":"stride-lite-boundary:before_task"}}'
$rc = $LASTEXITCODE
if ($rc -eq 0 -and $out -match '"status":"success"' -and -not (Get-Probe 'TASK_FILE') -and -not (Get-Probe 'TASK_NUMBER')) {
    Ok "undeterminable keys export as defined-but-empty; hook fires, exit 0"
} else { Nope "missing task path must degrade, not fail" "rc=$rc file='$(Get-Probe 'TASK_FILE')'" }

# --- Case 27: a path escaping the project directory is rejected ---
Write-Host "Case 27: task path outside the project directory is rejected"
Remove-Item -LiteralPath $EnvProbe -ErrorAction SilentlyContinue
$null = Run-Hook-Dir $EnvScratch 'pre' '{"tool_name":"Write","tool_input":{"file_path":"/p/.stride-copilot-lite/lite-boundary","content":"stride-lite-boundary:before_task:../../../../../../etc/passwd"}}'
if (-not (Get-Probe 'TASK_FILE') -and -not (Get-Probe 'TASK_TITLE')) {
    Ok "traversal path rejected → TASK_FILE and TASK_TITLE empty"
} else { Nope "path outside the project must be rejected" "file='$(Get-Probe 'TASK_FILE')'" }

# --- Case 28: after_goal derives goal context and no task context ---
Write-Host "Case 28: after_goal exports goal keys and empty task keys"
Remove-Item -LiteralPath $EnvProbe -ErrorAction SilentlyContinue
$null = Run-Hook-Dir $EnvScratch 'post' "{`"tool_name`":`"Edit`",`"tool_input`":{`"file_path`":`"$GoalRel/goal.md`",`"new_string`":`"## Completion Summary`"}}"
if ((Get-Probe 'HOOK_NAME') -eq 'after_goal' -and (Get-Probe 'GOAL_SLUG') -eq 'add-notifications' `
    -and (Get-Probe 'GOAL_TITLE') -eq 'Add real-time notifications' -and -not (Get-Probe 'TASK_NUMBER')) {
    Ok "after_goal → goal keys derived, task keys empty"
} else { Nope "after_goal goal-context derivation" "hook='$(Get-Probe 'HOOK_NAME')' slug='$(Get-Probe 'GOAL_SLUG')'" }

Remove-Item -Recurse -Force $EnvScratch -ErrorAction SilentlyContinue

# ==================================================================
# Orchestrator activation gate (W2023) — mirrors bash cases 34-40.
# ==================================================================

$GateScratch = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "stride-copilot-lite-gate-$([System.Guid]::NewGuid())")
New-Item -ItemType Directory -Force -Path $GateScratch | Out-Null
Set-Content -LiteralPath (Join-Path $GateScratch '.stride_lite.md') -Encoding UTF8 -Value @"
## before_task

``````bash
echo GATE_BEFORE
``````

## after_goal

``````bash
echo GATE_AFTER_GOAL
``````
"@
$GateBlocking = '{"tool_name":"Write","tool_input":{"file_path":"/p/.stride-copilot-lite/lite-boundary","content":"stride-lite-boundary:before_task"}}'
$GateAdvisory = '{"tool_name":"Edit","tool_input":{"file_path":"g/goal.md","new_string":"## Completion Summary"}}'

# --- Case 29: fresh marker → the section runs ---
Write-Host "Case 29: fresh marker → blocking trigger runs its section"
Write-Marker $GateScratch 0
$out = Run-Hook-Dir $GateScratch 'pre' $GateBlocking
if ($out -match '"hook":"before_task"' -and $out -match '"status":"success"') {
    Ok "fresh marker → before_task runs"
} else { Nope "fresh marker must run the section" "stdout='$out'" }

# --- Case 30: no marker → stands down, exit 0, empty stdout, no block ---
Write-Host "Case 30: no marker → blocking trigger stands down, exit 0, empty stdout"
Remove-Marker $GateScratch
$out = Run-Hook-Dir $GateScratch 'pre' $GateBlocking
$rc = $LASTEXITCODE
if ($rc -eq 0 -and -not $out) {
    Ok "missing marker → nothing runs, exit 0 (tool call not blocked)"
} else { Nope "missing marker must stand down without blocking" "rc=$rc stdout='$out'" }

# --- Case 31: stale marker (older than 4h) → stands down ---
Write-Host "Case 31: marker older than 4 hours → stands down"
Write-Marker $GateScratch 14500
$out = Run-Hook-Dir $GateScratch 'pre' $GateBlocking
$rc = $LASTEXITCODE
if ($rc -eq 0 -and -not $out) {
    Ok "stale marker → nothing runs, exit 0"
} else { Nope "a marker past the freshness window must not arm hooks" "rc=$rc stdout='$out'" }

# --- Case 32: a marker just inside the window still fires ---
Write-Host "Case 32: marker just inside the 4-hour window still fires"
Write-Marker $GateScratch 14000
$out = Run-Hook-Dir $GateScratch 'pre' $GateBlocking
if ($out -match '"hook":"before_task"') {
    Ok "marker inside the window → section runs"
} else { Nope "a marker inside the window must still fire" "stdout='$out'" }

# --- Case 33: override bypasses the gate ---
Write-Host "Case 33: STRIDE_COPILOT_LITE_ALLOW_DIRECT=1 bypasses a missing marker"
Remove-Marker $GateScratch
$env:STRIDE_COPILOT_LITE_ALLOW_DIRECT = '1'
$out = Run-Hook-Dir $GateScratch 'pre' $GateBlocking
Remove-Item Env:\STRIDE_COPILOT_LITE_ALLOW_DIRECT -ErrorAction SilentlyContinue
if ($out -match '"hook":"before_task"') {
    Ok "override → section runs with no marker present"
} else { Nope "override must bypass the gate" "stdout='$out'" }

# --- Case 34: the advisory trigger is gated too ---
Write-Host "Case 34: advisory after_goal trigger is gated on the same marker"
Remove-Marker $GateScratch
$gatedOut = Run-Hook-Dir $GateScratch 'post' $GateAdvisory
$gatedRc = $LASTEXITCODE
Write-Marker $GateScratch 0
$armedOut = Run-Hook-Dir $GateScratch 'post' $GateAdvisory
if ($gatedRc -eq 0 -and -not $gatedOut -and $armedOut -match '"hook":"after_goal"') {
    Ok "after_goal stands down without a marker and runs with one"
} else { Nope "advisory trigger must be gated identically" "gatedRc=$gatedRc gated='$gatedOut' armed='$armedOut'" }

Remove-Item -Recurse -Force $GateScratch -ErrorAction SilentlyContinue

# ==================================================================
# Coverage parity with the bash harness (W2031)
# ==================================================================

# --- Case 35: Copilot lowercase 'edit' triggers after_goal ---
Write-Host "Case 35: Copilot lowercase 'edit' triggers after_goal"
$out = Run-Hook 'post' '{"toolName":"edit","tool_input":{"file_path":"goal.md","new_string":"## Completion Summary"}}'
if ($out -match '"hook":"after_goal"') {
    Ok "Copilot 'edit' + goal.md + Completion Summary → after_goal fires"
} else { Nope "Copilot lowercase 'edit'" "stdout='$out'" }

# --- Case 36: Agent dispatch to a non-stride-copilot-lite subagent → no-op ---
Write-Host "Case 36: Agent with another subagent_type → no-op"
$out = Run-Hook 'pre' '{"tool_name":"Agent","tool_input":{"subagent_type":"Explore"}}'
if (-not $out) { Ok "Agent + non-matching subagent_type → no-op" }
else { Nope "non-matching subagent_type should no-op" "stdout='$out'" }

# --- Case 37: CLAUDE_PROJECT_DIR unset → falls back to the current directory ---
Write-Host "Case 37: env-var defaulted-fallback when CLAUDE_PROJECT_DIR unset"
$savedDir = $env:CLAUDE_PROJECT_DIR
$savedLoc = Get-Location
Remove-Item Env:\CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue
Set-Location $Scratch
$out = '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-copilot-lite:task-explorer"}}' |
    pwsh -NoProfile -File $HookScript pre 2>$null
Set-Location $savedLoc
if ($savedDir) { $env:CLAUDE_PROJECT_DIR = $savedDir }
if ($out -match '"hook":"before_task"') {
    Ok "unset CLAUDE_PROJECT_DIR + cwd .stride_lite.md → before_task fires"
} else { Nope "CLAUDE_PROJECT_DIR fallback" "stdout='$out'" }

# --- Case 38: the failure JSON carries no exported environment values ---
Write-Host "Case 38: failure JSON carries no exported environment values"
$LeakScratch = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "stride-copilot-lite-leak-$([System.Guid]::NewGuid())")
New-Item -ItemType Directory -Force -Path (Join-Path $LeakScratch 'g') | Out-Null
Write-Marker $LeakScratch
Set-Content -LiteralPath (Join-Path $LeakScratch 'g/goal.md') -Value '# Secret Goal Title' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $LeakScratch 'g/task2.md') -Value '# Secret Task Title' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $LeakScratch '.stride_lite.md') -Encoding UTF8 -Value @"
## before_task

``````bash
false
``````
"@
$out = Run-Hook-Dir $LeakScratch 'pre' '{"tool_name":"Write","tool_input":{"file_path":"/p/.stride-copilot-lite/lite-boundary","content":"stride-lite-boundary:before_task:g/task2.md"}}'
Remove-Item -Recurse -Force $LeakScratch -ErrorAction SilentlyContinue
if ($out -match '"status":"failed"' -and $out -notmatch 'Secret Task Title' `
    -and $out -notmatch 'Secret Goal Title' -and $out -notmatch 'TASK_TITLE' -and $out -notmatch 'GOAL_SLUG') {
    Ok "failure JSON contains no derived env values"
} else { Nope "failure JSON must not carry env values" "stdout='$out'" }

# --- Case 39: unparseable started_at falls back to the file's mtime ---
Write-Host "Case 39: marker with unparseable started_at falls back to file mtime"
$MtimeScratch = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "stride-copilot-lite-mtime-$([System.Guid]::NewGuid())")
New-Item -ItemType Directory -Force -Path (Join-Path $MtimeScratch '.stride-copilot-lite') | Out-Null
Set-Content -LiteralPath (Join-Path $MtimeScratch '.stride_lite.md') -Encoding UTF8 -Value @"
## before_task

``````bash
echo MTIME_OK
``````
"@
$mf = Join-Path (Join-Path $MtimeScratch '.stride-copilot-lite') '.orchestrator_active'
[System.IO.File]::WriteAllText($mf, '{"session_id":"harness","started_at":"not-a-timestamp","pid":1}')
[System.IO.File]::SetLastWriteTimeUtc($mf, [datetime]::UtcNow)
$freshOut = Run-Hook-Dir $MtimeScratch 'pre' $GateBlocking
[System.IO.File]::SetLastWriteTimeUtc($mf, [datetime]::UtcNow.AddSeconds(-14500))
$staleOut = Run-Hook-Dir $MtimeScratch 'pre' $GateBlocking
Remove-Item -Recurse -Force $MtimeScratch -ErrorAction SilentlyContinue
if ($freshOut -match '"hook":"before_task"' -and -not $staleOut) {
    Ok "unparseable started_at → mtime decides freshness in both directions"
} else { Nope "mtime fallback must judge freshness" "fresh='$freshOut' stale='$staleOut'" }

# --- Cases 40-42: section-parsing edge cases ---
$EdgeScratch = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "stride-copilot-lite-edge-$([System.Guid]::NewGuid())")
New-Item -ItemType Directory -Force -Path $EdgeScratch | Out-Null
Write-Marker $EdgeScratch
$explorerPayload = '{"tool_name":"Agent","tool_input":{"subagent_type":"stride-copilot-lite:task-explorer"}}'

Write-Host "Case 40: missing section → no-op, exit 0, empty stdout"
Set-Content -LiteralPath (Join-Path $EdgeScratch '.stride_lite.md') -Encoding UTF8 -Value @"
## after_goal

``````bash
echo only-after-goal
``````
"@
$out = Run-Hook-Dir $EdgeScratch 'pre' $explorerPayload
$rc = $LASTEXITCODE
if ($rc -eq 0 -and -not $out) { Ok "before_task section absent → exit 0, no stdout" }
else { Nope "missing section must no-op" "rc=$rc stdout='$out'" }

Write-Host "Case 41: empty fenced block → no-op, exit 0, empty stdout"
Set-Content -LiteralPath (Join-Path $EdgeScratch '.stride_lite.md') -Encoding UTF8 -Value @"
## before_task

``````bash
``````
"@
$out = Run-Hook-Dir $EdgeScratch 'pre' $explorerPayload
$rc = $LASTEXITCODE
if ($rc -eq 0 -and -not $out) { Ok "empty fenced block → exit 0, no stdout" }
else { Nope "empty fenced block must no-op" "rc=$rc stdout='$out'" }

Write-Host "Case 42: comment-only block → no-op, exit 0, empty stdout"
Set-Content -LiteralPath (Join-Path $EdgeScratch '.stride_lite.md') -Encoding UTF8 -Value @"
## before_task

``````bash
# just a comment
# another
``````
"@
$out = Run-Hook-Dir $EdgeScratch 'pre' $explorerPayload
$rc = $LASTEXITCODE
if ($rc -eq 0 -and -not $out) { Ok "comment-only block → exit 0, no stdout" }
else { Nope "comment-only block must no-op" "rc=$rc stdout='$out'" }

# --- Case 43: first failure stops the list; completed/remaining partition it ---
Write-Host "Case 43: first failure stops the list; completed/remaining partition it"
Set-Content -LiteralPath (Join-Path $EdgeScratch '.stride_lite.md') -Encoding UTF8 -Value @"
## before_task

``````bash
true
printf 'second\n' > /dev/null
false
echo never-runs-1
echo never-runs-2
``````
"@
$out = Run-Hook-Dir $EdgeScratch 'pre' $explorerPayload
$rc = $LASTEXITCODE
if ($rc -eq 2 -and $out -match '"failed_command":"false"' -and $out -match '"command_index":2' `
    -and $out -match '"commands_remaining":\["echo never-runs-1","echo never-runs-2"\]') {
    Ok "stops at the first failure; completed(2) + failed + remaining(2) partition the list"
} else { Nope "failure partition" "rc=2, index 2, 2 remaining" "rc=$rc stdout='$out'" }

# The remaining commands must genuinely not have run — assert a side effect.
$ranProbe = Join-Path $EdgeScratch 'ran.txt'
Set-Content -LiteralPath (Join-Path $EdgeScratch '.stride_lite.md') -Encoding UTF8 -Value @"
## before_task

``````bash
false
printf 'DID_RUN' > "$ranProbe"
``````
"@
Remove-Item -LiteralPath $ranProbe -ErrorAction SilentlyContinue
$null = Run-Hook-Dir $EdgeScratch 'pre' $explorerPayload
if (-not (Test-Path -LiteralPath $ranProbe)) {
    Ok "commands after the failure genuinely did not execute"
} else { Nope "post-failure execution" "no side effect" "probe file was written" }
Remove-Item -Recurse -Force $EdgeScratch -ErrorAction SilentlyContinue

# --- Case 44: the suite leaves no state behind ---
Write-Host "Case 44: the suite leaves no state behind"
$stillPresent = @()
foreach ($d in @($DedupeScratch, $SeqScratch, $EnvScratch, $GateScratch, $LeakScratch, $MtimeScratch, $EdgeScratch)) {
    if ($d -and (Test-Path -LiteralPath $d)) { $stillPresent += $d }
}
if ($stillPresent.Count -eq 0) { Ok "every inline scratch directory was removed" }
else { Nope "state left behind" "$($stillPresent -join ', ')" }

$repoRoot = Split-Path -Parent $ScriptDir
if (-not (Test-Path -LiteralPath (Join-Path $repoRoot '.stride-copilot-lite'))) {
    Ok "no marker directory created in the repository checkout"
} else { Nope "repository state" "no .stride-copilot-lite/ in the checkout" }

# --- Cleanup ---
Remove-Item -Recurse -Force $Scratch -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $FailScratch -ErrorAction SilentlyContinue

# --- Summary ---
Write-Host ""
Write-Host "------------------------------------------------------------------"
Write-Host "$Pass passed, $Fail failed"
if ($Fail -eq 0) { exit 0 } else { exit 1 }
