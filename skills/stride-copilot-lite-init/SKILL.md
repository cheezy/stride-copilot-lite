---
name: stride-copilot-lite-init
description: Use to scaffold a `.stride_lite.md` config file in the current working directory containing the four canonical sections (`## email`, `## before_task`, `## after_task`, `## after_goal`). The skill writes one file and prints a success message instructing the user to fill in the fields. Refuses to clobber an existing `.stride_lite.md` unless `--force` is supplied. The init skill itself never executes the hook sections (it is purely a scaffolder); the Copilot harness auto-fires them via `hooks/hooks.json` at the corresponding lifecycle points (before_task before the task-explorer dispatch, after_task before the task-reviewer dispatch, after_goal when the final task's goal.md Completion Summary is written). Never POSTs to any API. Activate when the user asks to initialize stride-lite, create a `.stride_lite.md` config, or scaffold the hook configuration file (optionally with `--force` to overwrite an existing file).
skills_version: "1.0"
---

# stride-copilot-lite-init

Surface skill for the init flow. Writes a project-local `.stride_lite.md` file with the canonical four-section template, and prints a one-paragraph message asking the user to fill in the fields. The hook sections (`before_task`, `after_task`, `after_goal`) are **auto-fired by the Copilot harness via `hooks/hooks.json`** at the corresponding lifecycle points — this init skill only scaffolds them and never runs them itself. The format mirrors the full Stride plugin's `.stride.md` so users moving between the two plugins recognize the shape.

## What this skill does

```
parse_args (--force?)  ->  collision check on ./.stride_lite.md
                       ->  write canonical template to ./.stride_lite.md
                       ->  print "fill in the fields" success message
```

That is the entire side effect.

## What this skill does NOT do

- **Never POSTs to any API.** stride-lite remains a "no network" plugin.
- **Never executes the hook sections.** The init skill is a pure scaffolder — it writes the template, prints the success message, exits. The hook sections (`## before_task`, `## after_task`, `## after_goal`) are auto-fired by the Copilot harness via `hooks/hooks.json`, not by this skill.
- **Never writes outside the current working directory.** No absolute paths, no parent traversal (`../`), no `$HOME` resolution. The target is always `./.stride_lite.md` relative to the cwd at invocation time.
- **Never clobbers an existing `.stride_lite.md`** unless `--force` is supplied. The self-contained collision-check block in Step 2 enforces this safety posture.
- **Never asks the user mid-flow.** The invocation is fire-and-forget.

## Inputs

| Input | Default | Notes |
|---|---|---|
| `--force` | absent | Boolean flag. When present, overwrites an existing `./.stride_lite.md`. When absent and the file already exists, the skill exits non-zero with a "use --force to overwrite" message. |

No positional arguments. No other flags. Any unknown argument is a hard error surfaced to the user (do NOT silently absorb).

## Flow

### Step 1 — Parse arguments

Parse the skill's invocation arguments for a single optional `--force` token. Two valid invocation shapes:

- `` (empty) — no overwrite
- `--force` — overwrite allowed

Anything else is an error: print `"stride-copilot-lite-init: unknown argument: <arg>"` to stderr and exit non-zero. Do NOT fall back to a default behavior.

### Step 2 — Write `./.stride_lite.md` with collision check

Resolve the target path as exactly `./.stride_lite.md` relative to the current working directory. Do not canonicalize, do not follow symlinks to alternate locations.

Collision-check pattern (self-contained — this skill carries the full check; there is no external installer):

```bash
TARGET=".stride_lite.md"

if [ -e "$TARGET" ] && [ "$FORCE" -ne 1 ]; then
  echo "stride-copilot-lite-init: .stride_lite.md already exists in the current directory" >&2
  echo "Re-run with --force to overwrite." >&2
  exit 1
fi

# If --force AND the target exists, remove it first (defensive — handles the rare
# case where the existing entry is a directory rather than a file).
if [ "$FORCE" -eq 1 ] && [ -e "$TARGET" ]; then
  rm -rf "$TARGET"
fi
```

Then write the canonical template (verbatim from "Canonical template" below) to `$TARGET`.

### Step 3 — Print the success message

After the file write succeeds, print exactly this paragraph to stdout (a fresh line for each sentence):

```
Wrote .stride_lite.md to the current directory.

Open the file and fill in the four sections:
  - ## email — your contact email
  - ## before_task — the shell commands you want to run before starting each task (auto-fired by the Copilot harness before the task-explorer dispatch)
  - ## after_task — the shell commands you want to run after each task's implementation (auto-fired by the Copilot harness before the task-reviewer dispatch)
  - ## after_goal — the shell commands you want to run when the final task in a goal completes (auto-fired by the Copilot harness when the goal.md Completion Summary is written)

The hook sections are auto-fired by the Copilot harness via hooks/hooks.json at the corresponding lifecycle points. The format mirrors the full Stride plugin's .stride.md so your snippets transfer across plugins.
```

That is the entire stdout output. The skill does not chain into any follow-up command.

## Canonical template

The skill writes this exact text to `./.stride_lite.md`. Keep the section order and the empty fenced bash blocks byte-equivalent to the format used by the full Stride plugin's `.stride.md` — that mental-model transfer is the reason for the empty-bash-block shape.

````markdown
# Stride Lite Configuration

This file is created by the `stride-copilot-lite-init` skill. Fill in the fields below.

**Note:** The hook sections are auto-fired by the Copilot harness via `hooks/hooks.json` at the corresponding lifecycle points (`before_task` and `after_task` on the workflow's boundary-marker write, `after_goal` when the final task's goal.md Completion Summary is written). The format mirrors the full Stride plugin's `.stride.md` so your snippets transfer across plugins.

**Available variables.** Each command runs with `HOOK_NAME`, `AGENT_NAME`, `TASK_FILE`, `TASK_NUMBER`, `TASK_TITLE`, `GOAL_DIR`, `GOAL_FILE`, `GOAL_SLUG` and `GOAL_TITLE` in its environment. A variable that cannot be derived is an empty string rather than an error, so it is always safe to reference one. The board-shaped variables from the full Stride plugin (`BOARD_ID`, `COLUMN_NAME`, `TASK_STATUS`) do not exist here — this plugin has no board.

## email

your-email@example.com

## before_task

```bash
# Runs before each task. e.g. git pull origin main
# echo "Starting task $TASK_NUMBER: $TASK_TITLE"
```

## after_task

```bash
# Runs after each task implementation. e.g. mix test
```

## after_goal

```bash
# Runs when the final task in a goal completes.
# gh pr create --title "$GOAL_TITLE" --body "Implements $GOAL_SLUG."
```
````

## Pitfalls

- **Don't execute the hook sections in THIS skill.** The init skill is a pure scaffolder — write the file, print the message, exit. Hook execution is handled by the Copilot harness via `hooks/hooks.json`, not by any skill body.
- **Don't omit any of the four sections.** The template contract is exact: `## email`, `## before_task`, `## after_task`, `## after_goal`, in that order.
- **Don't clobber an existing `.stride_lite.md` without `--force`.** Refuse and exit non-zero with a clear message pointing to the flag.
- **Don't write the file anywhere except the cwd.** No absolute paths, no parent traversal, no `$HOME` or `$XDG_CONFIG_HOME` resolution.
- **Don't make any API calls.** No `curl`, no Stride client, no network.
- **Don't require `stride-copilot-lite-init` to have run before the other surface skills.** `stride-copilot-lite-create-goal` and `stride-copilot-lite-create-task` must continue to work without `.stride_lite.md` present.

## Red flags — STOP

If you catch yourself thinking any of these, go back to the documented step:

- **"`.stride_lite.md` already exists but looks like a stub — I'll overwrite it."** No. Refuse without `--force`. What looks like a stub may be a config whose hook sections the user has deliberately left empty.
- **"I'll run the hook sections to check they work."** No. This skill is a pure scaffolder. The harness fires the hooks via `hooks/hooks.json`; executing them here would run the user's commands at a moment nothing expects.
- **"I'll rename the config file to match this plugin's name."** No. `.stride_lite.md` is a compatibility promise — the same file works with the Claude Code plugin, and the README says so.

## Rationalization table

| "I'll just…" | Reality | Consequence if you do |
|---|---|---|
| "…overwrite the existing config; it's nearly empty." | The refusal is the contract; `--force` is how a user opts in. | You destroy hook commands someone wrote, and the next workflow run silently does something different. |
| "…execute the sections to verify the scaffold." | This skill never executes hook content. | The user's `git pull` or test suite runs at scaffold time, outside any workflow and with no marker active. |
| "…rename the file to `.stride_copilot_lite.md` for consistency." | The filename and its four section names are a byte-identical-config promise to stride-lite users. | Every migrated config stops being found, and the hooks silently become no-ops. |
| "…rename a section to something clearer." | The executor matches the four canonical section names exactly. | The renamed section is never found and its commands never run — a silent no-op, not an error. |
| "…add a fifth section for a hook I think is useful." | The executor routes three sections plus `## email`; a fifth is dead text. | A user writes commands into it and reasonably expects them to run. Nothing ever does. |

## Edge cases

- **`.stride_lite.md` exists as a regular file** — refuse without `--force`; overwrite with `--force` (the `rm -rf` step in the collision-check block handles the unlikely directory case as well).
- **`.stride_lite.md` exists as a directory** — same `--force` rule applies. The `rm -rf` in the collision-check block removes the directory before writing the file.
- **User lacks write permission in cwd** — the file-write step fails with the shell's standard "permission denied" error; surface that and exit non-zero. Do not retry, do not prompt.
- **`--force` supplied but no existing file** — proceed as if `--force` were absent. No error, no warning. `--force` only matters when there is something to overwrite.
- **Unknown argument** — hard error. Do not silently absorb into a positional argv slot; the command takes no positionals.
