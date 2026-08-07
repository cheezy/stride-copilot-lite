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
#   pre  + (Edit|edit|Write|create) + file_path ~ */.stride-copilot-lite/lite-boundary + body contains
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
# .stride-copilot-lite/lite-boundary-fired and the Agent route consumes that record instead of re-firing.
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

# Boundary-marker route (W2021). Transient session state under .stride-copilot-lite/,
# a plugin-owned directory — never .stride/ or .stride-lite/, which belong to the sibling
# plugins a project may have installed alongside this one.
$BoundaryFiredFile = Join-Path (Join-Path $ProjectDir '.stride-copilot-lite') 'lite-boundary-fired'

# --- Orchestrator activation gate (W2023) ---
# Hook firing is a property of a WORKFLOW RUN, not of whichever tool call matched.
# The workflow skill writes this marker before its first task boundary and clears it
# on every exit path; without a fresh one, a matching payload runs nothing, exits 0
# and never blocks the tool call.
#
# NOT A SECURITY BOUNDARY. Any local process can write this file. It coordinates the
# workflow skill with the hook executor; nothing may lean on it for authorization.
$OrchestratorMarker = Join-Path (Join-Path $ProjectDir '.stride-copilot-lite') '.orchestrator_active'
$OrchestratorMaxAgeSeconds = 14400   # 4 hours, mirroring the full Stride plugin

