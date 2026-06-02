#!/bin/bash
# test-spec-linter.sh — Regression test for spec-linter.js.
#
# Usage:
#   bash scripts/tests/test-spec-linter.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LINTER_JS="$SCRIPT_DIR/lib/spec-linter.js"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ ! -f "$LINTER_JS" ]; then
  echo "FATAL: cannot find $LINTER_JS" >&2
  exit 2
fi

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Copy markdownlint config to temp root
cp "$ROOT_DIR/.markdownlintrc" "$TMP_ROOT/"
# Link node_modules so npx finds markdownlint
ln -s "$ROOT_DIR/node_modules" "$TMP_ROOT/node_modules"

pass=0
fail=0

render_spec() {
  local id="${1:-0001}"
  local slug="${2:-test-spec}"
  local status="${3:-draft}"
  local complexity="${4:-standard}"
  local extra_fm="${5:-}"
  local headings="${6:-}"

  if [ -z "$headings" ]; then
    headings=$(printf "## Intent\n\n## Requirements\n\n## Scenarios\n\n## Out of scope\n\n## Open questions")
  fi

  cat <<EOF
---
id: "$id"
slug: "$slug"
status: "$status"
complexity: "$complexity"
version: 1.0.0
related-issue: 123
$extra_fm
---

# Title

$headings
EOF
}

run_case() {
  local name="$1"
  local files="$2"
  local expected_exit="$3"

  local actual_exit=0
  local output
  # We run from TMP_ROOT so markdownlint finds .markdownlintrc
  output=$( ( cd "$TMP_ROOT" && node "$LINTER_JS" $files 2>&1 ) ) || actual_exit=$?

  if [ "$actual_exit" -eq "$expected_exit" ]; then
    echo "PASS  $name (exit $actual_exit)"
    pass=$((pass + 1))
  else
    echo "FAIL  $name (expected exit $expected_exit, got $actual_exit)"
    echo "Output:"
    echo "$output"
    fail=$((fail + 1))
  fi
}

# -------------------------------------------------------------------------
# Case 1 — Happy path: valid spec → exit 0
# -------------------------------------------------------------------------
spec1="0001-happy-path.md"
render_spec "0001" "happy-path" "draft" > "$TMP_ROOT/$spec1"
run_case "Case 1 — valid spec passes" "$spec1" 0

# -------------------------------------------------------------------------
# Case 2 — Missing heading → exit 1
# -------------------------------------------------------------------------
spec2="0002-missing-heading.md"
render_spec "0002" "missing-heading" "draft" "standard" "" "$(printf "## Intent\n\n## Requirements\n\n## Out of scope\n\n## Open questions")" > "$TMP_ROOT/$spec2"
run_case "Case 2 — missing heading fails" "$spec2" 1

# -------------------------------------------------------------------------
# Case 3 — ID mismatch → exit 1
# -------------------------------------------------------------------------
spec3="0003-id-mismatch.md"
render_spec "9999" "id-mismatch" "draft" > "$TMP_ROOT/$spec3"
run_case "Case 3 — ID mismatch fails" "$spec3" 1

# -------------------------------------------------------------------------
# Case 4 — Delta spec wrong order → exit 1
# -------------------------------------------------------------------------
spec4="0004-delta-order.delta-01.md"
render_spec "0004" "delta-order" "draft" "standard" "" "$(printf "## MODIFIED\n\n## ADDED\n\n## REMOVED")" > "$TMP_ROOT/$spec4"
run_case "Case 4 — delta spec wrong heading order fails" "$spec4" 1

# -------------------------------------------------------------------------
# Case 5 — max-iterations out of bounds → exit 1
# -------------------------------------------------------------------------
spec5="0005-max-iterations.md"
render_spec "0005" "max-iterations" "draft" "standard" "max-iterations: 25" > "$TMP_ROOT/$spec5"
run_case "Case 5 — max-iterations > 20 fails" "$spec5" 1

# -------------------------------------------------------------------------
# Case 6 — superseded-by missing → exit 1
# -------------------------------------------------------------------------
spec6="0006-superseded-missing.md"
render_spec "0006" "superseded-missing" "superseded" > "$TMP_ROOT/$spec6"
run_case "Case 6 — status superseded without superseded-by fails" "$spec6" 1

# -------------------------------------------------------------------------
# Case 7 — interaction-mode missing (status approved) → exit 1
# -------------------------------------------------------------------------
spec7="0007-interaction-missing.md"
render_spec "0007" "interaction-missing" "approved" > "$TMP_ROOT/$spec7"
run_case "Case 7 — status approved without interaction-mode fails" "$spec7" 1

