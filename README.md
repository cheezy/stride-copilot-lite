# Stride Lite for GitHub Copilot

A lightweight companion plugin to [Stride](https://www.stridelikeaboss.com) — produces Stride-shaped **goal and task markdown documents on disk** from a free-text prompt plus an optional requirements directory. No API calls, no kanban setup, no auth files. Just markdown.

stride-copilot-lite is the GitHub Copilot CLI port of the Claude Code [stride-lite](https://github.com/cheezy/stride-lite) plugin. It provides the same field discipline (acceptance criteria, key files, pitfalls, testing strategy, dependencies) through Copilot's skill activation, with feature parity with stride-lite as the goal.

## Installation

Install via the Copilot CLI plugin command:

```bash
copilot plugin install https://github.com/cheezy/stride-copilot-lite
```

### Plugin management

```bash
copilot plugin list                              # confirm stride-copilot-lite is loaded
copilot plugin update stride-copilot-lite        # pull a newer release
copilot plugin uninstall stride-copilot-lite     # remove
```

After install, the four skills (described below) are discoverable by description match. There are no slash commands — type natural-language prompts and the Copilot agent routes them.

## Skills

stride-copilot-lite exposes four skills — invoke them by matching natural-language prompts against the skill description blocks. Copilot has no Claude Code-style slash commands; the agent reads your prompt, matches against the four `SKILL.md` description blocks, and activates the best fit. The descriptions are tuned so the matcher reliably routes user intent to the right skill.

### `stride-copilot-lite-create-goal` — decompose a prompt into a multi-task goal directory

Activate when you want to break a free-text initiative into 1–8 ordered, Stride-shaped tasks on disk. Produces `<output-dir>/<slug>/goal.md` + one `taskN.md` per child task.

Activation phrases:

- "Create a Stride-shaped goal for adding real-time notifications."
- "Decompose 'Add board comments' into a goal under docs/implementation/PENDING."
- "Break this initiative into Stride-shaped tasks on disk: <prompt>."
- "Write a goal directory for <prompt> using my docs/requirements docs."

Default flags: `--requirements-dir docs/requirements`, `--output-dir docs/implementation/PENDING`.

### `stride-copilot-lite-create-task` — render a single one-off task markdown file

Activate when the work is genuinely one task and a full goal decomposition would be overkill. Produces `<output-dir>/tasks/<slug>.md`.

Activation phrases:

- "Create a single Stride-shaped task for fixing the login button typo."
- "Write a one-off task markdown file: <prompt>."
- "Generate a Stride task spec from this prompt — just one task, no goal."

Same default flags as `stride-copilot-lite-create-goal`. The per-task markdown template is byte-identical to the one in the goal flow (enforced by AGENTS.md cross-skill contract).

### `stride-copilot-lite-init` — scaffold the `.stride_lite.md` hook config

Activate when you want to create the project-local `.stride_lite.md` config file (four canonical sections: `## email`, `## before_task`, `## after_task`, `## after_goal`). The skill writes the scaffold and prints a success message; it does NOT execute the hook sections itself (that's `stride-copilot-lite-workflow`'s job).

Activation phrases:

- "Initialize stride-copilot-lite in this project."
- "Create the `.stride_lite.md` config file."
- "Scaffold the stride-lite hook configuration."
- "Set up the `.stride_lite.md` skeleton — overwrite the existing one if any." (passes `--force`)

Refuses to clobber an existing `.stride_lite.md` unless `--force` is supplied.

### `stride-copilot-lite-workflow` — drive a goal through the full eight-step lifecycle

Activate ONLY when you supply BOTH (a) explicit intent to work the goal end-to-end AND (b) a path to a goal directory. Without both signals the skill stays inactive — single-task requests and inspection requests should NOT activate it.

Activation phrases (intent + path):

- "Work the docs/implementation/PENDING/add-notifications goal."
- "Drive the add-notifications goal to completion."
- "Resume the add-notifications goal at docs/implementation/PENDING/add-notifications/."
- "Process all tasks in docs/implementation/PENDING/<slug>/."

The workflow iterates each `taskN.md` in numeric order: select-next → `## before_task` hook → dispatch `stride-copilot-lite:task-explorer` → implement → `## after_task` hook → dispatch `stride-copilot-lite:task-reviewer` → review-loop (cap 3) → append `## Completion Summary` → next task. On the final task it also writes the goal-level `## Completion Summary` to `goal.md`, fires `## after_goal`, and moves the directory from `PENDING/` to `IMPLEMENTED/`.

**The loop scales to the task.** A one-line fix should not pay two subagent dispatches and two hook runs, so a decision matrix reads each task's complexity and its `## Key files` count and picks a branch:

| Complexity | Key files | Explore | Plan | Review |
|---|---|:---:|:---:|:---:|
| `small` | 0–1 | skip | skip | skip |
| `small` | 2 or more | yes | skip | yes |
| `medium` or `large` | any | yes | yes | yes |
| absent or unreadable | any | yes | yes | yes |

**Every task's Completion Summary records what actually ran.** All seven task-level steps — `enricher`, `before_task`, `explorer`, `planner`, `implementation`, `after_task`, `reviewer` — appear every time, each marked dispatched or skipped, with a duration where one was measured and a reason naming the rule when it was not. A skipped step is recorded, never omitted: omission is exactly the shortcut the record exists to catch, and a summary that simply does not mention the explorer is indistinguishable from one where it was forgotten. It renders as a table for you plus a fenced JSON block for tooling.

An unreadable signal takes the full branch — absence of evidence is not evidence of a small task. Because this port fires `## before_task` / `## after_task` on the workflow's boundary writes, a skipped step also skips its hook, so on the `skip-all` row your `git pull` and test commands do not run for that task. Every skip is recorded in the task's `## Completion Summary` along with the rule that caused it, so a skip is never indistinguishable from a bug. The matrix mirrors the Claude Code plugin's, and `lib/select_workflow_branch.md` is its normative specification.

### Automatic enrichment of sparse task files

`stride-copilot-lite-create-goal` writes task files from your prompt with **no codebase access** — so `## Key files`, `## Patterns to follow` and `## Testing strategy` start out as informed guesses, and a hand-written task file may have nothing in them at all.

Before acting on a task, the workflow checks whether `## Key files`, `## Acceptance criteria`, `## Verification steps` or `## Testing strategy` are empty or `(none)`. If any are, it dispatches the **`task-enricher`** subagent, which explores your codebase and fills them in place. It fills only the sections that were empty; everything else in the file — the title, `## Description`, `## Why`, `## What`, and every already-populated section — comes back byte-identical. It appends nothing, so it never collides with the `## Exploration Report` that `task-explorer` appends later.

A fully-specified task file skips enrichment entirely. If the enricher cannot ground a section it leaves it `(none)` and says so, because a section left honestly empty is a signal to the implementer and one filled with plausible filler is a trap.

The agent holds `read`, `search`, `glob` and `write` — no command execution, and deliberately no streaming-edit tool, so it reads the whole file and writes it once rather than leaving a half-enriched task file behind on a failure.

### Hook failure triage

A blocking `## before_task` or `## after_task` failure stops the run — and `after_task` is where your test suite and linter usually live, so the raw output is two tools' failures interleaved. Rather than dumping that, the workflow dispatches the **`hook-diagnostician`** subagent with the structured failure JSON the hook already emits, and surfaces a prioritized fix plan instead.

The stop is unchanged: triage makes a blocking failure *useful*, never optional, and the agent never re-runs or repairs the failing command. It holds `read`, `search` and `glob` — no command execution, so a diagnostician cannot act on a misdiagnosis. It also never echoes the captured stdout/stderr tails back verbatim, since those can carry environment values, paths and occasionally secrets, and it treats all captured output as data to classify rather than as instructions.

An `after_goal` failure is advisory — the workflow is finishing rather than halting — so triage there is available but optional.

### Optional: exploratory testing and hardening

If you also install [stride-copilot-exploratory-testing](https://github.com/cheezy/stride-copilot-exploratory-testing), the workflow gains two extra steps after the reviewer. Both are **gated and optional** — with the plugin absent, nothing changes and nothing fails.

- **Manual & exploratory testing.** Your task's `## Testing strategy` manual-test entries become exploratory charters, and the plugin's `explorer` agent runs one budgeted session per charter against your running app. Today those entries just sit in the file as a note to a human who may never read them.
- **Hardening.** Oracle-confirmed bugs from those sessions become drafted regression checks, staged under `.exploratory/checks/`.

Three things are worth knowing before you turn this on:

**You are asked once, at activation, whether the target is yours to test and is not production.** That affirmative is a safety control. It is never inferred — not from a `localhost` URL, not from anything a task file says — and if you do not give it, exploratory testing simply skips. Sessions exercise your app as a user would and never run destructive or production-mutating actions.

**Drafted checks are drafts.** Hardening runs nothing, so a draft is never reported as passing. One enters your test tree only after the project's own gate command has come back clean across the whole suite; otherwise it stays staged with a follow-up noted. A regression check for a bug you have not fixed yet is *supposed* to fail, and a red check in the tree would take down the next reviewer dispatch and the next task's `## after_task`.

**Add `.exploratory/` to your `.gitignore` before the first session.** Session artifacts hold transcribed application output and arrive untracked, so a gate that stages everything before committing would sweep them in. `.gitignore` is inert for a path git already tracks, so doing it first is the difference between the line working and doing nothing.

Whatever ran — or did not — is recorded in the task's Completion Summary, including which sessions were partial and which did not happen.

### Optional: deep security-considerations review

Install [stride-copilot-security-review](https://github.com/cheezy/stride-copilot-security-review) and the workflow gains one more gated step. Every task file renders a `## Security considerations` section, and the generalist reviewer gives it one overall verdict — but nothing checks the listed considerations one by one, so an implication the task author wrote down can ship unaddressed behind a green review.

When the section carries **real** entries (a `(none)` placeholder or an entry beginning `None —` does not count) and the plugin is installed, the specialist reviewer is dispatched with your working-tree diff and that list, and returns one verdict per consideration: `mitigated`, `partial` or `unmitigated`, each with a `file:line` evidence reference.

**Any `partial` or `unmitigated` verdict sends the task back to implementation**, through the same review loop and the same 3-iteration cap that a `changes_requested` review already uses — so a persistently unaddressed consideration stops the run rather than looping forever. There is no second loop and no second cap.

**Every failure mode is fail-closed**, because this step is itself a security control: no plugin means no verdict recorded rather than a passing one, and a malformed or empty verdict set is treated as unaddressed rather than downgraded to passed. Inability to confirm mitigation is never the same as confirming it.

## Subagents

Five agents ship with the plugin. You never invoke them directly — the workflow dispatches them when its decision matrix and gates call for it — but knowing what each does makes a Completion Summary readable.

| Agent | Runs when | What it does |
|---|---|---|
| `create-decomposer` | You ask for a goal or a task | Turns your prompt plus any requirements docs into the structured decomposition the create skills render. It has **no codebase access at all** — which is why the sections it writes are informed guesses, and why the enricher exists. |
| `task-enricher` | A task's operational sections are empty or `(none)` | Explores your codebase and fills in the derivable sections in place. Never touches the title, `## Description`, `## Why` or `## What` — those are intent, not derived context. |
| `task-explorer` | The matrix calls for exploration | Reads the task's key files and patterns, then appends an `## Exploration Report`. |
| `task-reviewer` | The matrix calls for review | Reads the task file and `git diff HEAD`, then appends a `## Review Report` whose embedded JSON drives the review loop. |
| `hook-diagnostician` | A blocking hook fails | Turns the hook's structured failure JSON into a prioritized fix plan instead of a raw dump. It never re-runs or repairs the failing command. |

Two more agents can be dispatched from **other plugins** when you have them installed — an exploratory-testing explorer and a security reviewer. Both are optional and both gate to a clean skip when absent.

## What gets written where

A goal drive produces this layout, all of it plain markdown you can read and edit:

```
docs/implementation/PENDING/<slug>/     the goal, while it is in flight
  goal.md                               why/what + a link index to each task
  task1.md                              one file per task, each accumulating:
  task2.md                                ## Exploration Report   (from task-explorer)
  ...                                     ## Review Report        (from task-reviewer)
                                          ## Completion Summary   (synthesis + telemetry)

docs/implementation/IMPLEMENTED/<slug>/ where the goal moves when every task is done

.stride_lite.md                         your hook commands (you write this)
.stride-copilot-lite/                   transient run state — gitignore it
.exploratory/                           session artifacts, if you use that plugin — gitignore it
```

Nothing is deleted and nothing is overwritten: a name collision resolves to `<slug>-2`, `<slug>-3` and so on.

## What this plugin does not do

- **No network calls.** No API client, no telemetry, no update check. The only thing that can reach the network is a command you wrote in `.stride_lite.md`.
- **No kanban server, no accounts, no auth files.** There is nothing to sign into and nothing to configure beyond `.stride_lite.md`.
- **No credential handling.** It never reads, stores or transmits credentials, and the agents that write files are forbidden from copying secret-bearing material into them.
- **No writes outside your project** — the goal directory you name, `.stride_lite.md`, and the two transient state directories above.
- **No silent overwrites.** Existing goal directories, task files and configs are never clobbered; `init` refuses without `--force`.
- **No questions mid-flow.** The workflow asks at activation and then runs to completion or stops with a reason.

See [SECURITY.md](SECURITY.md) for the execution model in full.

## Configuration

stride-copilot-lite reads a project-local `.stride_lite.md` config file at the repository root. The file has four canonical sections, each a fenced bash block whose body the harness runs at the corresponding lifecycle point:

```markdown
## email

your-email@example.com

## before_task

```bash
# commands to run before each task (e.g., `git pull origin main`)
```

## after_task

```bash
# commands to run after each task implementation (e.g., `mix test`, `mix format`)
```

## after_goal

```bash
# commands to run when the final task in a goal completes (e.g., `gh pr create`)
```
```

Generate the skeleton by activating `stride-copilot-lite-init` (see Skills below) or copy the example above. The `email` section is informational. The three hook sections are auto-fired by the harness via `hooks/hooks.json`:

| Hook | Fires on | Blocking | Purpose |
|---|---|:---:|---|
| `## before_task` | `PreToolUse` + the workflow's boundary-marker write at Step 2 | yes | Pull latest code, install deps, ensure clean working tree |
| `## after_task` | `PreToolUse` + the workflow's boundary-marker write at Step 5 | yes | Run tests / lint / format before the reviewer evaluates the diff |
| `## after_goal` | `PostToolUse` + edit/write on a `goal.md` whose content contains `## Completion Summary` (Step 8) | advisory | Generate a PR, post artifacts, kick off a release pipeline |

All three fire on **both** GitHub Copilot CLI and Claude Code. At each task boundary the workflow writes a one-line marker to `.stride-copilot-lite/lite-boundary`, and that write is the interceptable event — Copilot CLI emits no skill- or agent-dispatch event to key on, so the marker is what makes `before_task` and `after_task` work there. The hook routes only when the path and the marker body both match, so writing that token into any other file, or naming it in a shell command, fires nothing. Under Claude Code the subagent dispatch is still recognised for goal directories driven by an older workflow skill, and each boundary still fires exactly once. `AGENTS.md` → "Hook intercept design" records the reasoning and the rejected alternatives.

A failing `before_task` or `after_task` stops the workflow on either runtime: the hook returns `exit 2` for Claude Code and a `permissionDecision: deny` object for Copilot CLI, so neither can continue past a hook the other blocked on. `after_goal` stays advisory — a `PostToolUse` hook cannot roll back the write it follows.

**Hooks fire only inside a workflow run.** Because the boundary intercept is a file write, it necessarily matches more tool calls than a subagent dispatch would. So the workflow also writes an activation marker at `.stride-copilot-lite/.orchestrator_active` when it starts and deletes it when it stops, and the hook runs a section only while that marker is present and less than 4 hours old. Editing files outside a workflow run therefore fires nothing — your `git pull` or test suite cannot be triggered by ordinary work. A hook that stands down never blocks the tool call; it simply does nothing.

Set `STRIDE_COPILOT_LITE_ALLOW_DIRECT=1` to bypass the gate when debugging or in CI. It is not a setting to leave on.

This is a coordination mechanism, not a security boundary — any local process on your machine can write the marker file.

These files are written into **your** project under `.stride-copilot-lite/`: the activation marker, the boundary marker, and a small fired-record. All are transient session state — add `.stride-copilot-lite/` to your project's `.gitignore` so a workflow run does not leave them in a commit.

### Variables available to your hook commands

Each command runs with these in its environment, all derived from your goal and task markdown — there is no server involved:

| Variable | Value | Present in |
|---|---|---|
| `HOOK_NAME` | `before_task`, `after_task` or `after_goal` | all three |
| `AGENT_NAME` | Always `stride-copilot-lite` | all three |
| `TASK_FILE` | Absolute path to the active `taskN.md` | `before_task`, `after_task` |
| `TASK_NUMBER` | The `N` from `taskN.md` | `before_task`, `after_task` |
| `TASK_TITLE` | The task file's first `# ` heading | `before_task`, `after_task` |
| `GOAL_DIR` | Absolute path to the goal directory | all three |
| `GOAL_FILE` | Absolute path to `goal.md` | all three |
| `GOAL_SLUG` | Basename of the goal directory | all three |
| `GOAL_TITLE` | `goal.md`'s first `# ` heading | all three |

```bash
gh pr create --title "$GOAL_TITLE" --body "Implements $GOAL_SLUG."
```

A variable that cannot be derived is the **empty string**, never an error — so referencing one is always safe, including under `set -u`. Values arrive as environment values and are never spliced into your command text, so a task title containing `$(...)` or backticks is inert.

If you are migrating a `.stride_lite.md` from the Claude Code [stride-lite](https://github.com/cheezy/stride-lite) plugin, note this set is smaller: there is no `BOARD_ID`, `COLUMN_NAME` or `TASK_STATUS`, because this plugin has no board, column or status. Everything else transfers unchanged.

You do NOT need `.stride_lite.md` to use the create/init skills — only the `stride-copilot-lite-workflow` orchestrator activates the hooks.

## Migration from stride-lite

**Your existing `.stride_lite.md` works unchanged.** The filename and its four canonical sections (`## email`, `## before_task`, `## after_task`, `## after_goal`) are identical across both plugins, and the executor parses them the same way. Copy the file across and it runs.

**Your goal directories work in both directions too.** The on-disk artifacts — goal directories, task markdown files and the embedded per-task template — are byte-identical, so a goal created by stride-lite can be driven by this plugin's workflow and vice versa. That is verified rather than asserted: both plugins' `fixtures/expected-output/` files diff clean against each other.

Differences to expect:

- **No slash commands.** Claude Code stride-lite ships `/stride-lite:create-goal`, `/stride-lite:create-task`, `/stride-lite:init`. Copilot has no equivalent surface — use the natural-language activation phrases in the Skills section instead.
- **Subagent identities are prefixed differently.** Cross-references in your scripts or CI to `stride-lite:task-explorer` / `stride-lite:task-reviewer` become `stride-copilot-lite:task-explorer` / `stride-copilot-lite:task-reviewer`. The `.stride_lite.md` hook sections themselves are agnostic to the plugin name and need no change.
- **`hooks/hooks.json` matchers.** stride-lite uses Claude Code's matcher names (`Agent`, `Edit`, `Write`); this plugin adds Copilot's lowercase forms by regex alternation (`Edit|edit`, `Write|create`), so one hooks.json covers both runtimes.
- **The hooks fire at a different moment here, and that is deliberate.** Copilot CLI emits no skill- or agent-dispatch event, so `before_task` and `after_task` cannot key on one. This plugin's workflow writes a boundary marker instead and the harness intercepts that write. Your hook *commands* are unaffected; only the trigger differs.
- **The scaffolded template is not byte-identical, though your config is.** `stride-copilot-lite-init` writes a template carrying this plugin's variable documentation and example comments, which stride-lite's does not have. That affects a **newly scaffolded** file only — an existing config remains fully compatible, which is the promise that actually matters when migrating.

## Running the test suites

Three suites, all pure shell/PowerShell — no test framework, no network, no dependencies beyond what the plugin itself needs.

```bash
bash test/smoke.sh                             # lib/ helpers, the decision matrix, agent contracts
bash hooks/test-stride-copilot-lite-hook.sh    # the bash hook executor
pwsh -File hooks/test-stride-copilot-lite-hook.ps1   # the PowerShell hook executor
```

Each exits `0` when every assertion passes and `1` on the first failure, printing the failing case with its expected and actual values to stderr. Run all three before opening a PR.

**What has been verified, and where.** Both suites are run on macOS — bash 5 and PowerShell 7 (`pwsh`). The PowerShell executor has **not** been exercised on Windows PowerShell on a Windows host; it is written for it and the suite passes under `pwsh`, but that is a different runtime and saying otherwise would overstate it. If you run it on Windows, a passing or failing report is genuinely useful.

**Both hook suites are needed, not one or the other.** They exercise two independent implementations of the same contract, and each has caught bugs the other could not see. The bash suite additionally runs a **cross-executor parity check**: it feeds a shared fixture set through both executors and diffs the emitted JSON, so a change that alters one runtime's behaviour without the other fails there rather than in the field. On a host without `pwsh` that check reports a **skip with a reason** rather than passing silently — an absent run stays distinguishable from a passing one.

Every fixture command is inert (`true`, `false`, `echo`, a `printf` into the sandbox) and confined to a temporary directory the suite creates and removes. The suites write nothing into your checkout and leave no marker directory behind, both of which they assert before finishing.

## License

[MIT](LICENSE) — Copyright (c) 2026 Jeff Morgan.
