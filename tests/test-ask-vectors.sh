#!/usr/bin/env bash
# Vector tests for hooks/gate.sh — the pure AskUserQuestion routing decision.
#
# Unlike fixtures/gate-vectors.json, this file is NOT a cross-repo contract:
# the push gate has a TS twin in @hwip/cli, this decision does not. It lives
# only in the Claude Code plugin, because AskUserQuestion is a Claude Code tool.
# Keep it out of cli/scripts/sync-from-plugin.mjs.
#
# Exit code 0 = all pass; non-zero = some failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE_LIB="$SCRIPT_DIR/../hooks/gate.sh"
VECTORS="$SCRIPT_DIR/fixtures/ask-vectors.json"

[ -f "$GATE_LIB" ] || { echo "gate lib not found: $GATE_LIB" >&2; exit 1; }
[ -f "$VECTORS" ]  || { echo "vectors not found: $VECTORS" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

. "$GATE_LIB"

PASS=0; FAIL=0; TOTAL=0
FAILED_TESTS=()

record() {
    local desc="$1" expected="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if [ "$actual" = "$expected" ]; then
        echo "  ✓ $desc"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $desc (expected '$expected', got '$actual')"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$desc")
    fi
}

echo "[ask-vectors — hwip_ask_decide]"
# Booleans in the JSON contract; the bash function takes 1/0.
while IFS=$'\t' read -r name hookid muted preview qchars ochars replay remote expected; do
    record "$name" "$expected" "$(hwip_ask_decide "$hookid" "$muted" "$preview" "$qchars" "$ochars" "$replay" "$remote")"
done < <(jq -r '.[] |
    [ .name,
      (if .input.hookId     then "1" else "0" end),
      (if .input.muted      then "1" else "0" end),
      (if .input.hasPreview then "1" else "0" end),
      (.input.questionChars | tostring),
      (.input.optionChars   | tostring),
      (if .input.replay     then "1" else "0" end),
      (if .input.remote     then "1" else "0" end),
      .expect
    ] | @tsv' "$VECTORS")

echo
echo "[hwip_ask_decide — a failed measurement must not become a deny]"
# The JSON vectors can only carry numbers, so the non-numeric cases live here.
# They matter more than they look: `[ x -gt 400 ]` errors out, and without an
# explicit guard control falls through to the deny at the end of the function.
record "non-numeric question length allows" "allow" "$(hwip_ask_decide 1 0 0 unmeasurable 30 0 1)"
record "non-numeric option length allows"   "allow" "$(hwip_ask_decide 1 0 0 40 unmeasurable 0 1)"
record "missing arguments allow"            "allow" "$(hwip_ask_decide)"
# Empty args are NOT the unmeasurable case: `${4:-0}` reads them as a real
# zero, which is a genuinely empty question and still worth routing. The hook
# never produces them — ask_measure emits the sentinel above instead.
record "empty args read as a zero-length question" "deny" "$(hwip_ask_decide 1 0 0 '' '' 0 1)"

echo
echo "[replay markers — write, read, and expiry]"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
HWIP_STATE_DIR="$WORK/state"

record "unknown hash reads as not-seen" "1" \
    "$(hwip_ask_replay_seen deadbeef >/dev/null 2>&1; echo $?)"

hwip_ask_replay_mark deadbeef
record "a freshly marked hash reads as seen" "0" \
    "$(hwip_ask_replay_seen deadbeef >/dev/null 2>&1; echo $?)"

record "a different hash is unaffected" "1" \
    "$(hwip_ask_replay_seen cafebabe >/dev/null 2>&1; echo $?)"

# Stamp it past the window instead of sleeping through it.
printf '%s\n' "$(( $(hwip_ask_now) - HWIP_ASK_REPLAY_WINDOW_SEC - 1 ))" > "$HWIP_STATE_DIR/askdeny-deadbeef"
record "an expired marker reads as not-seen" "1" \
    "$(hwip_ask_replay_seen deadbeef >/dev/null 2>&1; echo $?)"

# A corrupted marker must not crash the arithmetic or read as fresh.
printf '%s\n' 'not-a-number' > "$HWIP_STATE_DIR/askdeny-deadbeef"
record "a corrupted marker reads as not-seen" "1" \
    "$(hwip_ask_replay_seen deadbeef >/dev/null 2>&1; echo $?)"

echo
echo "[replay markers — the state dir does not grow without bound]"
# Every denied question drops a file here, so marking has to take out the dead
# ones or a long-lived install accretes one per question forever.
printf '%s\n' "$(( $(hwip_ask_now) - HWIP_ASK_REPLAY_WINDOW_SEC - 5 ))" > "$HWIP_STATE_DIR/askdeny-expired1"
printf '%s\n' "$(( $(hwip_ask_now) - HWIP_ASK_REPLAY_WINDOW_SEC - 5 ))" > "$HWIP_STATE_DIR/askdeny-expired2"
printf '%s\n' 'garbage' > "$HWIP_STATE_DIR/askdeny-corrupt"
printf '%s\n' "$(hwip_ask_now)" > "$HWIP_STATE_DIR/askdeny-fresh"
hwip_ask_replay_mark newkey
record "expired markers are swept"       "0" "$(ls "$HWIP_STATE_DIR" | grep -c 'askdeny-expired')"
record "corrupted markers are swept"     "0" "$(ls "$HWIP_STATE_DIR" | grep -c 'askdeny-corrupt')"
record "a live marker survives the sweep" "1" "$(ls "$HWIP_STATE_DIR" | grep -c 'askdeny-fresh')"
record "the new marker is written"        "1" "$(ls "$HWIP_STATE_DIR" | grep -c 'askdeny-newkey')"
# Unrelated state must not be collateral damage — mute and pushmode live here.
touch "$HWIP_STATE_DIR/muted-12345"
hwip_ask_replay_mark anotherkey
record "the sweep leaves other state alone" "1" "$(ls "$HWIP_STATE_DIR" | grep -c 'muted-12345')"

echo
echo "=========================================="
echo "Total: $TOTAL  |  Passed: $PASS  |  Failed: $FAIL"
echo "=========================================="
if [ "$FAIL" -gt 0 ]; then
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
    exit 1
fi
