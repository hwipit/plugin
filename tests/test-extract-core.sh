#!/usr/bin/env bash
# Tests for scripts/extract-core.js (the CLI-bound core extractor).
#
# Guards these regressions:
#   - the extracted core must not steer by a mechanism the CLI harnesses never
#     receive. The manifest drops rules 1-2 (Push Signal) and rule 12 (the
#     /hwip-* dial), so surviving prose that says "your Push Signal" or "the
#     user's dial" is an unfollowable instruction on all eight of them
#     (PI-RULES-AUDIT F1, measured against a live pi install).
#   - the numbering the CLI harnesses see must read as a whole list. The manifest
#     drops rules 1-2 and 12, so the raw slice opens at 3 and jumps 11 -> 13,
#     which reads as truncated context (PI-RULES-AUDIT F4). The extractor
#     renumbers at render time; cross-references have to move with it or the
#     core points at rules that no longer carry those numbers.
#   - the disambiguation those sentences carried must survive the rewrite:
#     `<!-- hwip: exit -->` is a marker the CLI core DOES tell agents to emit,
#     and Rule 9 has to keep saying it is not a mode signal.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRACTOR="$SCRIPT_DIR/../scripts/extract-core.js"

[ -f "$EXTRACTOR" ] || { echo "extractor not found: $EXTRACTOR" >&2; exit 1; }
command -v node >/dev/null || { echo "node required" >&2; exit 1; }

PASS=0; FAIL=0; TOTAL=0
FAILED_TESTS=()

assert() {
    local desc="$1"; shift
    TOTAL=$((TOTAL + 1))
    if "$@"; then
        echo "  ✓ $desc"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $desc"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$desc")
    fi
}

assert_not() {
    local desc="$1"; shift
    TOTAL=$((TOTAL + 1))
    if ! "$@"; then
        echo "  ✓ $desc"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $desc"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$desc")
    fi
}

# Both cores in one blob: they are assembled from the same manifest and every
# assertion below has to hold for each, so a single grep target keeps a
# regression from hiding in whichever one the test forgot to check.
CORES=$(node -e '
const { extractCore } = require(process.argv[1]);
const c = extractCore();
process.stdout.write(c.hookDriven + "\n" + c.ruleOnly);
' "$EXTRACTOR") || { echo "extractor failed" >&2; exit 1; }

core_has() { printf '%s' "$CORES" | grep -qF "$1"; }
# Word-boundary variant: "dial" as a bare substring would also fire on a
# legitimate future "dialog", and a false red here reads like a real one.
core_has_re() { printf '%s' "$CORES" | grep -qE "$1"; }

echo "── extracted core: no dangling references to sliced-out mechanisms ──"
assert_not "no Push Signal reference"    core_has "Push Signal"
assert_not "no push-mode dial reference" core_has_re "dial\b"
assert_not "no /hwip-* slash command"    core_has "/hwip-"

echo "── extracted core: the rewrite kept what it was disambiguating ──"
assert "still names the exit marker"     core_has "hwip: exit"
assert "still carries sticky REMOTE"     core_has "Sticky REMOTE mode"
assert "still carries the NORMAL branch" core_has "no hwip_ask is owed"

echo "── extracted core: renumbered 1..N with cross-references in step ──"

# Top-level ordered markers, in document order. Column-0 anchored so an
# indented sub-list inside a rule can never be mistaken for a rule number.
markers() {
    printf '%s\n' "$1" | grep -oE '^[0-9]+\.' | tr -d '.' | tr '\n' ' ' | sed 's/ $//'
}
HOOK_CORE=$(node -e '
const { extractCore } = require(process.argv[1]);
process.stdout.write(extractCore().hookDriven);
' "$EXTRACTOR")

assert "hook-driven core numbers 1..10" \
    test "$(markers "$HOOK_CORE")" = "1 2 3 4 5 6 7 8 9 10"
assert "sticky REMOTE heading follows the new number" core_has "Sticky REMOTE mode (Rule 7)"
assert "singular cross-reference remapped"            core_has "Rule 7 says when to send one"
assert "list cross-reference remapped"                core_has "Rules 1, 2, 8 and 9 are in force"
assert_not "no reference to a pre-renumber number"    core_has_re "Rules? (3|4|9|10|11|12|13)\b"

echo "── renumber: an unmappable reference is a hard error ──"
assert "throws on a reference to a dropped rule" node -e '
const { renumberRules } = require(process.argv[1]);
// Guard the vacuous pass: a missing export would make the call below throw a
// TypeError and look like the hard-fail this test is meant to prove.
if (typeof renumberRules !== "function") process.exit(1);
// Both casings: a mid-sentence "rule 12" is as unfollowable as "Rule 12", and
// only the regex tells them apart.
for (const ref of ["Rule 12", "rule 12"]) {
    try {
        renumberRules(`3. first\n\n4. see ${ref} for the dial\n`);
        process.exit(1);
    } catch (err) {
        if (!/Rule 12/.test(err.message)) process.exit(1);
    }
}
process.exit(0);
' "$EXTRACTOR"

echo
echo "Extract-core: $PASS/$TOTAL passed"
if [ "$FAIL" -gt 0 ]; then
    printf 'Failed: %s\n' "${FAILED_TESTS[@]}"
    exit 1
fi
