param(
    [Parameter(Position = 0)]
    [string]$Phase = ''
)

# stride-copilot-lite-hook.ps1 — Bridges harness hooks to stride-copilot-lite .stride_lite.md hook execution.
#
# PowerShell companion to stride-copilot-lite-hook.sh for Windows compatibility.
# Called by the harness's PreToolUse/PostToolUse hooks (configured in hooks.json).
# Receives the hook JSON on stdin, determines whether the tool call is one of the
# three stride-copilot-lite trigger conditions, and if so executes the corresponding
# `## before_task` / `## after_task` / `## after_goal` section from .stride_lite.md.
#
# Trigger conditions (identical to stride-copilot-lite-hook.sh):
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
# each task boundary and the write itself is the interceptable event. Routing requires BOTH
# the exact marker path AND the exact boundary token, so a write to some other path, or a
# marker carrying neither token, fires nothing.
#
# The Agent route is retained unchanged for Claude Code. To keep each boundary firing exactly
# once on a runtime that emits both events, the marker route records the boundary it fired in
# .stride/lite-boundary-fired and the Agent route consumes that record instead of re-firing.
#
# Harness compatibility: handles both Claude Code (PascalCase tool_name; tool_input as
# object) and GitHub Copilot CLI (camelCase toolName; toolArgs as JSON-encoded string).
#
# Usage: echo '<hook-json>' | pwsh stride-copilot-lite-hook.ps1 <pre|post>
#
# Exit codes:
#   0 — success, no-op, or non-trigger
#   2 — blocking PreToolUse failure (only meaningful for pre + before_task/after_task)
#
# Blocking contract (dual-runtime). Claude Code blocks a PreToolUse tool call on exit 2.
# Copilot CLI ignores exit codes and blocks on a stdout {"permissionDecision":"deny"} object.
# A blocking failure therefore emits BOTH: the permissionDecision keys are added to the same
# single-line failure JSON this script already emits AND the process exits 2. Emitting only
# one would let a failing before_task stop the workflow on one runtime while the other
# silently continued.
#
# Cross-platform parity contract: this script and stride-copilot-lite-hook.sh MUST detect
# the same three trigger conditions, produce equivalent single-line JSON results
# for the same input, and apply the same exit-code contract.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectDir = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { '.' }
$StrideLiteMd = Join-Path $ProjectDir '.stride_lite.md'

# Boundary-marker route (W2021). Transient session state under .stride/, which the
# plugin's .gitignore already excludes.
$BoundaryFiredFile = Join-Path (Join-Path $ProjectDir '.stride') 'lite-boundary-fired'

# Marker route <-> Agent route de-duplication. Claude Code emits BOTH events for one
# boundary; the marker route fires first and records the boundary, and the Agent route
# consumes that record and stands down. Consuming rather than merely reading is what
# lets the reviewer loop's second after_task fire correctly.
function Test-BoundaryConsumeFired {
    param([string]$Want)
    if (-not (Test-Path $BoundaryFiredFile)) { return $false }
    try {
        $last = (Get-Content $BoundaryFiredFile -Raw -Encoding UTF8).Trim()
    } catch {
        return $false
    }
    if ($last -ne $Want) { return $false }
    Remove-Item -Force $BoundaryFiredFile -ErrorAction SilentlyContinue
    return $true
}

function Set-BoundaryFired {
    param([string]$Boundary)
    try {
        $dir = Split-Path -Parent $BoundaryFiredFile
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [System.IO.File]::WriteAllText($BoundaryFiredFile, $Boundary)
    } catch {
        # Best-effort only — an unwritable state dir must never fail the hook.
    }
}

if (-not $Phase) { exit 0 }
if (-not (Test-Path $StrideLiteMd)) { exit 0 }

# Read the harness hook input from stdin.
# Must be [Console]::In, not the automatic $input variable: this script is invoked as
# `pwsh -File ... <phase>` with the payload piped in, and a -File script whose param()
# block declares no pipeline-bound parameter cannot bind piped input — PowerShell raises
# "The input object cannot be bound to any parameters" and $input stays empty, so every
# trigger silently no-opped under every runtime. Reading the stream directly sidesteps
# parameter binding entirely and works the same on Windows PowerShell and pwsh.
$InputJson = [Console]::In.ReadToEnd()
if (-not $InputJson) { exit 0 }

