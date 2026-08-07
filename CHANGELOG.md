# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Fixed

- **`before_task` and `after_task` now fire under GitHub Copilot CLI.** They previously keyed on Claude Code's `Agent` subagent-dispatch tool call, and Copilot CLI emits no skill- or agent-dispatch event at all, so two of the three hooks never fired on the runtime this plugin is named for. The workflow skill now writes a one-line boundary marker to `.stride/lite-boundary` at Steps 2 and 5, and `hooks.json` registers PreToolUse on `Edit|edit` / `Write|create` so that write is the intercept. Routing requires **both** the exact marker path and the exact boundary token, so writing the token into any other file — or naming it in a shell command — fires nothing. The `Agent` route is retained unchanged for Claude Code; when both events occur the marker route fires first and records the boundary, and the `Agent` route consumes that record and stands down, so each boundary fires exactly once. The chosen intercept and the two rejected alternatives (a Bash sentinel command; keying on the workflow's own file mutations) are recorded in `AGENTS.md` → "Hook intercept design". **Breaking for anyone driving a goal directory with their own orchestrator** rather than the shipped workflow skill: the marker write is now required to fire `before_task` / `after_task` under Copilot.
- **`after_goal` never fired under Copilot CLI either.** The bash executor's field extractor looked for a real `"` and Copilot delivers tool arguments as a JSON-*encoded* string (`\"file_path\":\"…\"`), so every Copilot-shaped payload silently routed to nothing — including `after_goal`, which the README, AGENTS.md and the v0.1.0 CHANGELOG entry all described as working on both runtimes. The extractor now falls back to an unescaped view of the payload. The PowerShell executor already decoded `toolArgs` correctly and was unaffected. All three hooks are now live on both runtimes.
- **The PowerShell executor could not read its stdin at all.** `stride-copilot-lite-hook.ps1` is invoked as `pwsh -File … <phase>` with the payload piped in, and a `-File` script whose `param()` block declares no pipeline-bound parameter cannot bind piped input — PowerShell raised "The input object cannot be bound to any parameters" and the automatic `$input` stayed empty, so every trigger no-opped under every runtime. It now reads `[Console]::In.ReadToEnd()`, which sidesteps parameter binding. This is what the PowerShell harness had been reporting: it went from 3 passed / 7 failed to fully green.
- **The PowerShell executor never actually ran multi-word hook commands.** It invoked `Start-Process -FilePath bash -ArgumentList '-c', $command`, and `-ArgumentList` re-splits on spaces — so `bash -c "echo hi"` reached bash as `-c echo hi` and ran `echo` with no arguments. Any hook command containing a space did nothing while the executor reported `"status":"success"`, which is worse than failing. Replaced with `ProcessStartInfo.ArgumentList`, which passes each argument verbatim with no shell re-parsing (and, with `UseShellExecute=$false`, is also what lets the child inherit the exported variables above). Only single-word commands such as `false` had been behaving correctly, which is why the exit-code harness cases passed while real hooks silently no-opped.
- **A failing blocking hook did not stop the workflow under Copilot CLI.** Claude Code blocks a PreToolUse call on `exit 2`, but Copilot CLI ignores exit codes and blocks on a stdout `{"permissionDecision":"deny"}` object, so a failed `before_task` fired and then let the workflow continue. Blocking failures now emit both — the `permissionDecision` / `permissionDecisionReason` keys ride inside the same single-line failure JSON, which consumers that don't know them simply ignore. `after_goal` stays advisory and never emits a deny.

### Added

- **Hook commands now receive task and goal context as environment variables.** Each `.stride_lite.md` command runs with `HOOK_NAME`, `AGENT_NAME`, `TASK_FILE`, `TASK_NUMBER`, `TASK_TITLE`, `GOAL_DIR`, `GOAL_FILE`, `GOAL_SLUG` and `GOAL_TITLE` exported, all derived from the goal and task markdown and their paths — there is no server involved. Previously nothing was forwarded, so a variable-using hook carried over from the Claude Code plugin (which the README markets as a migration feature) silently interpolated empty strings. A key that cannot be derived exports as the empty string rather than erroring, so referencing one is always safe including under `set -u`, and no derivation failure changes a hook's exit code. Values are exported as environment values and never spliced into command text, so a task title containing `$(...)` or backticks is inert. Paths taken from the hook payload are resolved and confirmed to sit under the project directory before being read. The set deliberately omits the full plugin's `BOARD_ID` / `COLUMN_NAME` / `TASK_STATUS` — this plugin has no board, column or status, and exporting them empty would teach a contract that does not exist. To carry the active task, the boundary marker gains an optional trailing path (`stride-lite-boundary:before_task:<taskN.md>`); a marker without one still fires the hook and simply yields empty task variables.