function Test-OrchestratorActive {
    # Debugging and CI escape hatch. Never set from any shipped file.
    if ($env:STRIDE_COPILOT_LITE_ALLOW_DIRECT -eq '1') { return $true }
    if (-not (Test-Path -LiteralPath $OrchestratorMarker -PathType Leaf)) { return $false }
    try {
        $content = Get-Content -LiteralPath $OrchestratorMarker -Raw -Encoding UTF8
        $then = $null
        # Freshness from started_at when it parses, else the file's mtime. A crashed
        # run leaves a marker behind, so an existing marker is never trusted alone.
        if ($content -match '"started_at"\s*:\s*"([^"]+)"') {
            $parsed = [datetime]::MinValue
            if ([datetime]::TryParse($Matches[1], [cultureinfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor
                    [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
                $then = $parsed
            }
        }
        if (-not $then) {
            # [System.IO.File], not Get-Item: the provider cmdlets are unreliable
            # for dot-prefixed names here, and a throw would be swallowed by the
            # catch below and read as "no active run" — silently disabling every
            # hook whenever started_at could not be parsed.
            $then = [System.IO.File]::GetLastWriteTimeUtc($OrchestratorMarker)
        }
        $now = [datetime]::UtcNow
        # A marker dated in the future is as untrustworthy as a stale one.
        if ($then -gt $now) { return $false }
        return (($now - $then).TotalSeconds -le $OrchestratorMaxAgeSeconds)
    } catch {
        return $false
    }
}

# --- Hook context derivation (W2022) ---
# Same key set, same empty-string rule and same no-interpolation guarantee as the
# .sh, per the parity contract. Deliberately omits stride's BOARD_ID/COLUMN_NAME/
# TASK_STATUS: this plugin has no board, column or status.
$HookTaskFile = ''
$HookTaskNumber = ''
$HookTaskTitle = ''
$HookGoalDir = ''
$HookGoalFile = ''
$HookGoalSlug = ''
$HookGoalTitle = ''

# A path from a hook payload is untrusted. Resolve it and confirm it sits under
# the project directory before reading it. Returns '' on rejection.
# Canonicalize a directory the way bash's `pwd -P` does — following symlinks on
# every component. Neither GetFullPath nor Resolve-Path does this, and it matters
# twice over: a symlink inside the project pointing outward would otherwise pass
# the containment test below, and the .sh/.ps1 parity assertion compares the
# exported paths byte-for-byte.
function Get-PhysicalDirectory {
    param([string]$Dir)
    $info = [System.IO.DirectoryInfo]::new([System.IO.Path]::GetFullPath($Dir))
    $target = $info.ResolveLinkTarget($true)
    if ($target) { return $target.FullName }
    # Not itself a link — an ancestor still might be, so walk up and rebuild.
    $parent = $info.Parent
    if (-not $parent) { return $info.FullName }
    return (Join-Path (Get-PhysicalDirectory $parent.FullName) $info.Name)
}

function Resolve-WithinProject {
    param([string]$P)
    if (-not $P) { return '' }
    try {
        $proj = Get-PhysicalDirectory $ProjectDir
        $abs = if ([System.IO.Path]::IsPathRooted($P)) { $P } else { Join-Path $proj $P }
        $abs = [System.IO.Path]::GetFullPath($abs)
        # Resolve the parent, not the leaf, so a not-yet-existing file still
        # validates — matching the .sh, which resolves dirname and re-appends.
        $dir = [System.IO.Path]::GetDirectoryName($abs)
        $base = [System.IO.Path]::GetFileName($abs)
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return '' }
        $full = Join-Path (Get-PhysicalDirectory $dir) $base
        $sep = [System.IO.Path]::DirectorySeparatorChar
        $projPrefix = if ($proj.EndsWith($sep)) { $proj } else { $proj + $sep }
        if ($full.StartsWith($projPrefix)) { return $full }
    } catch {
        return ''
    }
    return ''
}

# First '# ' heading of a markdown file; '' when missing, unreadable or absent.
function Get-MarkdownTitle {
    param([string]$File)
    if (-not $File -or -not (Test-Path -LiteralPath $File -PathType Leaf)) { return '' }
    try {
        foreach ($line in (Get-Content -LiteralPath $File -Encoding UTF8 -ErrorAction Stop)) {
            if ($line -match '^# (.+)$') { return $Matches[1].TrimEnd() }
        }
    } catch {
        return ''
    }
    return ''
}

function Set-HookContext {
    param([string]$TaskPath = '', [string]$GoalPath = '')
    if ($TaskPath) {
        $resolved = Resolve-WithinProject $TaskPath
        if ($resolved) {
            $script:HookTaskFile = $resolved
            $base = Split-Path -Leaf $resolved
            if ($base -match '^task([0-9]+)\.md$') { $script:HookTaskNumber = $Matches[1] }
            $script:HookTaskTitle = Get-MarkdownTitle $resolved
            $script:HookGoalDir = Split-Path -Parent $resolved
        }
    }
    if ($GoalPath) {
        $resolved = Resolve-WithinProject $GoalPath
        if ($resolved) {
            $script:HookGoalFile = $resolved
            $script:HookGoalDir = Split-Path -Parent $resolved
        }
    }
    if ($script:HookGoalDir) {
        $script:HookGoalSlug = Split-Path -Leaf $script:HookGoalDir
        if (-not $script:HookGoalFile) { $script:HookGoalFile = Join-Path $script:HookGoalDir 'goal.md' }
        $script:HookGoalTitle = Get-MarkdownTitle $script:HookGoalFile
    }
}

# Optional task path trailing the boundary token in the marker body.
function Get-MarkerTaskPath {
    param([string]$Body, [string]$Boundary)
    $prefix = "stride-lite-boundary:${Boundary}:"
    if ($Body -and $Body.StartsWith($prefix)) {
        return ($Body.Substring($prefix.Length) -split "`n")[0].Trim()
    }
    return ''
}

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
$ContentBody = ''
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
        # Write uses `content`; Edit uses `new_string`. Either can carry the marker body.
        if ($ti.PSObject.Properties.Name -contains 'content') {
            $ContentBody = [string]$ti.content
        }
        if (-not $ContentBody -and $ti.PSObject.Properties.Name -contains 'new_string') {
            $ContentBody = [string]$ti.new_string
        }
    }
    if ((-not $FilePath -or -not $ContentBody) -and $parsed.PSObject.Properties.Name -contains 'toolArgs' -and $parsed.toolArgs) {
        # Copilot CLI: toolArgs is a JSON-encoded string. Decode once more.
        try {
            $tArgs = $parsed.toolArgs | ConvertFrom-Json
            if (-not $FilePath -and $tArgs.PSObject.Properties.Name -contains 'file_path') {
                $FilePath = [string]$tArgs.file_path
            }
            if (-not $ContentBody -and $tArgs.PSObject.Properties.Name -contains 'content') {
                $ContentBody = [string]$tArgs.content
            }
            if (-not $ContentBody -and $tArgs.PSObject.Properties.Name -contains 'new_string') {
                $ContentBody = [string]$tArgs.new_string
            }
        } catch {
            # toolArgs not parseable as JSON — leave the extracted values empty.
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
            if ($FilePath -match '(^|[/\\])\.stride-copilot-lite[/\\]lite-boundary$') {
                if ($InputJson -match 'stride-lite-boundary:before_task') {
                    $HookName = 'before_task'; $Blocking = $true; $MarkerRoute = $true
                }
                elseif ($InputJson -match 'stride-lite-boundary:after_task') {
                    $HookName = 'after_task';  $Blocking = $true; $MarkerRoute = $true
                }
                if ($HookName) {
                    # Optional task path trailing the boundary token; absent is valid.
                    Set-HookContext -TaskPath (Get-MarkerTaskPath $ContentBody $HookName)
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
                    Set-HookContext -GoalPath $FilePath
                }
            }
        }
    }
}