# --- Pure JSON parsing via built-in ConvertFrom-Json (no module installs) ---
$ToolName = ''
$SubagentType = ''
$FilePath = ''
try {
    $parsed = $InputJson | ConvertFrom-Json
    # Claude Code uses tool_name + tool_input (object). Copilot CLI uses toolName + toolArgs
    # (JSON-encoded string). Try both.
    if ($parsed.PSObject.Properties.Name -contains 'tool_name') {
        $ToolName = [string]$parsed.tool_name
    }
    if (-not $ToolName -and $parsed.PSObject.Properties.Name -contains 'toolName') {
        $ToolName = [string]$parsed.toolName
    }
    if ($parsed.PSObject.Properties.Name -contains 'tool_input' -and $parsed.tool_input) {
        $ti = $parsed.tool_input
        if ($ti.PSObject.Properties.Name -contains 'subagent_type') {
            $SubagentType = [string]$ti.subagent_type
        }
        if ($ti.PSObject.Properties.Name -contains 'file_path') {
            $FilePath = [string]$ti.file_path
        }
    }
    if (-not $FilePath -and $parsed.PSObject.Properties.Name -contains 'toolArgs' -and $parsed.toolArgs) {
        # Copilot CLI: toolArgs is a JSON-encoded string. Decode once more.
        try {
            $tArgs = $parsed.toolArgs | ConvertFrom-Json
            if ($tArgs.PSObject.Properties.Name -contains 'file_path') {
                $FilePath = [string]$tArgs.file_path
            }
        } catch {
            # toolArgs not parseable as JSON — leave $FilePath empty.
        }
    }
} catch {
    # Malformed JSON — silent no-op.
    exit 0
}

# --- Determine which stride-lite hook to run ---
$HookName = ''
$Blocking = $false
$MarkerRoute = $false

switch ($Phase) {
    'pre' {
        # Agent is Claude Code's subagent-dispatch tool name. Copilot CLI emits no
        # equivalent event, so this branch fires only under Claude Code — where it
        # stands down if the marker route already handled the boundary.
        if ($ToolName -eq 'Agent') {
            switch ($SubagentType) {
                'stride-copilot-lite:task-explorer' { $HookName = 'before_task'; $Blocking = $true }
                'stride-copilot-lite:task-reviewer' { $HookName = 'after_task';  $Blocking = $true }
            }
            if ($HookName -and (Test-BoundaryConsumeFired -Want $HookName)) {
                exit 0
            }
        }
        elseif ($ToolName -eq 'Edit' -or $ToolName -eq 'Write' -or $ToolName -eq 'edit' -or $ToolName -eq 'create') {
            # Runtime-native boundary intercept: the workflow skill's write of the
            # boundary marker. Requires BOTH the exact plugin-owned path AND an exact
            # boundary token in the written body — either alone routes to nothing.
            if ($FilePath -match '(^|[/\\])\.stride[/\\]lite-boundary$') {
                if ($InputJson -match 'stride-lite-boundary:before_task') {
                    $HookName = 'before_task'; $Blocking = $true; $MarkerRoute = $true
                }
                elseif ($InputJson -match 'stride-lite-boundary:after_task') {
                    $HookName = 'after_task';  $Blocking = $true; $MarkerRoute = $true
                }
            }
        }
    }
    'post' {
        if ($ToolName -eq 'Edit' -or $ToolName -eq 'Write' -or $ToolName -eq 'edit' -or $ToolName -eq 'create') {
            if ($FilePath -match '(^|[/\\])goal\.md$') {
                # "## Completion Summary" detection — scan the entire hook JSON.
                # In goal.md edits, this string only appears in the Edit new_string
                # or Write content body, so a substring match is reliable.
                if ($InputJson -match '## Completion Summary') {
                    $HookName = 'after_goal'
                    $Blocking = $false
                }
            }
        }
    }
}

if (-not $HookName) { exit 0 }

