# Stride Lite for Copilot — Agent Guidelines

Project guidelines for AI agents working **on** the stride-copilot-lite plugin codebase (not for agents *using* the plugin's skills — that audience is served by the surface skills' SKILL.md files).

## What this plugin is

A GitHub Copilot CLI plugin that turns a free-text prompt plus an optional requirements directory into Stride-shaped markdown documents on disk, then drives those documents through a file-based task lifecycle. It is the Copilot port of the Claude Code [stride-lite](https://github.com/cheezy/stride-lite) plugin — same on-disk contract, same field discipline, same `.stride_lite.md` config shape, adapted for Copilot's skill activation and hook intercept points. Four skills ship (the three create/init flows plus the `stride-copilot-lite-workflow` orchestrator), five subagents (`create-decomposer`, `task-enricher`, `task-explorer`, `task-reviewer`, `hook-diagnostician`), five `lib/` helpers, and a `hooks/` enforcement layer (`hooks.json` + `stride-copilot-lite-hook.sh` + `stride-copilot-lite-hook.ps1`) registered with Copilot's PreToolUse/PostToolUse harness so the three `.stride_lite.md` hooks auto-fire at the right lifecycle intercept points. `before_task` and `after_task` fire on the workflow's boundary-marker write and `after_goal` on the `goal.md` Completion Summary write, so all three are live on Copilot CLI as well as Claude Code (see "Hook intercept design"). Each section's commands run with `HOOK_NAME`, `AGENT_NAME`, `TASK_FILE`, `TASK_NUMBER`, `TASK_TITLE`, `GOAL_DIR`, `GOAL_FILE`, `GOAL_SLUG` and `GOAL_TITLE` exported into their environment, derived from the goal and task markdown and always present (empty when underivable). The set deliberately omits the full plugin's board-shaped variables — there is no board here. There is no kanban server, no claim/complete loop — the `.stride_lite.md` hooks ARE executed (by the Copilot harness) but everything happens locally against the file tree.

## Repository layout

```
stride-copilot-lite/
  plugin.json                    ← Copilot plugin manifest (name, version, license, agents/skills/hooks pointers)
  hooks/
    hooks.json                   ← Copilot PreToolUse/PostToolUse handler registration (cross-platform)
    stride-copilot-lite-hook.sh  ← bash executor for macOS/Linux
    stride-copilot-lite-hook.ps1 ← PowerShell executor for Windows (behavior-equivalent to .sh)
  skills/
    stride-copilot-lite-create-goal/SKILL.md   ← goal-flow orchestrator
    stride-copilot-lite-create-task/SKILL.md   ← single-task-flow orchestrator
    stride-copilot-lite-init/SKILL.md          ← .stride_lite.md scaffold flow
    stride-copilot-lite-workflow/SKILL.md      ← eight-step task lifecycle orchestrator
  agents/
    create-decomposer.agent.md   ← subagent: prompt + requirements + mode → fenced YAML
    task-enricher.agent.md       ← subagent: fills a sparse task file's derivable sections in place
    task-explorer.agent.md       ← subagent: reads a task file, appends-or-replaces ## Exploration Report section in place
    task-reviewer.agent.md       ← subagent: reads a task file + git diff, appends-or-replaces ## Review Report section in place
    hook-diagnostician.agent.md  ← subagent: triages a hook's structured failure JSON into a fix plan
  lib/
    parse_args.md                ← extract prompt + --requirements-dir + --output-dir
    load_requirements_dir.md     ← read a directory, concatenate text files
    slugify.md                   ← normalize a title into a filesystem-safe slug
    resolve_output_path.md       ← produce a unique <base>/<slug>(.<ext>)? path
    select_workflow_branch.md    ← resolve a task file to a decision-matrix branch token
  test/                          ← smoke.sh end-to-end harness
  fixtures/                      ← sample-requirements.md + expected-output/ for smoke.sh
  docs/                          ← long-form research notes (port-specific, not user-facing)
  README.md                      ← user-facing intro and skill activation reference
  CHANGELOG.md                   ← versioned change log
  AGENTS.md                      ← this file
  LICENSE                        ← MIT
  .stride-copilot-lite/          ← transient run state (gitignored): activation marker,
                                   boundary marker, fired-record. NOT committed.
  .gitignore                     ← OS/editor cruft + .stride-copilot-lite/ marker dir
```

All `lib/*.md` files document a single pure helper with a Contract table, Spec/Rules, Reference Implementation (bash), Examples, and Edge Cases. The reference implementations are normative — when you ship a runtime that needs an executable helper, transliterate the bash from these docs without renaming functions or changing the exit-code semantics.

**Differences from stride-lite (Claude Code):**

- Manifest is at the repo root (`plugin.json`) instead of `.claude-plugin/plugin.json`.
- `agents/` files use the `.agent.md` extension and Copilot YAML frontmatter (`tools:` array, etc.).
- There is no `commands` directory: Copilot has no Claude Code-style slash-command surface; skills are activated by matching the user's natural-language prompt against the skill's description block. (See CHANGELOG "Removed".)
- `hooks/hooks.json` uses Copilot's PreToolUse/PostToolUse matcher names (the actual matcher strings may differ from Claude Code's `Agent`/`Edit`/`Write`). W928 documents the chosen intercept points.

