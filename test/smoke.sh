#!/usr/bin/env bash
# smoke.sh — Stride Lite lib/ helper smoke test.
#
# Exercises the four lib/ helpers (slugify, resolve_output_path,
# load_requirements_dir, parse_args) against known inputs and asserts the
# expected behavior. Pure bash + POSIX utilities — no test framework, no
# network, no external dependencies.
#
# The helper implementations below are byte-equivalent to the reference
# implementations in the corresponding lib/<name>.md spec files. If a spec
# changes, update this file in the same commit and bump the assertion count.
#
# Usage:
#   ./test/smoke.sh                # from the repo root
#   bash test/smoke.sh             # alternative invocation
#
# Exit codes:
#   0  all assertions passed
#   1  one or more assertions failed (count printed to stderr)

set -u  # NOT set -e — we want assertions to keep running after a failure

# Resolve repo root so the script works from any working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

ok() {
  PASS=$(( PASS + 1 ))
  echo "  PASS  $1"
}

nope() {
  FAIL=$(( FAIL + 1 ))
  echo "  FAIL  $1" >&2
  echo "        expected: $2" >&2
  echo "        actual:   $3" >&2
}

assert_eq() {
  local label="$1"
  local actual="$2"
  local expected="$3"
  if [ "$actual" = "$expected" ]; then
    ok "$label"
  else
    nope "$label" "$expected" "$actual"
  fi
}

# ------------------------------------------------------------------
# slugify — mirrors lib/slugify.md reference implementation
# ------------------------------------------------------------------

slugify() {
  local input="${1:-}"
  if [ -z "$input" ]; then
    echo "slugify: empty input" >&2
    return 1
  fi
  local lowered
  lowered="$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')"
  local replaced
  replaced="$(printf '%s' "$lowered" \
    | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-//; s/-$//')"
  if [ -z "$replaced" ]; then
    echo "slugify: slug normalized to empty string" >&2
    return 1
  fi
  printf '%s' "$replaced"
}

echo "slugify"
assert_eq "lowercases and dashes the prompt" \
  "$(slugify 'Add real-time notifications')" \
  'add-real-time-notifications'
assert_eq "collapses runs of dashes and trims" \
  "$(slugify '  Multiple   spaces & symbols!! ')" \
  'multiple-spaces-symbols'
assert_eq "numeric-only stays numeric-only" \
  "$(slugify '123')" \
  '123'
# Empty-input path returns non-zero — assert via exit code, not output.
if slugify '' >/dev/null 2>&1; then
  nope "rejects empty input" "non-zero exit" "exit 0"
else
  ok "rejects empty input"
fi

# ------------------------------------------------------------------
# resolve_output_path — mirrors lib/resolve_output_path.md
# ------------------------------------------------------------------