- Hook-harness coverage for the new trigger in both executors: the marker route on both payload shapes, four distinct near-misses (marker path without a token, token written to another file, marker payload in the wrong phase, token inside a bash command), the fire-exactly-once handshake and its consume-on-fire release, the blocking deny-plus-exit-2 contract, the advisory no-deny contract, and a regression guard for `after_goal` on a Copilot-shaped payload. The bash harness goes from 13 to 25 assertions and the PowerShell harness from 10 to 22.

### Changed

- **Renamed the four skill directories and identities `stride-lite-*` → `stride-copilot-lite-*`**, finishing the plugin rename that v0.3.0 started. The skills formerly named `stride-lite-create-goal`, `stride-lite-create-task`, `stride-lite-init` and `stride-lite-workflow` now live at `skills/stride-copilot-lite-create-goal`, `skills/stride-copilot-lite-create-task`, `skills/stride-copilot-lite-init` and `skills/stride-copilot-lite-workflow` (moved with `git mv`, so rename history is preserved); each `SKILL.md`'s frontmatter `name` matches its directory, and every cross-reference in `README.md`, `AGENTS.md`, the three `agents/*.agent.md` files, `lib/parse_args.md`, `lib/slugify.md` and `test/smoke.sh` was updated to match. This also removes the `stride-copilot-lite:stride-lite-workflow` split-identity construction from the README. **Breaking for name-based references:** anything that names a skill directly — a `.stride_lite.md` hook body, your own scripts, CI, or documentation — must use the new `stride-copilot-lite-*` names. Skill *activation* is unaffected: Copilot matches natural-language prompts against each `SKILL.md` description block, not against the skill or directory name, and the description prose is unchanged apart from the renamed identifiers themselves.
- Earlier entries in this file were updated to the new skill names so no reference to this plugin's own surface uses the old prefix. Entries prior to this one describe releases in which those directories were still named `stride-lite-*`.

### Unchanged (deliberately)

