# Changelog

All notable changes to this project will be documented in this file.

## [0.2.0] - 2026-07-05

### Changed

- **init skill hook-execution framing** — `stride-lite-init/SKILL.md` now correctly attributes hook execution to the Copilot harness (auto-fired via `hooks/hooks.json` at the corresponding lifecycle points), removing the stale "static configuration / the workflow skill executes them" claims and the phantom `install.sh` references; the init skill remains a pure scaffolder.
- **workflow walkthrough alignment** — `stride-lite-workflow/SKILL.md`'s Concrete walkthrough now describes `before_task`/`after_task`/`after_goal` as harness-auto-fired (consistent with the skill body), documents the terminal `PENDING`→`IMPLEMENTED` archive move on goal close-out, and corrects the hook-script filename references to `stride-lite-copilot-hook.sh` / `.ps1`.
- **create-decomposer capability surface** — the `create-decomposer` agent's `tools` grant is now `[]`, matching its inline-only, no-codebase-access contract (it previously granted unused `read`/`search`).
- **AGENTS.md accuracy** — corrected doc-drift so it describes the shipped state: four skills ship (not "planned"), the hook scripts are `stride-lite-copilot-hook.sh` / `.ps1`, and there is no `commands` directory (Copilot uses skill activation).

### Fixed

- **init-template parity enforcement** — `test/smoke.sh` now extracts the canonical `.stride_lite.md` template from `stride-lite-init/SKILL.md` at runtime and asserts byte-parity, replacing a hardcoded copy that had drifted (it referenced a phantom `/stride-lite:init` slash command and a stale `v0.2.0` Note).
- **hook exit-code-contract coverage** — the bash and PowerShell hook test harnesses gained failing-command cases that assert the exit-code contract: `before_task`/`after_task` block with exit 2, `after_goal` stays advisory at exit 0, all emitting the structured failure JSON.

## [0.1.0] - 2026-05-27

### Added

- Initial scaffold for the GitHub Copilot port of [stride-lite](https://github.com/cheezy/stride-lite): `plugin.json`, `README.md`, `CHANGELOG.md`, `AGENTS.md`, `LICENSE`, `.gitignore`, and the empty subdirectory tree (`lib/`, `agents/`, `skills/`, `hooks/`, `test/`, `fixtures/`, `docs/`).
- `plugin.json` follows the `stride-copilot` manifest shape (root-level, not `.claude-plugin/plugin.json`), with `name=stride-lite-copilot`, `version=0.1.0`, `license=MIT`, and the `agents` / `skills` / `hooks` pointer fields populated for Copilot's plugin loader.
- Four skills (`stride-lite-create-goal`, `stride-lite-create-task`, `stride-lite-init`, `stride-lite-workflow`), three subagents (`create-decomposer.agent.md`, `task-explorer.agent.md`, `task-reviewer.agent.md`), four `lib/` markdown helpers, and a `hooks/` enforcement layer (`hooks.json` + `stride-lite-copilot-hook.sh` + `stride-lite-copilot-hook.ps1`) ported from stride-lite under W924–W928.
- Smoke test (`test/smoke.sh`, 26 assertions, byte-identical with stride-lite source) and a compact 13-case bash hook test harness (`hooks/test-stride-lite-copilot-hook.sh`) covering missing-file no-op, both Claude Code snake_case and Copilot CLI camelCase field-name handling, all three hook trigger conditions, env-var defaulted-fallback when `CLAUDE_PROJECT_DIR` is unset, non-matching tool / non-stride-lite-copilot subagent no-ops, and the failing-command exit-code contract (before_task/after_task block with exit 2, after_goal stays advisory at exit 0, all emitting failure JSON). PS1 mirror (`hooks/test-stride-lite-copilot-hook.ps1`) ships for Windows CI.
- README, AGENTS.md, and CHANGELOG finalized for the Copilot CLI install + migration story. README documents the `copilot plugin install` flow, the four-skill activation reference, the `.stride_lite.md` configuration shape with a hook-firing table, and a stride-lite → stride-lite-copilot migration guide. AGENTS.md preserves the stride-lite hard-rules block with the Copilot-variant repository layout.

### Removed

- No `commands/` directory. GitHub Copilot CLI has no Claude Code-style slash command surface; skill activation is done by natural-language prompt matching against the four `SKILL.md` description blocks. README documents the activation phrases for each skill.

### Backward compatibility

Initial release — no prior version of stride-lite-copilot exists. Behavior parity with `stride-lite` is the goal of subsequent releases; this 0.1.0 entry only establishes the metadata foundation.

### Source

W923–W931 under goal G200. Task W932 (GitHub repo creation + marketplace decision) closes out the goal.
