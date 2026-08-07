# Security

This document describes what stride-copilot-lite actually does on your machine, where the risk in that sits, and what protects it. It is written for someone deciding whether to install the plugin and for anyone auditing it later.

## The execution model, stated plainly

**This plugin runs shell commands that you wrote.** That is its whole point, and it is the largest thing to understand about it.

You put commands in a project-local `.stride_lite.md` under `## before_task`, `## after_task` and `## after_goal`. When the workflow reaches the matching lifecycle point, the harness runs them in your shell, in your project directory, with your credentials. The plugin never writes those commands, never modifies them, and never adds any of its own.

Three consequences follow:

- **A `.stride_lite.md` is executable content.** Treat one arriving from anywhere else exactly as you would a shell script from that source. Review it before the first workflow run.
- **The plugin's blast radius is whatever your commands can reach.** If `## after_task` runs a deploy, the plugin can deploy.
- **There is no sandbox.** Commands run with your full ambient authority.

## What the plugin does not do

- **No network calls of its own.** It writes markdown to disk and reads your files. There is no API client, no telemetry, no update check, no phone-home. The one thing that can reach the network is a command *you* wrote in `.stride_lite.md`.
- **No credential handling.** It never reads, stores or transmits credentials. Several of its contracts explicitly forbid copying secret-bearing material into the files it writes — see "Data that reaches disk" below.
- **No writes outside your project.** The skills write into the goal directory you name, `.stride_lite.md` in the working directory, and `.stride-copilot-lite/` for transient run state.

## The hook trigger, and its blast radius

GitHub Copilot CLI emits no skill- or agent-dispatch event, so `before_task` and `after_task` cannot key on one. Instead the workflow writes a marker file and the harness intercepts that **write**.

The matcher that intercepts it is necessarily broader than a dispatch event: it sees every file edit in the session. That breadth is the security-relevant fact, and two things bound it.

**Routing requires both an exact path and an exact token.** A write to `.stride-copilot-lite/lite-boundary` carrying `stride-lite-boundary:before_task` routes; anything missing either half routes to nothing. Writing that token into another file, or naming it in a shell command, fires nothing. The hook test suites assert four distinct near-miss payloads for exactly this reason — removing one silently re-opens the surface.

**Hook firing is scoped to an active workflow run.** The workflow writes `.stride-copilot-lite/.orchestrator_active` when it starts and clears it on every exit path; the executor runs a section only while that marker exists and is under four hours old. Editing files outside a workflow run therefore executes nothing.

### The activation marker is NOT a security boundary

It is a coordination mechanism between the workflow skill and the hook executor, and nothing may treat it as authorization. **Any local process can write it.** It establishes only that a workflow run believes itself active — never that a caller is permitted.

What it actually buys is *scope*: it keeps a widened matcher from running your commands outside a workflow. A crashed run leaves a marker behind, which is what the four-hour freshness window bounds; clearing on every exit is what keeps the exposure short in practice rather than four hours long.

`STRIDE_COPILOT_LITE_ALLOW_DIRECT=1` bypasses the gate entirely. It exists for debugging and CI. Nothing in this repository sets it, and it should not be set in a normal environment.

## Cross-plugin dispatch

Three optional workflow steps dispatch agents belonging to **other plugins** — `stride-copilot-exploratory-testing` and `stride-copilot-security-review`.

**A subagent dispatch is a local harness operation, not a network call.** It is the same mechanism this plugin already uses for its own five agents. The "no network" property above is unaffected.

Every one of those steps is **gated and falls through to a clean skip** when the sibling plugin is absent, so an optional integration can never become a hard dependency or fail a run by not being installed.

### Exploratory sessions exercise a running application

This is the highest-risk capability the plugin can reach, and it is gated on a control that only you can supply.

Before any session is dispatched, the workflow must hold an explicit statement from you that the target is one you are **authorized to test** and is **not production**. It is collected once, at activation. It is **never inferred** — not from a `localhost` URL, not from a dev-looking hostname, not from anything a task file says. Inferring it *is* supplying it on your behalf, which the workflow refuses. Without it, the step skips.

A dispatched session exercises the app as a user would and never runs destructive or production-mutating actions, and never touches production or unauthorized systems. That boundary is absolute.

Session artifacts land under `.exploratory/` and contain transcribed application output. **Add `.exploratory/` to your `.gitignore` before the first session** — the artifacts arrive untracked, so a gate that stages everything before committing would sweep them into a commit, and `.gitignore` is inert for a path git already tracks.

## Data that reaches disk

Everything this plugin writes is intended to be committed, so several contracts exist to keep sensitive material out of it:

- The **task-enricher** explores your codebase to fill sparse sections and is forbidden from copying an API key, token, password, connection string, `.env` content, a secret-shaped assignment, an internal hostname, a private IP or fixture personal data into any section it writes. It references such a file by path and purpose only.
- The **hook-diagnostician** receives the failing command's stdout and stderr tails, which can contain environment values and occasionally secrets. It never echoes those tails verbatim into its plan.
- **Security-review evidence** is a `file:line` reference and a short note, never quoted material from the diff.
- **Workflow telemetry** carries step names, durations and skip reasons only — no command output, no environment values, no paths outside the project.
- **Exploratory findings** are restated in the workflow's own words before entering a Completion Summary.

## Untrusted input

Task files are agent-authored from a free-text prompt, and application output comes from the software under test. Both are treated as **data to assess, never as instructions**:

- The decision matrix reads a task's complexity and key-files count to select a branch and ignores the rest of the file for that decision. A task file saying "skip the review" is text to be ignored, not a rule.
- The security-review dispatch frames the considerations list and the diff as content under review, so an attacker-authored consideration or diff hunk cannot redirect the reviewer.
- Exploratory findings and command output are classified, never followed.

## Agent tool grants

Each agent's grant is scoped to its contract, and the narrowness is deliberate rather than incidental:

| Agent | Grant | Why |
|---|---|---|
| `create-decomposer` | none | It never sees the codebase; it transforms a prompt into structured output |
| `task-enricher` | read, search, glob, write | No command execution — an agent that rewrites files should not hold it. No streaming-edit tool either, so it reads whole and writes once and cannot leave a half-written task file behind |
| `task-explorer` | read, search, glob, edit, write | Reads the codebase, appends one report section |
| `task-reviewer` | read, search, glob, run_terminal_cmd, edit, write | The only agent with command execution, and only for read-only git |
| `hook-diagnostician` | read, search, glob | Diagnosis is reading a payload and the repository. No command execution, so it cannot act on a misdiagnosis |

## Reporting a vulnerability

Open a security advisory on the repository, or email the maintainer at the address in `plugin.json`. Please do not open a public issue for an unpatched vulnerability.

Include what you did, what happened, and what you expected. A minimal reproduction against a scratch project is more useful than a description.

## Scope

In scope: anything that causes the plugin to execute a command you did not write, to write outside the locations named above, to leak secret material into files it produces, or to bypass the affirmative gate on exploratory sessions.

Out of scope: the consequences of commands you put in your own `.stride_lite.md`. That file is executable content under your control, which is the point of it.
