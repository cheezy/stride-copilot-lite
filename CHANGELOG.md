# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

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