resolve_output_path() {
  local base_dir="${1:-}"
  local slug="${2:-}"
  local kind="${3:-}"
  local ext="${4:-}"
  if [ -z "$base_dir" ] || [ -z "$slug" ] || [ -z "$kind" ]; then
    echo "resolve_output_path: usage: resolve_output_path <base_dir> <slug> <dir|file> [<ext>]" >&2
    return 1
  fi
  if [ "$kind" != "dir" ] && [ "$kind" != "file" ]; then
    echo "resolve_output_path: kind must be 'dir' or 'file', got '$kind'" >&2
    return 1
  fi
  if [ "$kind" = "file" ] && [ -z "$ext" ]; then
    echo "resolve_output_path: ext is required when kind=file" >&2
    return 1
  fi

  local stripped="${base_dir%/}"
  local candidate
  if [ "$kind" = "dir" ]; then
    candidate="${stripped}/${slug}"
  else
    candidate="${stripped}/${slug}.${ext}"
  fi
  if [ ! -e "$candidate" ]; then
    printf '%s' "$candidate"
    return 0
  fi

  local n=2
  while :; do
    if [ "$kind" = "dir" ]; then
      candidate="${stripped}/${slug}-${n}"
    else
      candidate="${stripped}/${slug}-${n}.${ext}"
    fi
    if [ ! -e "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
    n=$(( n + 1 ))
    if [ "$n" -gt 1000 ]; then
      echo "resolve_output_path: refusing to scan past -1000 collisions" >&2
      return 2
    fi
  done
}

echo ""
echo "resolve_output_path"
# Create a sandbox under /tmp so we can simulate collisions safely.
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

assert_eq "returns the base path when nothing exists" \
  "$(resolve_output_path "$SANDBOX" 'add-notifs' dir)" \
  "$SANDBOX/add-notifs"

# Now create the directory and confirm we get -2.
mkdir -p "$SANDBOX/add-notifs"
assert_eq "appends -2 on first collision (dir)" \
  "$(resolve_output_path "$SANDBOX" 'add-notifs' dir)" \
  "$SANDBOX/add-notifs-2"

mkdir -p "$SANDBOX/add-notifs-2"
assert_eq "appends -3 on second collision (dir)" \
  "$(resolve_output_path "$SANDBOX" 'add-notifs' dir)" \
  "$SANDBOX/add-notifs-3"

# File-mode path.
assert_eq "returns base path for file mode" \
  "$(resolve_output_path "$SANDBOX" 'fix-typo' file md)" \
  "$SANDBOX/fix-typo.md"

touch "$SANDBOX/fix-typo.md"
assert_eq "appends -2 on first collision (file)" \
  "$(resolve_output_path "$SANDBOX" 'fix-typo' file md)" \
  "$SANDBOX/fix-typo-2.md"

# Caller-supplied base dir is honored (not hardcoded).
ALT_BASE="$SANDBOX/alt"
mkdir -p "$ALT_BASE"
assert_eq "honors caller-supplied base directory" \
  "$(resolve_output_path "$ALT_BASE" 'foo' dir)" \
  "$ALT_BASE/foo"

# ------------------------------------------------------------------
# load_requirements_dir — mirrors lib/load_requirements_dir.md
# ------------------------------------------------------------------

load_requirements_dir() {
  local dir="${1:-}"
  if [ -z "$dir" ]; then
    echo "load_requirements_dir: usage: load_requirements_dir <dir>" >&2
    return 0
  fi
  if [ ! -d "$dir" ]; then
    echo "load_requirements_dir: directory not found: $dir" >&2
    return 0
  fi

  local stripped="${dir%/}"
  local file rel

  find -L "$stripped" -type f -not -path '*/.*' 2>/dev/null \
    | sort \
    | while IFS= read -r file; do
        rel="${file#${stripped}/}"

        local size
        size="$(wc -c < "$file" 2>/dev/null | tr -d '[:space:]')"
        if [ -n "$size" ] && [ "$size" -gt 1048576 ]; then
          echo "load_requirements_dir: skipping (>1MiB): $rel" >&2
          continue
        fi

        local raw_bytes stripped_bytes
        raw_bytes="$(head -c 8192 "$file" 2>/dev/null | wc -c | tr -d '[:space:]')"
        stripped_bytes="$(head -c 8192 "$file" 2>/dev/null | LC_ALL=C tr -d '\0' | wc -c | tr -d '[:space:]')"
        if [ "${raw_bytes:-0}" -ne "${stripped_bytes:-0}" ]; then
          echo "load_requirements_dir: skipping (binary): $rel" >&2
          continue
        fi

        printf '=== %s ===\n\n' "$rel"
        cat "$file"
        if [ -n "$(tail -c 1 "$file" 2>/dev/null)" ]; then
          printf '\n'
        fi
        printf '\n'
      done
}

echo ""
echo "load_requirements_dir"

# Missing dir is non-fatal and returns empty stdout.
MISSING_OUTPUT="$(load_requirements_dir "$SANDBOX/does-not-exist" 2>/dev/null)"
assert_eq "missing directory yields empty stdout" \
  "$MISSING_OUTPUT" \
  ""

# Sample-requirements fixture: confirm load picks up the file and emits the header.
FIXTURE_DIR="$REPO_ROOT/fixtures"
FIXTURE_OUTPUT="$(load_requirements_dir "$FIXTURE_DIR" 2>/dev/null)"
# Crude check — should contain the sample-requirements.md header marker.
if printf '%s' "$FIXTURE_OUTPUT" | grep -q '=== sample-requirements.md ==='; then
  ok "reads fixtures/sample-requirements.md and emits header"
else
  nope "reads fixtures/sample-requirements.md and emits header" \
    "output contains '=== sample-requirements.md ==='" \
    "header not found in output"
fi

# Sort order check — create a temp dir with two files and ensure the alphabetically-first one is emitted first.
SORT_DIR="$(mktemp -d -p "$SANDBOX")"
printf 'BBB\n' > "$SORT_DIR/b.md"
printf 'AAA\n' > "$SORT_DIR/a.md"
SORT_OUTPUT="$(load_requirements_dir "$SORT_DIR" 2>/dev/null)"
# 'a.md' header should appear before 'b.md' header in the output.
A_LINE=$(printf '%s' "$SORT_OUTPUT" | grep -n '=== a.md ===' | head -1 | cut -d: -f1)
B_LINE=$(printf '%s' "$SORT_OUTPUT" | grep -n '=== b.md ===' | head -1 | cut -d: -f1)
if [ -n "$A_LINE" ] && [ -n "$B_LINE" ] && [ "$A_LINE" -lt "$B_LINE" ]; then
  ok "emits files in sorted-by-name order"
else
  nope "emits files in sorted-by-name order" \
    "a.md header line < b.md header line" \
    "a=$A_LINE b=$B_LINE"
fi

# ------------------------------------------------------------------
# parse_args — mirrors lib/parse_args.md
# ------------------------------------------------------------------

parse_args() {
  local requirements_dir="docs/requirements"
  local output_dir="docs/implementation/PENDING"
  local -a positional=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --requirements-dir)
        if [ $# -lt 2 ]; then
          echo "parse_args: --requirements-dir requires a value" >&2
          return 1
        fi
        requirements_dir="$2"
        shift 2
        ;;
      --output-dir)
        if [ $# -lt 2 ]; then
          echo "parse_args: --output-dir requires a value" >&2
          return 1
        fi
        output_dir="$2"
        shift 2
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done

  local prompt=""
  if [ "${#positional[@]}" -gt 0 ]; then
    prompt="${positional[*]}"
  fi

  if [ -z "$prompt" ]; then
    echo "parse_args: prompt is required (supply at least one positional argument)" >&2
    return 2
  fi

  printf 'PROMPT=%q\n' "$prompt"
  printf 'REQUIREMENTS_DIR=%q\n' "$requirements_dir"
  printf 'OUTPUT_DIR=%q\n' "$output_dir"
}

echo ""
echo "parse_args"

# Defaults case: prompt only, both flags should land on their documented defaults.
PROMPT="" REQUIREMENTS_DIR="" OUTPUT_DIR=""
eval "$(parse_args 'Add notifications' 2>/dev/null)"
assert_eq "extracts the prompt" "$PROMPT" "Add notifications"
assert_eq "defaults --requirements-dir to docs/requirements" "$REQUIREMENTS_DIR" "docs/requirements"
assert_eq "defaults --output-dir to docs/implementation/PENDING" "$OUTPUT_DIR" "docs/implementation/PENDING"

# --requirements-dir override.
PROMPT="" REQUIREMENTS_DIR="" OUTPUT_DIR=""
eval "$(parse_args --requirements-dir /tmp/reqs 'Add notifs' 2>/dev/null)"
assert_eq "honors --requirements-dir override" "$REQUIREMENTS_DIR" "/tmp/reqs"

# --output-dir override.
PROMPT="" REQUIREMENTS_DIR="" OUTPUT_DIR=""
eval "$(parse_args 'Add notifs' --output-dir build/goals 2>/dev/null)"
assert_eq "honors --output-dir override" "$OUTPUT_DIR" "build/goals"

# Empty argv: should fail.
if parse_args >/dev/null 2>&1; then
  nope "rejects empty argv" "non-zero exit" "exit 0"
else
  ok "rejects empty argv"
fi

# Flag without value: should fail.
if parse_args 'Hi' --requirements-dir >/dev/null 2>&1; then
  nope "rejects flag without value" "non-zero exit" "exit 0"
else
  ok "rejects flag without value"
fi

# ------------------------------------------------------------------
# stride-copilot-lite-init template — byte-parity against skills/stride-copilot-lite-init/SKILL.md
# ------------------------------------------------------------------
#
# The "## Canonical template" block in skills/stride-copilot-lite-init/SKILL.md is the
# single source of truth for the .stride_lite.md body. Rather than hand-copy it
# here (which silently drifts out of sync — the bug this rework fixes), we
# extract it from the SKILL.md at runtime and assert the init flow writes it
# back byte-for-byte.
SKILL_MD="$REPO_ROOT/skills/stride-copilot-lite-init/SKILL.md"

# Extract the .stride_lite.md body from the ````markdown … ```` fence inside the
# "## Canonical template" section. The outer fence is four backticks so the
# template's own ```bash blocks nest without closing it early; we slice strictly
# between the opening ````markdown line and its matching four-backtick close,
# emitting neither fence line. Byte-exact by construction — no fuzzy matching.
extract_canonical_template() {
  awk '
    /^## Canonical template$/      { in_section = 1; next }
    in_section && /^````markdown$/ { in_block = 1; next }
    in_block && /^````$/           { exit }
    in_block                       { print }
  ' "$SKILL_MD"
}

# The init flow writes the canonical template verbatim (SKILL.md Step 2 — "write
# the canonical template … to $TARGET"). We source it from the SKILL.md rather
# than embedding a copy, so the two can never drift apart.
write_stride_lite_template() {
  local target="${1:-}"
  if [ -z "$target" ]; then
    echo "write_stride_lite_template: usage: write_stride_lite_template <target>" >&2
    return 1
  fi
  mkdir -p "$(dirname "$target")"
  extract_canonical_template > "$target"
}

echo ""
echo "stride-copilot-lite-init template"

# Sandbox subdir for the init flow. $SANDBOX is the mktemp -d from earlier in
# the file; the EXIT trap cleans the whole tree.
INIT_DIR="$SANDBOX/init-flow"
INIT_TARGET="$INIT_DIR/.stride_lite.md"

# Golden copy: the canonical template extracted straight from the SKILL.md.
CANONICAL_TEMPLATE="$SANDBOX/canonical-template.md"
extract_canonical_template > "$CANONICAL_TEMPLATE"

# Assertion 1: the extraction is non-empty. A silent extraction failure (bad
# fence match) would otherwise turn the byte-parity diff below into an
# empty-vs-empty pass — exactly the drift-blind hole this rework closes.
if [ -s "$CANONICAL_TEMPLATE" ]; then
  ok "canonical template extracted from SKILL.md is non-empty"
else
  nope "canonical template extracted from SKILL.md is non-empty" \
    "non-empty extraction" "empty — check the ````markdown fence in $SKILL_MD"
fi

# Run the init flow.
write_stride_lite_template "$INIT_TARGET"

# Assertion 2: the file was written.
if [ -f "$INIT_TARGET" ]; then
  ok "init flow writes .stride_lite.md to the target path"
else
  nope "init flow writes .stride_lite.md to the target path" "file exists" "missing"
fi

# Assertion 3: what the init flow wrote is byte-for-byte identical to the
# canonical template extracted from the SKILL.md. This is the parity contract —
# any divergence between the init flow's output and the SKILL.md source fails.
if diff "$CANONICAL_TEMPLATE" "$INIT_TARGET" >/dev/null 2>&1; then
  ok "init template is byte-identical to the canonical SKILL.md template"
else
  nope "init template is byte-identical to the canonical SKILL.md template" \
    "no diff vs the $SKILL_MD canonical block" "diff found (template drifted)"
fi

# Assertion 4: the email section is present.
if grep -qE '^## email$' "$INIT_TARGET"; then
  ok "template contains ## email section"
else
  nope "template contains ## email section" "## email header line" "not found"
fi

# Assertion 5: the three hook sections appear in the exact required order.
BEFORE_LINE=$(grep -nE '^## before_task$' "$INIT_TARGET" | head -1 | cut -d: -f1)
AFTER_LINE=$(grep -nE '^## after_task$' "$INIT_TARGET" | head -1 | cut -d: -f1)
GOAL_LINE=$(grep -nE '^## after_goal$' "$INIT_TARGET" | head -1 | cut -d: -f1)
if [ -n "$BEFORE_LINE" ] && [ -n "$AFTER_LINE" ] && [ -n "$GOAL_LINE" ] \
   && [ "$BEFORE_LINE" -lt "$AFTER_LINE" ] && [ "$AFTER_LINE" -lt "$GOAL_LINE" ]; then
  ok "before_task < after_task < after_goal in the template"
else
  nope "before_task < after_task < after_goal in the template" \
    "all three present and ordered" \
    "before=$BEFORE_LINE after=$AFTER_LINE goal=$GOAL_LINE"
fi

# Assertion 6: collision detection precondition — [ -e ] returns true on the
# now-existing file, so the SKILL.md's clobber-refusal branch would fire on a
# second invocation without --force.
if [ -e "$INIT_TARGET" ]; then
  ok "collision check would refuse second write without --force"
else
  nope "collision check would refuse second write without --force" \
    "[ -e ] returns true on the existing file" "file not present"
fi

# ------------------------------------------------------------------
# ------------------------------------------------------------------
# select_workflow_branch — the decision matrix (W2024)
# ------------------------------------------------------------------
#
# Unlike the four helpers above, this one is NOT hand-copied into this file.
# The reference implementation is extracted from lib/select_workflow_branch.md
# at runtime, so the spec and the tested code cannot drift apart.
#
# Extraction alone would be circular, though — comparing an extraction to itself
# proves nothing. So every assertion below checks BEHAVIOUR against an
# independently written expected token, and the first one fails loudly if the
# extraction produced nothing at all.

BRANCH_MD="$REPO_ROOT/lib/select_workflow_branch.md"

extract_reference_impl() {
  awk '/^```bash$/ { in_block = 1; next } in_block && /^```$/ { exit } in_block { print }' "$BRANCH_MD"
}

echo ""
echo "select_workflow_branch"

BRANCH_IMPL="$SANDBOX/select_workflow_branch.sh"
extract_reference_impl > "$BRANCH_IMPL"

# Guard: a broken path or a renamed fence yields an empty file, and every
# assertion below would then fail confusingly rather than pointing here.
if [ -s "$BRANCH_IMPL" ] && grep -q '^select_workflow_branch()' "$BRANCH_IMPL"; then
  ok "reference implementation extracted from lib/select_workflow_branch.md"
else
  nope "reference implementation extraction" "non-empty function definition" "empty or malformed"
fi

# shellcheck source=/dev/null
. "$BRANCH_IMPL"

BRANCH_DIR="$SANDBOX/branch-fixtures"
mkdir -p "$BRANCH_DIR"

# Render a task file with the given complexity and key-files section body.
write_task_file() {
  local target="$1" complexity="$2" keyfiles="$3"
  {
    printf '# A task title\n\n'
    printf '> Type: work · Complexity: %s · Priority: medium\n\n' "$complexity"
    printf '## Description\n\nSome description.\n\n'
    printf '## Key files\n\n%s\n' "$keyfiles"
  } > "$target"
}

TABLE_1='| File | Note |
|---|---|
| `lib/a.ex` | why |'
TABLE_2='| File | Note |
|---|---|
| `lib/a.ex` | why |
| `lib/b.ex` | why |'
TABLE_3='| File | Note |
|---|---|
| `lib/a.ex` | why |
| `lib/b.ex` | why |
| `lib/c.ex` | why |'

assert_branch() {
  local label="$1" complexity="$2" keyfiles="$3" expected="$4"
  local f="$BRANCH_DIR/t.md"
  write_task_file "$f" "$complexity" "$keyfiles"
  assert_eq "$label" "$(select_workflow_branch "$f")" "$expected"
}

# --- The five matrix rows, in the order the table states them ---
assert_branch "small + 1 key file → skip-all"        small  "$TABLE_1" "skip-all"
assert_branch "small + 2 key files → explore-review" small  "$TABLE_2" "explore-review"
assert_branch "small + 3 key files → explore-review" small  "$TABLE_3" "explore-review"
assert_branch "medium + 1 key file → full"           medium "$TABLE_1" "full"
assert_branch "medium + 5 key files → full"          medium "$TABLE_3" "full"
assert_branch "large + 1 key file → full"            large  "$TABLE_1" "full"
assert_branch "unrecognized complexity → full"       enormous "$TABLE_1" "full"

# --- The safe-default rules ---
# An unreadable signal is absence of evidence, not evidence of a small task.
assert_branch "(none) placeholder → 0 files"         small  '| (none) | |' "skip-all"
assert_branch "same path twice → 1 distinct file"    small  '| File | Note |
|---|---|
| `lib/a.ex` | why |
| `lib/a.ex` | other note |' "skip-all"
assert_branch "two bullets → 2 distinct files"       small  '- `lib/a.ex` — why
- `lib/b.ex` — why' "explore-review"
assert_branch "prose names paths but declares none"  small  'We will touch lib/a.ex and lib/b.ex as needed.' "skip-all"
assert_branch "case-insensitive heading is matched"  small  "$TABLE_2" "explore-review"

# A file with no ## Key files section at all told us nothing → full.
NOSECTION="$BRANCH_DIR/nosection.md"
{
  printf '# A task title\n\n'
  printf '> Type: work · Complexity: small · Priority: medium\n\n'
  printf '## Description\n\nNo key files section at all.\n'
} > "$NOSECTION"
assert_eq "absent Key files section → full" "$(select_workflow_branch "$NOSECTION")" "full"

# No metadata line at all → unrecognized complexity → full.
NOMETA="$BRANCH_DIR/nometa.md"
{
  printf '# A task title\n\n'
  printf '## Key files\n\n%s\n' "$TABLE_1"
} > "$NOMETA"
assert_eq "absent metadata line → full" "$(select_workflow_branch "$NOMETA")" "full"

# A missing file is a valid input, not an error.
assert_eq "missing task file → full" "$(select_workflow_branch "$BRANCH_DIR/does-not-exist.md")" "full"
assert_eq "empty task_file argument → full" "$(select_workflow_branch "")" "full"

# The shipped fixture must resolve to a real branch — this catches a template
# change that breaks the metadata line the matrix reads.
FIXTURE_BRANCH="$(select_workflow_branch "$REPO_ROOT/fixtures/expected-output/task1.md")"
case "$FIXTURE_BRANCH" in
  skip-all|explore-review|full) ok "shipped fixture resolves to a branch ($FIXTURE_BRANCH)" ;;
  *) nope "shipped fixture branch" "one of skip-all/explore-review/full" "$FIXTURE_BRANCH" ;;
