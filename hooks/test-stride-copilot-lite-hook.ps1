# test-stride-copilot-lite-hook.ps1 — Smoke test for the PowerShell hook executor.
#
# Mirrors test-stride-copilot-lite-hook.sh — exercises the three .stride_lite.md
# trigger conditions plus the env-var defaulted-fallback and cross-runtime
# field-name handling (Claude Code snake_case `tool_name` vs Copilot CLI
# camelCase `toolName`).
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

# --- Failing-command fixture: three sections that each run a failing command
# (`false`, exit 1) — drives the exit-code contract cases below. Kept in its own
# scratch dir so it never perturbs the success-path .stride_lite.md above. ---
$FailScratch = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "stride-copilot-lite-fail-$([System.Guid]::NewGuid())")
New-Item -ItemType Directory -Force -Path $FailScratch | Out-Null

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

# --- Cleanup ---
Remove-Item -Recurse -Force $Scratch -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $FailScratch -ErrorAction SilentlyContinue

# --- Summary ---
Write-Host ""
Write-Host "------------------------------------------------------------------"
Write-Host "$Pass passed, $Fail failed"
if ($Fail -eq 0) { exit 0 } else { exit 1 }