- The `.stride_lite.md` config filename and its four section names (`## email`, `## before_task`, `## after_task`, `## after_goal`) are untouched — the README's byte-identical-config promise to stride-lite users depends on them.
- References to the upstream Claude Code [stride-lite](https://github.com/cheezy/stride-lite) plugin — including its `/stride-lite:create-goal` / `/stride-lite:create-task` / `/stride-lite:init` slash commands and its `stride-lite:task-explorer` / `stride-lite:task-reviewer` subagent identities in the Migration section — are correct as written and were left alone.

## [0.3.0] - 2026-07-20

### Changed

- **Renamed the plugin `stride-lite-copilot` → `stride-copilot-lite`** for naming consistency with the other `stride-copilot-*` Copilot ports. The GitHub repository was renamed (GitHub keeps an old→new redirect); `plugin.json` (`name`, `homepage`, `repository`), the four `hooks/` scripts (`stride-copilot-lite-hook.sh` / `.ps1` and their test harnesses), `hooks/hooks.json`, `AGENTS.md`, `README.md`, and the skill/agent docs were updated to the new name. **Breaking for existing installs:** reinstall under the new name; the old `stride-lite-copilot` install identity no longer matches.

## [0.2.0] - 2026-07-05

### Changed

- **init skill hook-execution framing** — `stride-copilot-lite-init/SKILL.md` now correctly attributes hook execution to the Copilot harness (auto-fired via `hooks/hooks.json` at the corresponding lifecycle points), removing the stale "static configuration / the workflow skill executes them" claims and the phantom `install.sh` references; the init skill remains a pure scaffolder.
- **workflow walkthrough alignment** — `stride-copilot-lite-workflow/SKILL.md`'s Concrete walkthrough now describes `before_task`/`after_task`/`after_goal` as harness-auto-fired (consistent with the skill body), documents the terminal `PENDING`→`IMPLEMENTED` archive move on goal close-out, and corrects the hook-script filename references to `stride-copilot-lite-hook.sh` / `.ps1`.
- **create-decomposer capability surface** — the `create-decomposer` agent's `tools` grant is now `[]`, matching its inline-only, no-codebase-access contract (it previously granted unused `read`/`search`).
- **AGENTS.md accuracy** — corrected doc-drift so it describes the shipped state: four skills ship (not "planned"), the hook scripts are `stride-copilot-lite-hook.sh` / `.ps1`, and there is no `commands` directory (Copilot uses skill activation).

### Fixed

- **init-template parity enforcement** — `test/smoke.sh` now extracts the canonical `.stride_lite.md` template from `stride-copilot-lite-init/SKILL.md` at runtime and asserts byte-parity, replacing a hardcoded copy that had drifted (it referenced a phantom `/stride-lite:init` slash command and a stale `v0.2.0` Note).
- **hook exit-code-contract coverage** — the bash and PowerShell hook test harnesses gained failing-command cases that assert the exit-code contract: `before_task`/`after_task` block with exit 2, `after_goal` stays advisory at exit 0, all emitting the structured failure JSON.

## [0.1.0] - 2026-05-27

### Added

- Initial scaffold for the GitHub Copilot port of [stride-lite](https://github.com/cheezy/stride-lite): `plugin.json`, `README.md`, `CHANGELOG.md`, `AGENTS.md`, `LICENSE`, `.gitignore`, and the empty subdirectory tree (`lib/`, `agents/`, `skills/`, `hooks/`, `test/`, `fixtures/`, `docs/`).
- `plugin.json` follows the `stride-copilot` manifest shape (root-level, not `.claude-plugin/plugin.json`), with `name=stride-copilot-lite`, `version=0.1.0`, `license=MIT`, and the `agents` / `skills` / `hooks` pointer fields populated for Copilot's plugin loader.
- Four skills (`stride-copilot-lite-create-goal`, `stride-copilot-lite-create-task`, `stride-copilot-lite-init`, `stride-copilot-lite-workflow`), three subagents (`create-decomposer.agent.md`, `task-explorer.agent.md`, `task-reviewer.agent.md`), four `lib/` markdown helpers, and a `hooks/` enforcement layer (`hooks.json` + `stride-copilot-lite-hook.sh` + `stride-copilot-lite-hook.ps1`) ported from stride-lite under W924–W928.
- Smoke test (`test/smoke.sh`, 26 assertions, byte-identical with stride-lite source) and a compact 13-case bash hook test harness (`hooks/test-stride-copilot-lite-hook.sh`) covering missing-file no-op, both Claude Code snake_case and Copilot CLI camelCase field-name handling, all three hook trigger conditions, env-var defaulted-fallback when `CLAUDE_PROJECT_DIR` is unset, non-matching tool / non-stride-copilot-lite subagent no-ops, and the failing-command exit-code contract (before_task/after_task block with exit 2, after_goal stays advisory at exit 0, all emitting failure JSON). PS1 mirror (`hooks/test-stride-copilot-lite-hook.ps1`) ships for Windows CI.
- README, AGENTS.md, and CHANGELOG finalized for the Copilot CLI install + migration story. README documents the `copilot plugin install` flow, the four-skill activation reference, the `.stride_lite.md` configuration shape with a hook-firing table, and a stride-lite → stride-copilot-lite migration guide. AGENTS.md preserves the stride-lite hard-rules block with the Copilot-variant repository layout.

### Removed

- No `commands/` directory. GitHub Copilot CLI has no Claude Code-style slash command surface; skill activation is done by natural-language prompt matching against the four `SKILL.md` description blocks. README documents the activation phrases for each skill.

### Backward compatibility

Initial release — no prior version of stride-copilot-lite exists. Behavior parity with `stride-lite` is the goal of subsequent releases; this 0.1.0 entry only establishes the metadata foundation.

### Source

W923–W931 under goal G200. Task W932 (GitHub repo creation + marketplace decision) closes out the goal.