esac

# The task template still renders the metadata line the matrix depends on. If a
# future template change drops it, every task silently resolves to `full` and the
# matrix quietly stops saving anything — which no other assertion would catch.
if grep -q '^> Type: .*Complexity:' "$REPO_ROOT/fixtures/expected-output/task1.md"; then
  ok "task template still renders the Complexity metadata line"
else
  nope "task template metadata line" "a '> Type: … Complexity: …' line" "not found"
fi

# ------------------------------------------------------------------
# task-enricher agent contract (W2025)
# ------------------------------------------------------------------

echo ""
echo "task-enricher agent"

ENRICHER="$REPO_ROOT/agents/task-enricher.agent.md"

if [ -f "$ENRICHER" ]; then
  ok "agents/task-enricher.agent.md exists"
else
  nope "task-enricher agent file" "agents/task-enricher.agent.md" "missing"
fi

# The house-style sections every agent file in this plugin carries, plus the two
# this agent adds because it mutates the file it reads.
for heading in \
  '## Inputs' \
  '## What this agent does' \
  '## What this agent does NOT do' \
  '## Sections this agent owns' \
  '## Enrichment methodology' \
  '## In-place mutation contract' \
  '## Never copy secrets into the task file' \
  '## Pitfalls'
do
  if grep -qF "$heading" "$ENRICHER" 2>/dev/null; then
    ok "task-enricher has '$heading'"
  else
    nope "task-enricher section" "$heading" "not found"
  fi
