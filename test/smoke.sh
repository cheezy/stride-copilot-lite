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

# A SECOND, INDEPENDENT derivation of the same template — deliberately a
# different algorithm, because comparing an extraction with itself proves
# nothing (D219: the original parity assertion did exactly that and passed even
# when the SKILL.md path did not resolve, because empty equals empty).
#
# The extractor above is a forward state machine that stops at the FIRST
# four-backtick line. This one bounds the section first — from the
# "## Canonical template" heading to the next "## " heading or EOF — then takes
# everything between the FIRST ````markdown line and the LAST ```` line inside
# that window. Two different readings of one source: if they disagree, one of
# them is wrong, which is the parsing bug the assertion is there to catch.
#
# The realistic failure this guards is TRUNCATION, not emptiness. The template
# body carries nested ```bash blocks, and the outer fence is four backticks
# precisely so they do not close it early. Change that outer fence to three and
# the forward scanner stops at the first nested close, yielding a non-empty but
# truncated template — which an emptiness check alone would wave through.
extract_canonical_template_independent() {
  awk '
    /^## Canonical template$/ { in_section = 1; next }
    # Track the four-backtick fence explicitly rather than exiting at the first
    # one. The template BODY carries its own "## " headings (## email,
    # ## before_task, ...), so a section boundary that ignored the fence would
    # close at the first of them and return nothing.
    in_section && $0 == "````markdown" && fence == 0 { fence = 1; next }
    in_section && fence == 1 && $0 == "````"         { fence = 0; done = 1; next }
    # Only a heading OUTSIDE the fence ends the section.
    in_section && fence == 0 && /^## /               { in_section = 0; next }
    in_section && fence == 1 && done == 0            { print }
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
  # The INDEPENDENT extractor, not the one the expectation uses. This is what
  # makes the parity assertion below a comparison rather than a tautology.
  extract_canonical_template_independent > "$target"
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
# The comparison is only credited when BOTH sides are non-empty and the
# canonical copy is structurally complete. Without this, an extraction that
# returned nothing would satisfy the diff trivially — which is precisely how
# this assertion passed with the SKILL.md path broken (D219).
PARITY_CREDITED=1
[ -s "$CANONICAL_TEMPLATE" ] || PARITY_CREDITED=0
[ -s "$INIT_TARGET" ]        || PARITY_CREDITED=0
# Structural completeness: a truncated extraction is non-empty but wrong, and
# truncation is the realistic failure — the outer fence is four backticks so the
# body's nested ```bash blocks cannot close it early. Require the whole shape.
for _sect in '^# Stride Lite Configuration$' '^## email$' '^## before_task$' '^## after_task$' '^## after_goal$'; do
  grep -qE "$_sect" "$CANONICAL_TEMPLATE" 2>/dev/null || PARITY_CREDITED=0
done
# Over-capture is the mirror of truncation and neither extractor catches it
# alone: remove the CLOSING four-backtick fence and both run to EOF, so they
# still agree and every required section is still present. The template body has
# exactly four "## " headings, so anything beyond that means SKILL.md prose from
# past the template leaked in.
_tmpl_headings=$(grep -cE '^## ' "$CANONICAL_TEMPLATE" 2>/dev/null || echo 0)
[ "$_tmpl_headings" -eq 4 ] || PARITY_CREDITED=0

if [ "$PARITY_CREDITED" -eq 1 ] && diff "$CANONICAL_TEMPLATE" "$INIT_TARGET" >/dev/null 2>&1; then
  ok "init template is byte-identical to the canonical SKILL.md template"
else
  nope "init template is byte-identical to the canonical SKILL.md template" \
    "no diff vs the $SKILL_MD canonical block" "diff found (template drifted)"
fi

# Assertion 4: the email section is present.
# --- Negative control: prove the comparison can actually fail ---
# A parity assertion that has never been observed failing is indistinguishable
# from one that cannot fail. Perturb a copy by one byte and confirm the same
# comparison reports a difference. This is what makes the guarantee credible
# rather than merely green.
PERTURBED="$SANDBOX/perturbed-template.md"
if [ ! -s "$CANONICAL_TEMPLATE" ]; then
  # Nothing to perturb. Report a skip WITH A REASON rather than a failure: the
  # control cannot run, and a failure here would point at itself instead of at
  # the extraction that actually broke.
  ok "parity negative control SKIPPED — the canonical extraction is empty (see the assertion above)"
else
  sed '1s/$/ /' "$CANONICAL_TEMPLATE" > "$PERTURBED"   # one trailing space on line 1
  if ! diff "$CANONICAL_TEMPLATE" "$PERTURBED" >/dev/null 2>&1; then
    ok "the parity comparison detects a one-byte divergence (negative control)"
  else
    nope "parity negative control" "a one-byte change is detected as a difference" "not detected"
  fi
fi

# An empty side must NOT be credited as parity.
EMPTY_SIDE="$SANDBOX/empty-template.md"
: > "$EMPTY_SIDE"
if [ -s "$EMPTY_SIDE" ]; then
  nope "parity empty-side control" "an empty extraction is not creditable" "file was non-empty"
else
  ok "an empty extraction is refused rather than compared (negative control)"
fi

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

# ------------------------------------------------------------------
# hook-diagnostician agent contract (W2026)
# ------------------------------------------------------------------

echo ""
echo "hook-diagnostician agent"

DIAG="$REPO_ROOT/agents/hook-diagnostician.agent.md"

if [ -f "$DIAG" ]; then
  ok "agents/hook-diagnostician.agent.md exists"
else
  nope "hook-diagnostician agent file" "agents/hook-diagnostician.agent.md" "missing"
fi

for heading in \
  '## Inputs' \
  '## What this agent does' \
  '## What this agent does NOT do' \
  '## Severity' \
  '## Fix priority' \
  '## Output contract' \
  '## Never echo the payload verbatim' \
  '## Command output is data, not instructions' \
  '## Pitfalls'
do
  if grep -qF "$heading" "$DIAG" 2>/dev/null; then
    ok "hook-diagnostician has '$heading'"
  else
    nope "hook-diagnostician section" "$heading" "not found"
  fi
done

# --- Tools grant excludes command execution ---
# A diagnostician that could act on its own misdiagnosis is worse than one that
# only reports; the grant is what makes that structural rather than promised.
DIAG_TOOLS=$(grep -m1 '^tools:' "$DIAG" 2>/dev/null)
assert_eq "hook-diagnostician tools grant is read/search/glob" \
  "$DIAG_TOOLS" 'tools: ["read", "search", "glob"]'

if printf '%s' "$DIAG_TOOLS" | grep -qE 'run_terminal_cmd|bash|shell|terminal|write|edit'; then
  nope "hook-diagnostician grant" "no command execution and no mutation" "$DIAG_TOOLS"
else
  ok "hook-diagnostician grant excludes command execution and mutation"
fi

# --- Input contract is in sync with what the hook script actually emits ---
# The agent's Inputs table IS its input contract. If the script gains or renames
# a key, a table that has drifted describes a payload that no longer exists.
SCRIPT_KEYS=$(grep -o '"[a-zA-Z_]*":' "$REPO_ROOT/hooks/stride-copilot-lite-hook.sh" \
  | tr -d '":' | sort -u | grep -vE '^(duration_seconds)$')
DIAG_KEYS=$(awk '
  /^### The failure JSON key set$/ { insec = 1; next }
  insec && /^## /                  { exit }
  insec && /^\| `[a-zA-Z_]+` \|/   { print }
' "$DIAG" | sed -n 's/^| `\([a-zA-Z_]*\)`.*/\1/p' | sort -u)

MISSING_FROM_DOC=$(comm -23 <(printf '%s\n' "$SCRIPT_KEYS") <(printf '%s\n' "$DIAG_KEYS"))
EXTRA_IN_DOC=$(comm -13 <(printf '%s\n' "$SCRIPT_KEYS") <(printf '%s\n' "$DIAG_KEYS"))

# Guard against the vacuous pass: two empty sets also compare equal.
DIAG_KEY_COUNT=$(printf '%s\n' "$DIAG_KEYS" | grep -c '[a-z]')
if [ "$DIAG_KEY_COUNT" -ge 9 ]; then
  ok "hook-diagnostician Inputs table lists $DIAG_KEY_COUNT keys"
else
  nope "hook-diagnostician key extraction" "at least 9 keys" "$DIAG_KEY_COUNT"
fi

if [ -z "$MISSING_FROM_DOC" ] && [ -z "$EXTRA_IN_DOC" ]; then
  ok "Inputs table matches the keys the hook script emits"
else
  nope "input-contract sync with hooks/stride-copilot-lite-hook.sh" \
    "identical key sets" "missing from doc: [$MISSING_FROM_DOC] extra in doc: [$EXTRA_IN_DOC]"
fi

# The blocking-only keys must be present and marked as conditional — a payload
# without them is an advisory failure, not a truncated one.
if grep -qF '`permissionDecision`' "$DIAG" && grep -qF 'blocking only' "$DIAG"; then
  ok "Inputs table marks the blocking-only keys as conditional"
else
  nope "blocking-only key handling" "permissionDecision marked blocking only" "not found"
fi

# --- The workflow dispatches it on both blocking-failure paths ---
# In this port before_task fails at Step 2's marker write and after_task at
# Step 5's, because the hooks fire on the boundary writes rather than on the
# subagent dispatches — so that is where the triage has to live.
WF="$REPO_ROOT/skills/stride-copilot-lite-workflow/SKILL.md"
STEP2_BLOCK=$(awk '/^### Step 2 —/{f=1} /^### Step 3 —/{f=0} f' "$WF")
STEP5_BLOCK=$(awk '/^### Step 5 —/{f=1} /^### Step 6 —/{f=0} f' "$WF")

if printf '%s' "$STEP2_BLOCK" | grep -q 'hook-diagnostician'; then
  ok "Step 2's before_task blocking path dispatches the diagnostician"
else
  nope "Step 2 triage" "a hook-diagnostician dispatch" "not found"
fi

if printf '%s' "$STEP5_BLOCK" | grep -q 'hook-diagnostician'; then
  ok "Step 5's after_task blocking path dispatches the diagnostician"
else
  nope "Step 5 triage" "a hook-diagnostician dispatch" "not found"
fi

# Triage must not soften the stop. Assert the stop on the SAME line as the
# dispatch, not merely somewhere in the step: a step-wide grep for "stop" matches
# unrelated prose and would pass even if the dispatch line said "and continue".
STEP2_DISPATCH=$(printf '%s' "$STEP2_BLOCK" | grep 'hook-diagnostician' | grep -v 'does not apply' | head -1)
STEP5_DISPATCH=$(printf '%s' "$STEP5_BLOCK" | grep 'hook-diagnostician' | grep -v 'does not apply' | head -1)
if printf '%s' "$STEP2_DISPATCH" | grep -q 'stop the workflow' \
   && printf '%s' "$STEP5_DISPATCH" | grep -q 'stop'; then
  ok "both blocking paths still stop on the same line as the triage dispatch"
else
  nope "blocking semantics" "a stop on each dispatch line" "step2='$STEP2_DISPATCH' step5='$STEP5_DISPATCH'"
fi

# Steps 3 and 6 name the agent too, to say why it does NOT apply to a failed
# subagent dispatch — a reader arriving from the upstream docs looks there.
if awk '/^### Step 3 —/{f=1} /^### Step 3a —/{f=0} f' "$WF" | grep -q 'hook-diagnostician' \
   && awk '/^### Step 6 —/{f=1} /^### Step 7 —/{f=0} f' "$WF" | grep -q 'hook-diagnostician'; then
  ok "Steps 3 and 6 reference the agent and scope it away from dispatch failures"
else
  nope "Steps 3/6 reference" "the agent named in both" "not found"
fi

# after_goal triage is available but optional — the run is finishing, not halting.
if grep -q 'may\*\* dispatch `stride-copilot-lite:hook-diagnostician`' "$WF" \
   || grep -q 'You \*\*may\*\* dispatch' "$WF"; then
  ok "after_goal triage is offered without being mandatory"
else
  nope "advisory triage" "an optional mention on the after_goal path" "not found"
fi

# ------------------------------------------------------------------
# Workflow telemetry vocabulary (W2027)
# ------------------------------------------------------------------

echo ""
echo "workflow telemetry"

WF="$REPO_ROOT/skills/stride-copilot-lite-workflow/SKILL.md"

# The seven names the telemetry block documents, read off the vocabulary table
# in Step 8 rather than hardcoded here — a list restated in the test would drift
# from the doc exactly as the doc could drift from the loop.
DOC_STEPS=$(awk '
  /^\| Name \| Step \| Recorded as dispatched when \|$/ { intbl = 1; next }
  intbl && /^\| `/ { print; next }
  intbl && !/^\|/ { exit }
' "$WF" | sed -n 's/^| `\([a-z_]*\)`.*/\1/p')
DOC_COUNT=$(printf '%s\n' "$DOC_STEPS" | grep -c '[a-z]')

assert_eq "telemetry vocabulary documents seven steps" "$DOC_COUNT" "7"

# Every documented name must correspond to a step the loop actually performs.
# The mapping is stated in the same table's Step column, so verify each one
# points at a heading that exists.
DOC_ANCHORS=$(awk '
  /^\| Name \| Step \| Recorded as dispatched when \|$/ { intbl = 1; next }
  intbl && /^\| `/ { print; next }
  intbl && !/^\|/ { exit }
' "$WF" | sed -n 's/^| `[a-z_]*` | \([0-9a-z]*\) |.*/\1/p')

missing_step=""
for anchor in $DOC_ANCHORS; do
  grep -q "^### Step ${anchor} —" "$WF" || missing_step="$missing_step $anchor"
done
if [ -z "$missing_step" ] && [ -n "$DOC_ANCHORS" ]; then
  ok "every telemetry name maps to a step heading that exists"
else
  nope "telemetry step mapping" "each name maps to an existing '### Step N —'" "missing:$missing_step"
fi

# No stride-copilot-only names. after_doing and before_review are the full
# plugin's hook names and do not exist here; recording them would produce
# telemetry comparable to nothing.
if printf '%s\n' "$DOC_STEPS" | grep -qxE 'after_doing|before_review'; then
  nope "telemetry vocabulary" "no stride-copilot-only names" "after_doing/before_review present"
else
  ok "telemetry vocabulary contains no stride-copilot-only names"
fi

# after_goal is goal-level, fires once per goal, and belongs in goal.md's
# summary — not in a task's telemetry.
if printf '%s\n' "$DOC_STEPS" | grep -qx 'after_goal'; then
  nope "telemetry vocabulary" "after_goal excluded (goal-level)" "after_goal present"
else
  ok "telemetry vocabulary excludes the goal-level after_goal"
fi

# --- Every example block lists all seven names ---
# Two in the walkthrough plus the rendering example in Step 8. Each must be
# complete: an example that omits a name teaches the omission the rule forbids.
EXAMPLE_BLOCKS=$(grep -c '{"workflow_steps":\[' "$WF")
assert_eq "three example telemetry blocks are present" "$EXAMPLE_BLOCKS" "3"

incomplete=""
blocknum=0
while IFS= read -r startline; do
  blocknum=$(( blocknum + 1 ))
  body=$(sed -n "${startline},$(( startline + 12 ))p" "$WF")
  for name in $DOC_STEPS; do
    printf '%s' "$body" | grep -q "\"name\":\"$name\"" || incomplete="$incomplete block$blocknum:$name"
  done
done <<< "$(grep -n '{"workflow_steps":\[' "$WF" | cut -d: -f1)"

if [ -z "$incomplete" ]; then
  ok "every example block lists all seven step names"
else
  nope "example telemetry completeness" "all seven names in each block" "$incomplete"
fi

# --- Skip reasons name a condition, not the outcome ---
# A reason that merely restates the skip is the failure mode the rule targets,
# so assert the examples model the right shape rather than the wrong one.
BAD_REASONS=$(grep -o '"reason":"[^"]*"' "$WF" | grep -icE '"reason":"(was )?skipped"|"reason":"(the )?step (was )?skipped"' || true)
assert_eq "no example reason merely restates the skip" "$BAD_REASONS" "0"

if grep -q '"reason":"Decision matrix' "$WF"; then
  ok "an example skip reason names the matrix rule that fired"
else
  nope "skip reason shape" "an example naming the matrix rule" "not found"
fi

# --- Both renderings are required, with the table primary ---
if grep -qF '| Step | Dispatched | Dispatches | Duration | Reason |' "$WF" && grep -q '{"workflow_steps":\[' "$WF"; then
  ok "telemetry renders as both a table and a fenced JSON block"
else
  nope "telemetry rendering" "a table and a JSON block" "one is missing"
fi

# --- Telemetry carries no command output or environment values ---
# The Completion Summary is committed; the contract must say so explicitly.
if grep -q 'No command output, no environment values, no paths outside the project' "$WF"; then
  ok "telemetry contract forbids command output and environment values"
else
  nope "telemetry redaction rule" "an explicit no-output/no-env rule" "not found"
fi

# ------------------------------------------------------------------
# G417 review-convergence rules ported to this port (W2171)
# ------------------------------------------------------------------
# All three rules land as prose here -- this plugin makes no network call,
# so there is no submission step and no validator. These assertions are
# therefore the only mechanical bound the repository has on them. Each one
# needles the CLAUSE ITSELF, never neighbouring text: an assertion that stays
# green when its clause is deleted reads as coverage while providing none.
# Every assertion below was mutation-tested by a harness that deletes each
# needle's clause in turn against a byte-verified copy and requires that named
# assertion to go red. Every g417_has needle in this block currently binds --
# count them from the file rather than trusting a number written here, since a
# stale count is how the previous audit claim went wrong. Four did not bind on
# the first pass, and a later edit left two needles unterminated so they never
# ran at all while the suite stayed green:
# three needled a neighbouring sentence rather than their clause, and one
# matched at two sites so deleting either left it green. Re-run the harness
# after editing any pinned clause -- and note a presence check pins against
# DELETION only; it cannot catch a contradiction added elsewhere in the file.
# grep -qF throughout: these needles carry [], (), * and backticks, which a
# basic regex would silently mis-match.

WF="$REPO_ROOT/skills/stride-copilot-lite-workflow/SKILL.md"
G417_TR="$REPO_ROOT/agents/task-reviewer.agent.md"

g417_has() { # label, file, needle
  if grep -qF "$3" "$2"; then ok "$1"; else nope "$1" "$3" "not found"; fi
}

# --- The ceiling ---------------------------------------------------
g417_has "the review ceiling is two rounds" "$WF" \
  "Two review rounds is the ceiling"
g417_has "the clamp is performed by a step, not just described" "$WF" \
  "Apply the clamp first"
g417_has "the clamp names the min it applies" "$WF" \
  "min(max_review_iterations, 2)"
assert_eq "the ceiling carries its canon anchor exactly once" \
  "$(grep -c 'canon:review-round-cap v1' "$WF")" "1"

# --- The four-way ceiling disposition ------------------------------
g417_has "the ceiling records important and minor findings" "$WF" \
  "are recorded, not fixed"
# The critical carve-out MUST stay bounded. An unbounded "one further round"
# re-applies to its own post-state and hands back the ceiling the clamp exists
# to guarantee -- pin the non-renewal clause, not the "one further round" words.
g417_has "the critical carve-out is spent once and does not renew" "$WF" \
  "The exemption is spent once for the whole task and does not renew"
g417_has "a security finding is never merely recorded at any severity" "$WF" \
  'is never merely recorded, at any severity'
g417_has "the ceiling judges a security finding by subject, not only by its label" "$WF" \
  "Judge by subject rather than by label as well"
g417_has "an outstanding escalation takes the stop path" "$WF" \
  "is never recorded-and-completed"
# The port's standing prohibition must survive this change verbatim.
g417_has "the no-second-cap prohibition survives verbatim" "$WF" \
  "no second loop and no second cap"

# --- The all-cosmetic branch ---------------------------------------
# This branch fires BEFORE the increment, so it never reaches the carve-outs
# above. Its own severity/category re-check is the only thing between a
# mis-flagged entry and a completed task.
g417_has "the all-cosmetic branch fires before the increment" "$WF" \
  "fires **before the increment**"
g417_has "the all-cosmetic branch re-reads severity and category" "$WF" \
  "Re-read \`severity\` and \`category\` here rather than trusting the flag"
g417_has "the all-cosmetic condition names the minor/non-security conjunct" "$WF" \
  'is a `minor` whose `category` is not `"security"`'
# Mutation-tested: needling only "voids the branch outright" left this green
# when the security half of the condition was deleted. Needle both halves.
g417_has "a non-minor entry voids the branch" "$WF" \
  'whose `severity` is anything other than `minor`'
g417_has "a security-category entry voids the branch" "$WF" \
  'or whose `category` is `"security"`, voids the branch'
g417_has "a non-boolean cosmetic is not coerced by the consumer" "$WF" \
  "is not coerced here either"
g417_has "an absent or empty issues array is never all-cosmetic" "$WF" \
  "is **never** an all-cosmetic round"
g417_has "the prose fallback makes the rule inapplicable, not satisfied" "$WF" \
  "**inapplicable, not satisfied**"
# The rendered issue bullet carries no `category`, so on the prose path the
# security carve-out has nothing to select on and recording is withheld.
g417_has "the record disposition is withheld where category cannot be read" "$WF" \
  "record disposition is unavailable on that path too"
# The all-cosmetic branch fires BEFORE the increment, so it never reaches the
# ceiling carve-outs. Both guards it therefore needs of its own are pinned here.
g417_has "the all-cosmetic branch requires no standing escalation" "$WF" \
  "**and no escalation is standing**"
g417_has "a standing escalation voids the all-cosmetic branch" "$WF" \
  "**voids this branch outright**"
g417_has "the all-cosmetic branch judges security by subject, not only by label" "$WF" \
  "Judge by subject as well as by label"
g417_has "reaching Step 8 is stated as a conjunction" "$WF" \
  "Reaching Step 8 is a conjunction"
# The prose fallback must test refusal first and anchor the affirmative --
# a bare substring test for "Approved" also matches "Not Approved".
g417_has "the prose fallback tests for refusal first" "$WF" \
  "Test for refusal first, and match the affirmative only at the start of the line"
g417_has "the prose fallback requires an empty Issues subsection" "$WF" \
  'subsection is empty or renders `- (none)`'
# A non-conforming approval must consume a round like any other refusal;
# a path that loops without incrementing is unbounded by the ceiling.
g417_has "a non-conforming approval increments and is bounded by the ceiling" "$WF" \
  "route into the \`changes_requested\` branch below"
# The absent round-count file is a recorded cannot-apply, not an omission.
g417_has "the absent round-count file is recorded with its structural reason" "$WF" \
  "No durable round-count file, and that cannot apply here"

# --- The approved path and Step 8 ----------------------------------
g417_has "the workflow refuses an approval that carries findings" "$WF" \
  "first confirm the report is conforming"
g417_has "an unrecognized status is never read as an approval" "$WF" \
  "Never read an unrecognized status as an approval"
g417_has "Step 8 has a shape for a completed non-approval" "$WF" \
  "Review ran, did not approve"
g417_has "Step 8 forbids writing approved for a refusal" "$WF" \
  'Never write "approved" for a review that refused'
g417_has "Step 8 records findings left unfixed" "$WF" \
  "Any finding recorded rather than fixed"
# Both recorded-finding write sites are committed markdown; both must carry
# the redaction clause. Pinned per-site: a whole-file count passes silently
# when one site loses the clause and an unrelated one gains it.
g417_has "the Step 7 recorded-findings rule carries the redaction clause" "$WF" \
  "never pasted. **Never copy a credential"
g417_has "the Step 7 recorded-findings rule names the redaction substitute" "$WF" \
  'and identify it by its `file:line`. The task completes'
g417_has "the Step 8 recorded-findings bullet carries the redaction clause" "$WF" \
  "restated in your own words. **Never copy a credential"
g417_has "the Step 8 recorded-findings bullet names the redaction substitute" "$WF" \
  'and identify it by its `file:line`. Omit this bullet only when'

# --- dispatch_count telemetry --------------------------------------
g417_has "dispatch_count is documented in the telemetry writing rules" "$WF" \
  "Record how many times a subagent was dispatched"
assert_eq "dispatch_count carries its canon anchor exactly once" \
  "$(grep -c 'canon:dispatch-count-telemetry v1' "$WF")" "1"
g417_has "dispatch_count counts dispatches, not rounds" "$WF" \
  "It counts dispatches, not rounds"
g417_has "dispatch_count is not review_iteration" "$WF" \
  'is **not** `review_iteration`'
g417_has "dispatch_count is meaningful on only three step names" "$WF" \
  "Only three names can carry it meaningfully"
g417_has "dispatch_count must not be divided into a duration" "$WF" \
  "is not a per-dispatch figure"
g417_has "dispatch_count is not a token count" "$WF" \
  "It is not a token count"

# --- The reviewer contract -----------------------------------------
g417_has "the cosmetic flag is defined in the reviewer contract" "$G417_TR" \
  "a disposition, not a fourth severity"
# The task's own security consideration, made mechanical: without this pin an
# edit could delete the exclusion, keep the flag, and leave the suite green --
# which that consideration calls worse than not porting the class at all.
g417_has "the cosmetic flag excludes the security category at any severity" "$G417_TR" \
  'A `cosmetic: true` beside `category: "security"`, at any severity'
# Mutation-tested: needling only the closing rationale sentence left this green
# when the above-minor refusal clause itself was deleted. Needle the clause.
g417_has "the cosmetic flag is refused above minor" "$G417_TR" \
  'beside any severity other than `minor`'
g417_has "the cosmetic refusal rationale is stated" "$G417_TR" \
  "A security finding is never presentation, and nothing above"
g417_has "the cosmetic flag refuses non-boolean values" "$G417_TR" \
  "are not coerced"
g417_has "the cosmetic flag never removes the finding" "$G417_TR" \
  "The flag never removes the finding"
assert_eq "the cosmetic definition carries its canon anchor exactly once" \
  "$(grep -c 'canon:cosmetic-finding-class v1' "$G417_TR")" "1"
g417_has "the top-level verdict vocabulary is documented locally" "$G417_TR" \
  "It has exactly two values"
g417_has "the top-level status is kept distinct from the section status" "$G417_TR" \
  "None of those six is ever legal at the top level"
g417_has "approved requires an empty issues array, minor included" "$G417_TR" \
  '`issues[]` is **empty** — every severity, `minor` included'
assert_eq "the reviewer cites a schema version that carries cosmetic" \
  "$(grep -oE 'schema_version .[0-9]+\.[0-9]+.' "$G417_TR" | sort -u | grep -c '1\.7')" "1"
assert_eq "no stale 1.1 schema citation survives" \
  "$(grep -c 'schema_version [^0-9]*1\.1' "$G417_TR")" "0"

# --- Negative pins: no key added to a schema this port does not have
# issue_counts has no consumer here and no G417 rule requires it. review_round
# would need a dispatch parameter, which this port's black-box contract forbids.
assert_eq "no issue_counts key was invented in the reviewer contract" \
  "$(grep -c 'issue_counts' "$G417_TR")" "0"
assert_eq "no review_round parameter was invented" \
  "$(cat "$WF" "$G417_TR" | grep -c 'review_round')" "0"

# --- The block's own needles must be well-formed ------------------
# A needle whose quote is never closed swallows the following lines: those
# assertions silently never run, the suite stays green, and the unquoted
# remainder can execute backticks as commands. That happened here once, to
# two of the redaction pins. Checked mechanically rather than by eye.
G417_BAD_QUOTE=0
while IFS= read -r _line; do
  case "$_line" in
    *"g417_has "*) continue ;;
  esac
  # a needle line: leading spaces then a quote; it must close on the same line
  case "$_line" in
    "  '"*) case "$_line" in *"'") ;; *) G417_BAD_QUOTE=$((G417_BAD_QUOTE+1)) ;; esac ;;
    '  "'*) case "$_line" in *'"') ;; *) G417_BAD_QUOTE=$((G417_BAD_QUOTE+1)) ;; esac ;;
  esac