## Module boundaries

- **`skills/<name>/SKILL.md` files orchestrate.** They wire `lib/` helpers and the `create-decomposer` subagent together. They never duplicate logic that lives in `lib/`.
- **`agents/<name>.agent.md` files produce structured output.** `create-decomposer` receives a prompt, requirements text, and a `mode` flag, and returns a single fenced ```yaml document. The other two append-or-replace named sections in a target task file. None of them call APIs, ask the user clarifying questions, or have access to a codebase beyond their input.
- **`lib/*.md` files are pure helpers.** Each documents one function. They have no side effects beyond writing to stdout/stderr.

When extending the plugin, add new helpers under `lib/`, new agents under `agents/`, and new skills under `skills/`. Do not move logic across these boundaries.

## Hard rules for agents working on this codebase

- **Never add Stride API calls.** Stride Lite's contract is "no network." If a feature seems to require an API call, it belongs in the full Stride plugin (`stride/` or `stride-copilot/`), not here.
- **Never change the default paths** without coordinating with the README, the surface skills, both create skill files, AND the `stride-copilot-lite-workflow` SKILL.md's terminal-move step in the same commit. The two defaults plus the workflow's archive sibling are the cross-skill contract:
  - `--requirements-dir` defaults to `docs/requirements`.
  - `--output-dir` defaults to `docs/implementation/PENDING` (the "in flight" location).
  - `docs/implementation/IMPLEMENTED` (the archive location populated by `stride-copilot-lite-workflow`'s terminal PENDING→IMPLEMENTED move at goal close-out, ported from stride-lite v0.10.0). Both `--output-dir` and the archive base must move together if either changes; otherwise the workflow's `/PENDING/` substring substitution breaks silently.
- **Never diverge the task markdown template** between `stride-copilot-lite-create-goal/SKILL.md` and `stride-copilot-lite-create-task/SKILL.md`. The two skills MUST render task markdown identically. The template is reproduced verbatim in both files so divergence is visible in code review.
- **Never raise the plugin version** without a matching CHANGELOG entry and a `plugin.json` bump in the same commit.
- **Never list more than 8 child tasks in a goal.** The `create-decomposer` agent enforces this cap; downstream tools (the surface skills) reject decomposer output that violates it.
- **Never add or remove a heading in the task template** without moving `agents/task-enricher.agent.md`'s owned/protected table with it in the same commit. That table's two sets must union to exactly the template's headings and stay disjoint; `test/smoke.sh` asserts it, because a heading the enricher does not know about is one it will never fill and never protect.
- **Never soften a safety row in a Rationalization table.** Each skill's table is a place a future edit can weaken a control by rewording one line, and the change reads as tidying rather than as a policy change. Two rows in `stride-copilot-lite-workflow` are **not editorial**: the one refusing to supply the exploratory step's authorized-and-non-production affirmative on the user's behalf, and the one refusing to treat an unconfirmable security verdict as mitigated. They restate controls that exist elsewhere in the file, and both are asserted by `test/smoke.sh`. Rewrite them only alongside the control itself.
- **Never change the hook script's failure JSON key set** without updating `agents/hook-diagnostician.agent.md`'s Inputs table in the same commit. That table is the agent's entire input contract, `test/smoke.sh` asserts the two agree, and a key the agent does not know about is one it will never read off a payload.
- **Never change the exported hook variable set** without updating all four places that state it in the same commit: both executors, the workflow SKILL.md's "Exported variables" table, the init skill's scaffolded template note, and README.md. The harnesses assert the executors agree with each other, but nothing catches a table that has drifted from the code.
- **Never drift from stride-lite's behavior on the on-disk markdown.** Feature parity means output parity: the smoke test fixtures (`fixtures/sample-requirements.md` + `fixtures/expected-output/`) port from stride-lite verbatim and any divergence requires a documented intentional change in CHANGELOG.

## Hook intercept design

**Decision (v0.10.0, W2021): the task boundary is signalled by a marker-file write, not by an agent dispatch.**

The problem. `## before_task` and `## after_task` originally keyed on Claude Code's `Agent` tool call with a `subagent_type` of `stride-copilot-lite:task-explorer` / `:task-reviewer`. GitHub Copilot CLI emits **no skill- or agent-dispatch event at all** — its `preToolUse` payloads fire on the underlying tools (`bash`, `edit`, `view`, `create`), and there is no `Agent` tool name in its vocabulary (`stride-copilot/docs/HOOK_RESEARCH.md`). Two of the three hooks therefore never fired on the runtime this plugin is named for.

**Chosen: a marker-file write.** The workflow skill writes `.stride-copilot-lite/lite-boundary` at each boundary with a single-line body — `stride-lite-boundary:before_task` or `stride-lite-boundary:after_task`. `hooks.json` registers PreToolUse on `Edit|edit` and `Write|create`; the executor routes only when the path is exactly that marker **and** the body carries exactly that token.

**False-positive failure mode, and how the routing bounds it.** The matcher is necessarily broad — it sees every file edit in the session — so precision lives in the routing, exactly as `after_goal`'s `*/goal.md` + `## Completion Summary` check already does. Both conditions are required, which bounds the two realistic misfires: a write to the marker path carrying other content (no token → no fire), and the token appearing in ordinary file content or in a shell command (wrong path → no fire). The harnesses assert four distinct near-misses covering both directions plus the wrong-phase and wrong-tool cases. The residual risk is a write to the exact plugin-owned path with the exact token, which nothing but the workflow skill has reason to produce.