# --- Parse and execute one .stride_lite.md hook section ---
# Returns:
#   0 — section missing OR empty fenced block OR all commands succeeded
#   2 — first command failed; structured failure JSON emitted on stdout
function Invoke-StrideLiteSection {
    param([string]$Section, [bool]$IsBlocking = $false)

    $raw = Get-Content $StrideLiteMd -Raw -Encoding UTF8
    $raw = $raw -replace "`r`n", "`n"
    $lines = $raw -split "`n"

    $commandsText = ''
    $found = $false
    $capture = $false

    foreach ($rawLine in $lines) {
        $line = $rawLine.TrimEnd("`r")

        if ($line -match '^## (.+)$') {
            if ($found) { break }
            $heading = $Matches[1].TrimEnd()
            if ($heading -eq $Section) { $found = $true }
            continue
        }

        if ($found) {
            if ($line -match '^```bash') {
                $capture = $true
                continue
            }
            if ($line -match '^```') {
                if ($capture) { break }
                continue
            }
            if ($capture) {
                $commandsText += $line + "`n"
            }
        }
    }

    if (-not $commandsText.Trim()) {
        return 0
    }

    $cmdList = @()
    foreach ($cmd in ($commandsText -split "`n")) {
        $trimmedCmd = $cmd.TrimStart()
        if (-not $trimmedCmd) { continue }
        if ($trimmedCmd.StartsWith('#')) { continue }
        $cmdList += $trimmedCmd
    }

    if ($cmdList.Count -eq 0) {
        return 0
    }

    Set-Location $ProjectDir
    $completedCmds = @()
    $startTime = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $cmdIndex = 0
    $cmdTotal = $cmdList.Count

    foreach ($execTrimmed in $cmdList) {
        $stdoutFile = [System.IO.Path]::GetTempFileName()
        $stderrFile = [System.IO.Path]::GetTempFileName()

        try {
            # Delegate user command execution to bash so .stride_lite.md content
            # stays POSIX-portable (git-bash on Windows ships bash.exe; WSL also
            # provides one). Users who want native PowerShell can wrap their line
            # with `pwsh -c '...'` inside their bash block.
            $proc = Start-Process -FilePath 'bash' -ArgumentList '-c', $execTrimmed `
                -RedirectStandardOutput $stdoutFile `
                -RedirectStandardError $stderrFile `
                -NoNewWindow -Wait -PassThru

            if ($proc.ExitCode -eq 0) {
                $completedCmds += $execTrimmed
                if (Test-Path $stdoutFile) {
                    $stdoutText = Get-Content $stdoutFile -Raw -Encoding UTF8
                    if ($stdoutText) { [Console]::Error.Write($stdoutText) }
                }
                if (Test-Path $stderrFile) {
                    $stderrText = Get-Content $stderrFile -Raw -Encoding UTF8
                    if ($stderrText) { [Console]::Error.Write($stderrText) }
                }
            } else {
                $cmdExit = $proc.ExitCode
                $cmdStdout = ''
                $cmdStderr = ''
                if (Test-Path $stdoutFile) {
                    $allLines = @(Get-Content $stdoutFile -Encoding UTF8)
                    if ($allLines.Count -gt 50) { $allLines = $allLines[-50..-1] }
                    $cmdStdout = $allLines -join "`n"
                }
                if (Test-Path $stderrFile) {
                    $allLines = @(Get-Content $stderrFile -Encoding UTF8)
                    if ($allLines.Count -gt 50) { $allLines = $allLines[-50..-1] }
                    $cmdStderr = $allLines -join "`n"
                }
                Remove-Item -Force $stdoutFile, $stderrFile -ErrorAction SilentlyContinue

                $remainingCmds = @()
                if (($cmdIndex + 1) -lt $cmdTotal) {
                    $remainingCmds = $cmdList[($cmdIndex + 1)..($cmdTotal - 1)]
                }

                $failureResult = [ordered]@{
                    hook               = $Section
                    status             = 'failed'
                    failed_command     = $execTrimmed
                    command_index      = $cmdIndex
                    exit_code          = $cmdExit
                    stdout             = $cmdStdout
                    stderr             = $cmdStderr
                    commands_completed = @($completedCmds)
                    commands_remaining = @($remainingCmds)
                }
                # Copilot CLI blocks a PreToolUse call on a stdout permissionDecision
                # object, not on the exit code. Carry those keys inside this same
                # failure object for blocking hooks so BOTH runtimes stop; consumers
                # that don't know the keys ignore them. Advisory hooks never deny.
                if ($IsBlocking) {
                    $failureResult['permissionDecision'] = 'deny'
                    $failureResult['permissionDecisionReason'] =
                        "stride-copilot-lite $Section hook failed on command $($cmdIndex + 1)/$($cmdTotal): $execTrimmed"
                }
                # Write JSON directly to the host stdout stream to avoid
                # capturing it in the caller's `$rc = Invoke-StrideLiteSection`
                # assignment.
                [Console]::Out.WriteLine(($failureResult | ConvertTo-Json -Depth 5 -Compress))
                [Console]::Error.WriteLine("stride-copilot-lite $Section hook failed on command $($cmdIndex + 1)/$($cmdTotal): $execTrimmed")
                if ($cmdStderr) { [Console]::Error.WriteLine($cmdStderr) }

                return 2
            }
        } finally {
            Remove-Item -Force $stdoutFile, $stderrFile -ErrorAction SilentlyContinue
        }

        $cmdIndex++
    }

    $endTime = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $duration = $endTime - $startTime

    $successResult = [ordered]@{
        hook               = $Section
        status             = 'success'
        commands_completed = @($completedCmds)
        duration_seconds   = $duration
    }
    [Console]::Out.WriteLine(($successResult | ConvertTo-Json -Depth 5 -Compress))

    return 0
}

$rc = Invoke-StrideLiteSection -Section $HookName -IsBlocking $Blocking

# Record the boundary so Claude Code's Agent dispatch, which follows the marker write
# for the same boundary, stands down instead of firing the section twice.
if ($MarkerRoute) {
    Set-BoundaryFired -Boundary $HookName
}

# PostToolUse cannot roll back the tool call — never block with exit 2 there.
# PreToolUse blocking failures propagate as exit 2 so the dispatch is aborted.
if ($Blocking -and $rc -ne 0) {
    exit $rc
}

exit 0