done < <(awk '/# G417 review-convergence rules ported/,/# Gated exploratory-testing and harden/' "$0")
assert_eq "every G417 needle closes its quote on its own line" "$G417_BAD_QUOTE" "0"

# --- Staleness: the old cap number is gone from every live surface --
assert_eq "no stale cap-of-3 survives in the workflow skill" \
  "$(grep -cE 'default 3|cap of 3|3 iterations|3-iteration|cap: 3' "$WF")" "0"
# The literal-3 pin above missed a stale summary that named the old terminus
# without naming the number ("the review-iteration cap"). Pin the phrase too.
assert_eq "no stale unconditional review-iteration-cap exit survives" \
  "$(grep -c 'the review-iteration cap' "$WF")" "0"

# ------------------------------------------------------------------
# Gated exploratory-testing and harden integration (W2028)
# ------------------------------------------------------------------

echo ""
echo "exploratory-testing integration"

for step in '### Step 6a — Manual & exploratory testing (optional, gated)' \
            '### Step 6b — Harden findings into regression checks (optional, gated)'; do
  if grep -qF "$step" "$WF"; then
    ok "workflow has '$(printf '%s' "$step" | sed 's/^### //')'"
  else
    nope "gated sub-step" "$step" "not found"
  fi
done

# Both sub-steps must carry a decision summary, so the skip outcomes are stated
# rather than left to be inferred from prose.
DECISION_TABLES=$(grep -c '^| Condition | Action |' "$WF")
if [ "$DECISION_TABLES" -ge 2 ]; then
  ok "both gated sub-steps carry a decision-summary table ($DECISION_TABLES found)"