**Rejected: a Bash sentinel command.** The closest sibling, `stride-copilot/hooks/stride-hook.sh`, routes on a Bash matcher plus a Stride API URL — but its boundaries *are* real API calls, so the signal is something the workflow genuinely does. This plugin makes no network calls, so its sentinel would be a command run purely to trip a hook. Two problems. First, the hook sees only the command text, so any bash call containing the string fires the user's hooks — and a prompt-injected requirements file that induces the agent to echo the sentinel is enough. A path is far harder to hit by accident than a substring. Second, this skill's security posture is built on *not* running arbitrary Bash (see `## Bash scope` in the workflow SKILL.md); granting a Bash carve-out to enable hooks would trade away more than it buys. A file write is the smaller grant.

**Rejected: keying on the workflow's own file mutations.** `after_goal` already works this way, keying on the `goal.md` Completion Summary write. It cannot serve `before_task`: that boundary is defined as the moment *before* any work happens, and at that point the workflow has mutated nothing. There is no mutation to key on without inventing one — which is what the marker is, made explicit.

**Double-firing.** Under Claude Code both events occur for one boundary. The marker route fires first and records the boundary in `.stride-copilot-lite/lite-boundary-fired`; the `Agent` route consumes that record and stands down. The record is *consumed* rather than merely read, so the reviewer loop's legitimate second `after_task` still fires. A pre-v0.10.0 skill writes no marker, leaves no record, and still fires through the `Agent` route unchanged.

**Blocking is runtime-specific and both forms are emitted.** Claude Code blocks a PreToolUse call on `exit 2`; Copilot CLI ignores exit codes and blocks on a stdout `{"permissionDecision":"deny"}` object. A failing blocking hook emits both, with the `permissionDecision` keys carried inside the same single-line failure JSON the executor already emits. Emitting only one would leave a failing `before_task` stopping the workflow on one runtime while the other silently continued. `after_goal` is advisory and must never emit a deny — doing so would newly block a write that has always been allowed to proceed.