# -------------------------------------------------------------------------
# Case 8 — markdownlint integration → exit 1
# -------------------------------------------------------------------------
# MD001: Header levels should only increase by one level at a time
spec8="0008-markdownlint-fail.md"
cat <<EOF > "$TMP_ROOT/$spec8"
---
id: "0008"
slug: "markdownlint-fail"
status: "draft"
complexity: "standard"
version: 1.0.0
related-issue: 123
---

# Title
### Wrong Level Heading
## Intent
## Requirements
## Scenarios
## Out of scope
## Open questions
EOF
run_case "Case 8 — markdownlint failure causes exit 1" "$spec8" 1

# -------------------------------------------------------------------------
# Case 9 — interaction-mode present (status approved) → exit 0
# -------------------------------------------------------------------------
spec9="0009-interaction-present.md"
render_spec "0009" "interaction-present" "approved" "standard" "interaction-mode: INTERMEDIATE" > "$TMP_ROOT/$spec9"
run_case "Case 9 — status approved with interaction-mode passes" "$spec9" 0

# -------------------------------------------------------------------------
# Case 10 — interaction-mode missing (status draft) → exit 0
# -------------------------------------------------------------------------
spec10="0010-interaction-missing-draft.md"
render_spec "0010" "interaction-missing-draft" "draft" > "$TMP_ROOT/$spec10"
run_case "Case 10 — status draft without interaction-mode passes" "$spec10" 0

# -------------------------------------------------------------------------
# Case 11 — Delta spec correct order → exit 0
# -------------------------------------------------------------------------
spec11="0011-delta-ok.delta-01.md"
render_spec "0011" "delta-ok" "draft" "standard" "" "$(printf "## ADDED\n\n## MODIFIED\n\n## REMOVED")" > "$TMP_ROOT/$spec11"
run_case "Case 11 — delta spec correct heading order passes" "$spec11" 0

# -------------------------------------------------------------------------
# Case 12 — superseded-by prohibited (status approved) → exit 1
# -------------------------------------------------------------------------
spec12="0012-superseded-prohibited.md"
render_spec "0012" "superseded-prohibited" "approved" "standard" "interaction-mode: INTERMEDIATE\nsuperseded-by: 0001" > "$TMP_ROOT/$spec12"
run_case "Case 12 — status approved with superseded-by fails" "$spec12" 1

# -------------------------------------------------------------------------
# Case 13 — related-issue not integer → exit 1
# -------------------------------------------------------------------------
spec13="0013-related-issue-string.md"
render_spec "0013" "related-issue-string" "draft" "standard" "related-issue: \"#123\"" > "$TMP_ROOT/$spec13"
run_case "Case 13 — non-integer related-issue fails" "$spec13" 1

# -------------------------------------------------------------------------
# Case 14 — extra headings allowed after mandatory ones → exit 0
# -------------------------------------------------------------------------
spec14="0014-extra-headings.md"
render_spec "0014" "extra-headings" "draft" "standard" "" "$(printf "## Intent\n\n## Requirements\n\n## Scenarios\n\n## Out of scope\n\n## Open questions\n\n## Extra Section\n\n### Sub Section")" > "$TMP_ROOT/$spec14"
run_case "Case 14 — extra headings allowed after mandatory ones passes" "$spec14" 0

# -------------------------------------------------------------------------
# Case 15 — headings inside code blocks are ignored → exit 0
# -------------------------------------------------------------------------
spec15="0015-headings-in-code.md"
render_spec "0015" "headings-in-code" "draft" "standard" "" "$(printf "## Intent\n\n## Requirements\n\n## Scenarios\n\n## Out of scope\n\n## Open questions\n\n\`\`\`markdown\n## This heading should be ignored\n\`\`\`")" > "$TMP_ROOT/$spec15"
run_case "Case 15 — headings inside code blocks are ignored passes" "$spec15" 0

# -------------------------------------------------------------------------
# Case 16 — mandatory heading missing but present in code block → exit 1
# -------------------------------------------------------------------------
spec16="0016-mandatory-heading-in-code.md"
render_spec "0016" "mandatory-heading-in-code" "draft" "standard" "" "$(printf "## Intent\n\n## Requirements\n\n## Scenarios\n\n## Out of scope\n\n\`\`\`markdown\n## Open questions\n\`\`\`")" > "$TMP_ROOT/$spec16"
run_case "Case 16 — mandatory heading missing but present in code block fails" "$spec16" 1

# -------------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------------
echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