if (-not $HookName) { exit 0 }

# The gate sits AFTER trigger detection so a non-trigger payload costs nothing.
# Standing down runs no section and exits 0 — it must never block the tool call.
if (-not (Test-OrchestratorActive)) { exit 0 }

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

    # Export the derived context for every command below. These are environment
    # values, never spliced into command text, so a title containing $(...) or
    # backticks is inert. Every key is exported even when empty. Nothing is
    # persisted to disk and none of it enters the result JSON.
    $env:HOOK_NAME   = $Section
    $env:AGENT_NAME  = 'stride-copilot-lite'
    $env:TASK_FILE   = $script:HookTaskFile
    $env:TASK_NUMBER = $script:HookTaskNumber
    $env:TASK_TITLE  = $script:HookTaskTitle
    $env:GOAL_DIR    = $script:HookGoalDir
    $env:GOAL_FILE   = $script:HookGoalFile
    $env:GOAL_SLUG   = $script:HookGoalSlug
    $env:GOAL_TITLE  = $script:HookGoalTitle

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
            #
            # ProcessStartInfo.ArgumentList, NOT Start-Process -ArgumentList: the
            # latter re-splits on spaces, so `bash -c "echo hi"` reached bash as
            # `-c echo hi` and ran `echo` with no arguments — every multi-word hook
            # command silently did nothing while the executor reported success.
            # ArgumentList passes each element verbatim with no shell re-parsing.
            # UseShellExecute=$false also makes the child inherit this process's
            # environment, which is how the exported TASK_*/GOAL_* values arrive.
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = 'bash'
            $psi.ArgumentList.Add('-c')
            $psi.ArgumentList.Add($execTrimmed)
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false
            $psi.WorkingDirectory = (Get-Location).Path

            $proc = [System.Diagnostics.Process]::Start($psi)
            # Read both pipes concurrently — a sequential ReadToEnd deadlocks when
            # the other stream's buffer fills.
            $outTask = $proc.StandardOutput.ReadToEndAsync()
            $errTask = $proc.StandardError.ReadToEndAsync()
            $proc.WaitForExit()
            [System.IO.File]::WriteAllText($stdoutFile, $outTask.GetAwaiter().GetResult())
            [System.IO.File]::WriteAllText($stderrFile, $errTask.GetAwaiter().GetResult())

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