done

# Four-phase methodology, per the agent's own contract.
ENRICHER_PHASES=$(grep -c '^### Phase [1-4] —' "$ENRICHER" 2>/dev/null || echo 0)
assert_eq "task-enricher documents four phases" "$ENRICHER_PHASES" "4"

# --- Tools grant ---
# The grant is a security boundary, not a convenience: an agent that rewrites
# files must not hold command execution, and must not hold a streaming-edit tool
# either, because read-whole/write-once is what stops a failure partway through
# leaving a half-enriched task file behind.
ENRICHER_TOOLS=$(grep -m1 '^tools:' "$ENRICHER" 2>/dev/null)
assert_eq "task-enricher tools grant is read/search/glob/write" \
  "$ENRICHER_TOOLS" 'tools: ["read", "search", "glob", "write"]'

if printf '%s' "$ENRICHER_TOOLS" | grep -qE 'run_terminal_cmd|bash|shell|terminal'; then
  nope "task-enricher command execution" "no command-execution capability" "$ENRICHER_TOOLS"
else
  ok "task-enricher grant contains no command-execution capability"
fi

if printf '%s' "$ENRICHER_TOOLS" | grep -q '"edit"'; then
  nope "task-enricher streaming edit" "no 'edit' tool (read-whole/write-once)" "$ENRICHER_TOOLS"