else
  nope "decision summaries" "at least 2 Condition/Action tables" "$DECISION_TABLES"
fi

# --- The never-dispatch list names every interactive surface plus the router ---
# This is the regression guard on the whole safety design: the workflow never
# prompts between steps, so an interactive surface would stall the drive until
# the claim expired. Removing one silently re-opens that.
# Scope the check to the never-dispatch TABLE, not the whole file: each of these
# names also appears in surrounding prose, so a file-wide grep would still pass
# after a table row was deleted — which is exactly the regression that matters.
NEVER_TABLE=$(awk '
  /^\*\*Never dispatch these/ { intbl = 1; next }
  intbl && /^\| / { print; next }
  intbl && /^$/ { next }
  intbl && !/^\|/ { exit }
' "$WF")
# Match each surface as a ROW KEY — the table's first cell — not anywhere in the
# table. One row's prose names another surface (the router row cites `pair`), so
# a table-wide grep still passes after a row is deleted. Only the key is proof
# the surface has its own entry.
NEVER_KEYS=$(printf '%s\n' "$NEVER_TABLE" | sed -n 's/^| \(.*\) | .*/\1/p')
missing_surface=""
for surface in explore pair recon nightmare-headline; do
  printf '%s\n' "$NEVER_KEYS" | grep -q "stride-exploratory-testing-$surface" \
    || missing_surface="$missing_surface $surface"
done
if [ -z "$missing_surface" ]; then
  ok "the never-dispatch list names explore, pair, recon and nightmare-headline"
else
  nope "never-dispatch list" "all four interactive surfaces named" "missing:$missing_surface"
fi

# The router skill is the surface most easily reached by mistake — the bare
# plugin name resolves to it, so "dispatch the plugin" lands there.
if printf '%s\n' "$NEVER_KEYS" | grep -qE 'router skill|routing skill' \
   && grep -q 'Dispatch the named agent, never the plugin' "$WF"; then
  ok "the router skill is named as never-dispatchable"
else
  nope "router skill" "the router skill named, with dispatch-the-agent-not-the-plugin" "not found"
fi

# The explorer must be named as the ONLY sanctioned session surface.
if grep -q 'stride-copilot-exploratory-testing:explorer' "$WF"; then
  ok "the explorer agent is named as the sanctioned session surface"
else
  nope "sanctioned surface" "the explorer agent named" "not found"
fi

# --- The affirmative is required, sourced from the user, never inferred ---
if grep -qi 'never infer it and never supply it on the user' "$WF"; then
  ok "the skill forbids inferring the authorized/non-production affirmative"
else
  nope "affirmative rule" "an explicit never-infer statement" "not found"
fi

if grep -q 'collected at activation' "$WF"; then
  ok "the affirmative's collection point is named (activation)"
else
  nope "affirmative collection point" "a named collection point" "not found"
fi

# A localhost URL is the specific wrong inference worth naming.
if grep -q 'localhost' "$WF"; then
  ok "a localhost URL is explicitly rejected as evidence of authorization"
else
  nope "localhost rule" "localhost named as insufficient" "not found"
fi

# --- A session budget is required, in the installed agent's own unit ---
if grep -qi 'probe' "$WF" && grep -qi 'budget' "$WF"; then
  ok "a session budget is required and expressed in the agent's own unit"
else
  nope "session budget" "a budget requirement naming the unit" "not found"
fi

# --- Harden: drafts never reported as passing; gate must run clean first ---
if grep -qi 'never report a drafted check as passing' "$WF" \
   || grep -qi 'Never report a drafted check as passing' "$WF"; then
  ok "harden states a drafted check is never reported as passing"
else
  nope "draft honesty rule" "an explicit never-report-as-passing statement" "not found"
fi

if grep -q 'across the whole suite' "$WF"; then
  ok "a check enters the tree only after the gate runs clean across the whole suite"
else
  nope "gate precondition" "a whole-suite gate run required before the move" "not found"
fi

# --- Every gate falls through to a clean skip ---
if grep -qi 'clean skip' "$WF"; then
  ok "the gates are documented as falling through to a clean skip"
else
  nope "skip semantics" "an explicit clean-skip statement" "not found"
fi

# --- Bash scope covers the new commands ---
BASH_SCOPE=$(awk '/^## Bash scope/{f=1} /^## Edge cases/{f=0} f' "$WF")
for cmd in 'gate command' '`cp` and `rm`'; do
  if printf '%s' "$BASH_SCOPE" | grep -qF "$cmd"; then
    ok "Bash scope covers $cmd"
  else
    nope "Bash scope" "an allow-list entry for $cmd" "not found"
  fi
done

# --- The artifact directory is gitignored ---
if grep -q '^\.exploratory/$' "$REPO_ROOT/.gitignore"; then
  ok ".exploratory/ is gitignored"
else
  nope "artifact directory" ".exploratory/ in .gitignore" "not found"
fi

# --- A blocked session's obstacle is not a finding ---
if grep -q 'Record the obstacle as an obstacle, never as a finding' "$WF" \
   && grep -q 'severity-bearing finding is a category error' "$WF"; then
  ok "a blocked session's obstacle is recorded as an obstacle, not a finding"
else
  nope "blocked-session rule" "obstacle-not-finding stated with its reason" "not found"
fi

# ------------------------------------------------------------------
# Gated deep security-considerations review (W2029)
# ------------------------------------------------------------------

echo ""
echo "security-considerations review"

if grep -q '^### Step 6c — Deep security-considerations review (optional, gated)' "$WF"; then
  ok "workflow has the gated security sub-step"
else
  nope "security sub-step" "### Step 6c — Deep security-considerations review" "not found"
fi

SEC=$(awk '/^### Step 6c —/{f=1} /^### Step 7 —/{f=0} f' "$WF")

# --- The gate is a conjunction, and the placeholder is explicitly excluded ---
if printf '%s' "$SEC" | grep -q 'stride-copilot-security-review'; then
  ok "the gate names the security-review plugin"
else
  nope "security gate" "the plugin named in the gate" "not found"
fi

# Both placeholder forms must be named as non-triggers: the template's own
# `(none)` and the prose `None — ...` entry. Either one alone would leave the
# other firing the specialist on an empty list.
if printf '%s' "$SEC" | grep -q '(none)' && printf '%s' "$SEC" | grep -qE 'None —|None -'; then
  ok "both placeholder forms are excluded from the gate"
else
  nope "placeholder exclusion" "(none) and 'None —' both named as non-triggers" "not found"
fi

if printf '%s' "$SEC" | grep -q '^| Condition | Action |'; then
  ok "the security sub-step carries a decision-summary table"
else
  nope "security decision summary" "a Condition/Action table" "not found"
fi

# --- Verdict shape ---
missing_status=""
for st in mitigated partial unmitigated; do
  printf '%s' "$SEC" | grep -q "$st" || missing_status="$missing_status $st"
done
if [ -z "$missing_status" ]; then
  ok "the three verdict statuses are documented"
else
  nope "verdict statuses" "mitigated, partial and unmitigated" "missing:$missing_status"
fi

if printf '%s' "$SEC" | grep -qi 'evidence'; then
  ok "each verdict carries evidence"
else
  nope "verdict evidence" "an evidence field" "not found"
fi

# --- Fail-closed on anomaly: never downgraded to passed ---
# This step is itself a security control, so inability to confirm mitigation
# must be treated as unaddressed. A downgrade here is the whole failure mode.
if printf '%s' "$SEC" | grep -qi 'fail-closed'; then
  ok "the sub-step states a fail-closed rule"
else
  nope "fail-closed rule" "an explicit fail-closed statement" "not found"
fi

if printf '%s' "$SEC" | grep -qiE 'malformed|empty|unparseable'; then
  ok "an anomalous verdict set is addressed explicitly"
else
  nope "anomaly handling" "malformed/empty/unparseable verdicts addressed" "not found"
fi

# --- Escalation routes through Step 7's existing loop and cap ---
STEP7=$(awk '/^### Step 7 —/{f=1} /^### Step 8 —/{f=0} f' "$WF")
if printf '%s' "$STEP7" | grep -q 'Security-escalation branch'; then
  ok "Step 7 has the security-escalation branch"
else
  nope "Step 7 escalation" "a Security-escalation branch" "not found"
fi

if printf '%s' "$STEP7" | grep -q 'changes_requested' \
   && printf '%s' "$STEP7" | grep -q 'max_review_iterations'; then
  ok "the escalation takes the changes_requested branch under the existing cap"
else
  nope "escalation routing" "changes_requested under max_review_iterations" "not found"
fi

# No second loop and no second cap — the pitfall this guards.
if printf '%s' "$STEP7" | grep -qi 'no second loop and no second cap'; then
  ok "no second review loop or cap is introduced"
else
  nope "single-loop rule" "an explicit no-second-loop statement" "not found"
fi

# --- The reviewer agent documents the verdict array ---
TR="$REPO_ROOT/agents/task-reviewer.agent.md"
if grep -q 'consideration_verdicts' "$TR"; then
  ok "task-reviewer documents the consideration_verdicts array"
else
  nope "verdict array documentation" "consideration_verdicts in task-reviewer" "not found"
fi

# It must say the agent does NOT produce it — the generalist is not the specialist.
if grep -qi 'you never produce it' "$TR"; then
  ok "task-reviewer states it does not produce the verdicts itself"
else
  nope "verdict ownership" "an explicit you-never-produce-it statement" "not found"
fi

# Absent is not empty: an empty array means the specialist ran and found nothing,
# which is treated as unaddressed rather than as a pass.
if grep -q 'Absent is not the same as empty' "$TR"; then
  ok "task-reviewer distinguishes an absent array from an empty one"
else
  nope "absent-vs-empty" "the distinction stated" "not found"
fi

# --- The dispatch frames its inputs as data, not instructions ---
if printf '%s' "$SEC" | grep -qiE 'data to assess|as data, never'; then
  ok "the considerations list and diff are framed as data to assess"
else
  nope "prompt-injection framing" "inputs framed as data, not instructions" "not found"
fi

# ------------------------------------------------------------------
# Anti-rationalization scaffolding (W2030)
# ------------------------------------------------------------------

echo ""
echo "anti-rationalization scaffolding"

SKILL_FILES="stride-copilot-lite-workflow stride-copilot-lite-create-goal stride-copilot-lite-create-task stride-copilot-lite-init"

for name in $SKILL_FILES; do
  f="$REPO_ROOT/skills/$name/SKILL.md"
  if grep -qiE '^## Red flags' "$f"; then
    ok "$name has a Red flags section"
  else
    nope "$name Red flags" "a '## Red flags' section" "not found"
  fi
  if grep -qiE '^## Rationalization table' "$f"; then
    ok "$name has a Rationalization table"
  else
    nope "$name Rationalization table" "a '## Rationalization table' section" "not found"
  fi
  # Three columns: the excuse, the reality that refutes it, the consequence.
  if grep -qF '| "I'"'"'ll just…" | Reality | Consequence if you do |' "$f"; then
    ok "$name table has the three-column header"
  else
    nope "$name table header" "excuse / reality / consequence" "not found"
  fi
done

# The workflow skill additionally carries a compressed index.
if grep -qiE '^## Quick reference card' "$REPO_ROOT/skills/stride-copilot-lite-workflow/SKILL.md"; then
  ok "the workflow skill has a Quick reference card"
else
  nope "Quick reference card" "a '## Quick reference card' section" "not found"
fi

# --- No row may reference a surface this plugin does not have ---
# An irrelevant row trains agents to skim the table, which costs more than the
# row is worth. These are the three stride-copilot surfaces most likely to be
# copied in by accident.
bad_surface=""
for name in $SKILL_FILES; do
  f="$REPO_ROOT/skills/$name/SKILL.md"
  TABLE_ROWS=$(grep -F '| "…' "$f" || true)
  for token in 'POST /api' 'root key' 'review_queue'; do
    printf '%s' "$TABLE_ROWS" | grep -qF "$token" && bad_surface="$bad_surface $name:$token"
  done
done
if [ -z "$bad_surface" ]; then
  ok "no table row references an API endpoint, root key or review queue"
else
  nope "irrelevant table rows" "no stride-copilot-only surfaces" "$bad_surface"
fi

# --- Every row has three cells and a non-trivial consequence ---
THIN_ROWS=0
for name in $SKILL_FILES; do
  f="$REPO_ROOT/skills/$name/SKILL.md"
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    cells=$(printf '%s' "$row" | awk -F'|' '{print NF-2}')
    conseq=$(printf '%s' "$row" | awk -F'|' '{print $4}' | sed 's/^ *//;s/ *$//')
    if [ "$cells" -ne 3 ] || [ "${#conseq}" -lt 25 ]; then
      THIN_ROWS=$(( THIN_ROWS + 1 ))
    fi
  done <<< "$(grep -F '| "…' "$f" || true)"
done
assert_eq "every rationalization row has three cells and a substantive consequence" "$THIN_ROWS" "0"

# Guard the vacuous pass: if the row extraction found nothing, the check above
# passes trivially.
ROW_TOTAL=0
for name in $SKILL_FILES; do
  n=$(grep -cF '| "…' "$REPO_ROOT/skills/$name/SKILL.md" || true)
  ROW_TOTAL=$(( ROW_TOTAL + n ))
done
if [ "$ROW_TOTAL" -ge 20 ]; then
  ok "the four tables carry $ROW_TOTAL rationalization rows in total"
else
  nope "rationalization row count" "at least 20 rows across four tables" "$ROW_TOTAL"
fi

# --- The two security-bearing rows must be present ---
# These restate controls documented elsewhere; a table that quietly loses them
# is how a control gets softened by an edit that reads as tidying.
WFS="$REPO_ROOT/skills/stride-copilot-lite-workflow/SKILL.md"
WF_ROWS=$(grep -F '| "…' "$WFS")
if printf '%s' "$WF_ROWS" | grep -qi 'affirmative' && printf '%s' "$WF_ROWS" | grep -qi 'Security-bearing'; then
  ok "the affirmative row is present and marked security-bearing"
else
  nope "affirmative row" "a security-bearing row on the affirmative" "not found"
fi

if printf '%s' "$WF_ROWS" | grep -qi 'mitigat'; then
  ok "the unconfirmable-verdict row is present"
else
  nope "security verdict row" "a row refusing to mark an unconfirmable verdict mitigated" "not found"
fi

# AGENTS.md must say those rows are not editorial.
if grep -q 'not editorial' "$REPO_ROOT/AGENTS.md"; then
  ok "AGENTS.md records that the safety rows are not editorial"
else
  nope "safety-row rule" "an AGENTS.md note that safety rows are not editorial" "not found"
fi

# --- The card is an index, not a second copy of the loop ---
CARD=$(awk '/^## Quick reference card/{f=1} /^## Red flags/{f=0} f' "$WFS")
CARD_LINES=$(printf '%s\n' "$CARD" | grep -c 'STEP')
if [ "$CARD_LINES" -ge 10 ] && [ "$CARD_LINES" -le 20 ]; then
  ok "the quick reference card indexes the loop in $CARD_LINES lines"
else
  nope "card size" "a compressed index of 10-20 STEP lines" "$CARD_LINES"
fi

# ------------------------------------------------------------------
# Release surface: documented counts vs actual files (W2032)
# ------------------------------------------------------------------
#
# Every count stated in prose is a claim that goes stale the moment a file is
# added. These assertions make that staleness a test failure rather than
# something a reader discovers.

echo ""
echo "release surface"

NUM_AGENTS=$(ls "$REPO_ROOT"/agents/*.agent.md 2>/dev/null | wc -l | tr -d ' ')
NUM_SKILLS=$(ls -d "$REPO_ROOT"/skills/*/ 2>/dev/null | wc -l | tr -d ' ')
NUM_LIB=$(ls "$REPO_ROOT"/lib/*.md 2>/dev/null | wc -l | tr -d ' ')

word_for() {
  case "$1" in
    3) printf 'three' ;; 4) printf 'four' ;; 5) printf 'five' ;;
    6) printf 'six' ;;   7) printf 'seven' ;; *) printf '%s' "$1" ;;
  esac
}

AG_WORD=$(word_for "$NUM_AGENTS")
SK_WORD=$(word_for "$NUM_SKILLS")
LIB_WORD=$(word_for "$NUM_LIB")

if grep -qi "$AG_WORD subagents" "$REPO_ROOT/AGENTS.md"; then
  ok "AGENTS.md's subagent count matches the $NUM_AGENTS agent files"
else
  nope "subagent count" "'$AG_WORD subagents' in AGENTS.md" "stale (actual: $NUM_AGENTS)"
fi

if grep -qi "$SK_WORD skills" "$REPO_ROOT/AGENTS.md"; then
  ok "AGENTS.md's skill count matches the $NUM_SKILLS skill directories"
else
  nope "skill count" "'$SK_WORD skills' in AGENTS.md" "stale (actual: $NUM_SKILLS)"
fi

if grep -qi "$LIB_WORD \`lib/\` helpers" "$REPO_ROOT/AGENTS.md"; then
  ok "AGENTS.md's lib-helper count matches the $NUM_LIB helper files"
else
  nope "lib helper count" "'$LIB_WORD lib/ helpers' in AGENTS.md" "stale (actual: $NUM_LIB)"
fi

# Every agent file must appear in the layout block, or the block is a partial
# map that reads as a complete one.
# Scope to the layout block, not the whole file: agent filenames also appear in
# prose elsewhere in AGENTS.md, so a file-wide grep still passes after a line is
# deleted from the block — which is exactly the drift this guards.
LAYOUT_BLOCK=$(awk '/^  agents\/$/{f=1;next} f && /^  [a-z]/{exit} f' "$REPO_ROOT/AGENTS.md")
missing_layout=""
for f in "$REPO_ROOT"/agents/*.agent.md; do
  base=$(basename "$f")
  printf '%s' "$LAYOUT_BLOCK" | grep -qF "$base" || missing_layout="$missing_layout $base"
done
if [ -z "$missing_layout" ]; then
  ok "every agent file appears in the AGENTS.md layout block"
else
  nope "layout block" "all $NUM_AGENTS agent files listed" "missing:$missing_layout"
fi

# --- plugin.json is the single version source and its pointers resolve ---
if command -v python3 > /dev/null 2>&1; then
  UNRESOLVED=$(cd "$REPO_ROOT" && python3 -c "
import json, os
d = json.load(open('plugin.json'))
print(','.join(p for p in [d['agents'], d['hooks']] + d['skills'] if not os.path.exists(p)))
" 2>/dev/null)
  if [ -z "$UNRESOLVED" ]; then
    ok "plugin.json's agents, skills and hooks pointers all resolve"
  else
    nope "plugin.json pointers" "all pointers resolve" "$UNRESOLVED"
  fi

  PLUGIN_VERSION=$(cd "$REPO_ROOT" && python3 -c "import json;print(json.load(open('plugin.json'))['version'])" 2>/dev/null)
  # The version must appear in plugin.json and the CHANGELOG heading, and
  # nowhere else — a second copy is the thing that goes stale.
  STRAY=$(grep -rln "\"version\": \"$PLUGIN_VERSION\"" "$REPO_ROOT" --include='*.json' 2>/dev/null | grep -v 'plugin.json' | tr '\n' ' ')
  if [ -z "$STRAY" ]; then
    ok "plugin.json is the only file stating the version ($PLUGIN_VERSION)"
  else
    nope "single version source" "only plugin.json" "$STRAY"
  fi

  if grep -q "^## \[$PLUGIN_VERSION\]" "$REPO_ROOT/CHANGELOG.md"; then
    ok "CHANGELOG has a release entry for $PLUGIN_VERSION"
  else
    nope "release entry" "## [$PLUGIN_VERSION] in CHANGELOG.md" "not found"
  fi
else
  ok "plugin.json checks SKIPPED — python3 not available on this host"
fi

# --- SECURITY.md exists and covers the required surfaces ---
SEC_MD="$REPO_ROOT/SECURITY.md"
if [ -f "$SEC_MD" ]; then
  ok "SECURITY.md exists"
else
  nope "SECURITY.md" "the file exists" "missing"
fi

missing_topic=""
for topic in 'execution model' 'NOT a security boundary' 'blast radius' 'Cross-plugin dispatch' 'Reporting a vulnerability'; do
  grep -qiF "$topic" "$SEC_MD" 2>/dev/null || missing_topic="$missing_topic [$topic]"
done
if [ -z "$missing_topic" ]; then
  ok "SECURITY.md covers the execution model, marker status, blast radius, dispatch and reporting"
else
  nope "SECURITY.md coverage" "all five required topics" "missing:$missing_topic"
fi

# --- README carries the sections it previously lacked ---
missing_readme=""
for sect in '## Subagents' '## What gets written where' '## What this plugin does not do'; do
  grep -qF "$sect" "$REPO_ROOT/README.md" || missing_readme="$missing_readme [$sect]"
done
if [ -z "$missing_readme" ]; then
  ok "README has the subagents, output-layout and does-NOT sections"
else
  nope "README sections" "all three present" "missing:$missing_readme"
fi

# --- No network call anywhere but a prohibition ---
NET_HITS=$(grep -rniE '\bcurl \b|\bwget \b|fetch\(' "$REPO_ROOT" \
  --include='*.sh' --include='*.ps1' --include='*.md' --include='*.json' 2>/dev/null \
  | grep -viE 'never|no network|not a network|forbidden|prohibit|contract violation|do not|SECURITY.md' | wc -l | tr -d ' ')
assert_eq "no network call appears except as a prohibition" "$NET_HITS" "0"

# Summary
# ------------------------------------------------------------------

echo ""
echo "------------------------------------------------------------------"
echo "$PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

exit 0