**Scoping hook firing to a workflow run (v0.10.0, W2023).** The marker intercept is necessarily broader than the agent dispatch it replaced — it sees every file edit in the session — so hook firing is additionally gated on `.stride-copilot-lite/.orchestrator_active`. The workflow skill writes it at Step 0 and clears it on all five exit paths; the executor runs a section only when that marker exists and its `started_at` is within 4 hours. Missing or stale means run nothing and exit 0 — never block the tool call, or ordinary editing outside a workflow would start failing. `STRIDE_COPILOT_LITE_ALLOW_DIRECT=1` bypasses the gate for debugging and CI, and must never be set from a shipped file.

**The marker is coordination, NOT a security boundary.** Any local process can write it, so it establishes only that a workflow run believes itself active — never that a caller is authorized. Do not build authorization on it, and do not describe it as protecting anything. What it actually buys is scope: it keeps a widened matcher from running a user's arbitrary shell commands outside a workflow. A crashed run leaves a marker behind, which is exactly what the freshness window bounds; the clear-on-every-exit rule is what keeps the exposure short in practice rather than four hours long.

**Its own directory, deliberately.** The marker lives in `.stride-copilot-lite/`, never `.stride/` or `.stride-lite/` — a project may have the full Stride plugin, stride-lite and this plugin installed at once, and sharing a directory would let one plugin's lifecycle arm or disarm another's hooks. For the same reason it sits outside the goal directory, so Step 8's terminal PENDING→IMPLEMENTED move cannot carry it along.

**When to revisit.** If Copilot CLI adds a skill-activation event or a documented `Skill`/`Agent` tool name, the marker becomes redundant for that runtime and this decision should be re-opened.

## Dispatching another plugin's agent

Steps 6a, 6b and 6c of the workflow dispatch surfaces belonging to **other plugins** — `stride-copilot-exploratory-testing` for the first two, `stride-copilot-security-review` for the third. Two things follow that are easy to get wrong.

**This is not a network call and does not violate the no-network contract.** A subagent dispatch is a local harness operation, the same mechanism this plugin already uses for its own five agents. The "no API calls, no network" rule is about this plugin never talking to a server; it has never been about refusing to compose with the harness. If that rule is ever restated, restate it in those terms so a later reader does not delete these steps to satisfy it.

**Their availability is a session fact this plugin does not control.** Our own five agents ship in this repository, so their availability follows the plugin's. The explorer and the security-reviewer ship elsewhere on their own release cadences, so every gate must check for them rather than assume them, and every gate must fall through to a clean skip when it is absent. A step that fails because an optional sibling is not installed would make the whole integration a liability.

**Anything read about that plugin's surfaces was read at a point in time.** Which of its commands require a human, and what unit its explorer takes a budget in, are facts about a repository that versions separately from this one. Re-establish them from its own agent and skill files when its version changes, rather than trusting what this workflow says about it.

## Conventions

- **All filenames are kebab-case** (`stride-copilot-lite-hook.sh`, `task-explorer.agent.md`). The exception is `lib/*.md` files, where snake_case mirrors the bash function name they document.
- **Markdown templates use angle-bracket placeholders** (`<task.title>`, `<key_files[0].file_path>`) — these are documentation, not runnable code. Implementing runtimes substitute the values at render time.
- **Empty values render as `(none)`** rather than disappearing from the output. Reviewability is the goal of the markdown layer.
- **Code fences are language-tagged** (`` ```bash ``, `` ```yaml ``, `` ```markdown ``). Untagged fences are reserved for raw output blocks where no language fits.

## What NOT to add

- **No Elixir/Phoenix-specific guidance.** Stride Lite is project-agnostic. The full Stride plugin has Phoenix conventions baked in; this plugin does not.
- **No multi-harness fallbacks beyond Copilot.** This is the Copilot variant. If a Cursor/Continue/Windsurf path is needed, it belongs in its own sibling plugin (`stride-lite-cursor`, etc.), not bolted onto this one.
- **No server-mediated lifecycle.** stride-copilot-lite has no kanban server, no claim/complete API. The `hooks/` directory holds a Copilot-level enforcement layer (`hooks.json` + `stride-copilot-lite-hook.sh` + `stride-copilot-lite-hook.ps1`) that auto-fires the three `.stride_lite.md` hooks (`before_task` on subagent dispatch, `after_task` on reviewer dispatch, `after_goal` on the goal.md write that appends `## Completion Summary`). The workflow skill body does not execute hooks directly — the harness does, so the enforcement survives skill amendments.
- **No API client.** A `curl` invocation, a Stride client wrapper, or an HTTP library import is a contract violation. The whole point of this plugin is "no network."