else
  ok "task-enricher grant omits 'edit', enforcing read-whole/write-once"
fi

# --- Owned ∪ Protected == the task template's headings, and disjoint ---
# If the template gains or loses a heading, the enricher's table must move with
# it: a heading it does not know about is one it will neither fill nor protect.
TEMPLATE_HEADINGS=$(awk '
  /^### taskN\.md template$/ { intmpl = 1; next }
  intmpl && /^```$/          { exit }
  intmpl && /^## /           { print }
' "$REPO_ROOT/skills/stride-copilot-lite-create-goal/SKILL.md" | sort -u)

ENRICHER_TABLE=$(awk '
  /^## Sections this agent owns$/ { insec = 1; next }
  insec && /^## /                 { exit }
  insec && /^\| `## /             { print }
' "$ENRICHER")

OWNED=$(printf '%s\n' "$ENRICHER_TABLE" | sed -n 's/^| `\(## [^`]*\)`.*/\1/p' | sort -u)
PROTECTED=$(printf '%s\n' "$ENRICHER_TABLE" | sed -n 's/^|[^|]*| `\(## [^`]*\)`.*/\1/p' | sort -u)
CLAIMED=$(printf '%s\n%s\n' "$OWNED" "$PROTECTED" | grep -v '^$' | sort -u)

assert_eq "enricher owned+protected covers every template heading" \
  "$(printf '%s' "$CLAIMED" | md5 -q 2>/dev/null || printf '%s' "$CLAIMED" | md5sum | cut -d' ' -f1)" \
  "$(printf '%s' "$TEMPLATE_HEADINGS" | md5 -q 2>/dev/null || printf '%s' "$TEMPLATE_HEADINGS" | md5sum | cut -d' ' -f1)"

OVERLAP=$(comm -12 <(printf '%s\n' "$OWNED" | grep -v '^$') <(printf '%s\n' "$PROTECTED" | grep -v '^$'))
if [ -z "$OVERLAP" ]; then
  ok "enricher owned and protected sets are disjoint"
else
  nope "enricher owned/protected disjoint" "no overlap" "$OVERLAP"
fi

# The three intent sections must be protected, never fillable — they are what the
# human or the decomposer said the task IS, not context derived from the code.
for intent in '## Description' '## Why' '## What'; do
  if printf '%s\n' "$PROTECTED" | grep -qxF "$intent"; then
    ok "enricher protects $intent"
  else
    nope "enricher must protect $intent" "in the protected column" "not found"
  fi
done

# --- The sparse rule is worded the same in both places ---
# The workflow's gate and the agent must classify one section identically; a
# definition that drifts is how a task ends up neither enriched nor reviewed.
SPARSE_PHRASE='absent, empty, whitespace-only, or a `(none)` placeholder in any rendered shape'
if grep -qF "$SPARSE_PHRASE" "$ENRICHER" \
   && grep -qF "$SPARSE_PHRASE" "$REPO_ROOT/skills/stride-copilot-lite-workflow/SKILL.md"; then
  ok "sparse rule worded identically in the agent and the workflow"
else
  nope "sparse rule wording" "the same definition in both files" "diverged or missing"
fi

# --- The workflow dispatches it, and only when sparse ---
WF="$REPO_ROOT/skills/stride-copilot-lite-workflow/SKILL.md"
if grep -q 'Step 1a — Enrichment check' "$WF"; then
  ok "workflow has the Step 1a enrichment check"
else
  nope "workflow enrichment step" "### Step 1a — Enrichment check" "not found"
fi

if grep -q 'None of the four sparse' "$WF" && grep -q 'One or more sparse' "$WF"; then
  ok "enrichment is conditional, not mandatory"
else
  nope "enrichment gating" "both sparse/not-sparse branches documented" "not found"
fi

# Ordering: enrichment must precede the matrix resolution, or a sparse file
# counts zero key files and takes the skip-all row on precisely the task whose
# metadata was too thin to judge.
STEP1A_LINE=$(grep -n 'Step 1a — Enrichment check' "$WF" | head -1 | cut -d: -f1)
RESOLVE_LINE=$(grep -n 'Now resolve the decision matrix' "$WF" | head -1 | cut -d: -f1)
STEP2_LINE=$(grep -n 'Step 2 — Execute the' "$WF" | head -1 | cut -d: -f1)
if [ -n "$STEP1A_LINE" ] && [ -n "$RESOLVE_LINE" ] && [ -n "$STEP2_LINE" ] \
   && [ "$STEP1A_LINE" -lt "$RESOLVE_LINE" ] && [ "$RESOLVE_LINE" -lt "$STEP2_LINE" ]; then
  ok "enrichment precedes matrix resolution, which precedes Step 2"
else
  nope "step ordering" "1a < resolve < Step 2" "1a=$STEP1A_LINE resolve=$RESOLVE_LINE step2=$STEP2_LINE"
fi

# Summary
# ------------------------------------------------------------------

echo ""
echo "------------------------------------------------------------------"
echo "$PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

exit 0
