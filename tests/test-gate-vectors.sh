#!/usr/bin/env bash
# Vector tests for hooks/gate.sh — the pure push-gate decision function.
#
# fixtures/gate-vectors.json is the CANONICAL cross-repo contract: the same
# file is vendored into @hwip/cli and run against the TS twin
# (cli/src/gate.ts), so any semantic change here that isn't mirrored there
# fails the other repo's CI. Edit gate.sh, the vectors, and gate.ts together.
#
# Exit code 0 = all pass; non-zero = some failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE_LIB="$SCRIPT_DIR/../hooks/gate.sh"
VECTORS="$SCRIPT_DIR/fixtures/gate-vectors.json"

[ -f "$GATE_LIB" ] || { echo "gate lib not found: $GATE_LIB" >&2; exit 1; }
[ -f "$VECTORS" ]  || { echo "vectors not found: $VECTORS" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

. "$GATE_LIB"

PASS=0; FAIL=0; TOTAL=0
FAILED_TESTS=()

# Single definition of the pass/fail bookkeeping — the vector loop and the
# resolver cases below both report through it, so the two halves of this file
# can never print in different formats.
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

# One compact line per vector: name<TAB>tool<TAB>nonreadonly<TAB>asked<TAB>marker<TAB>mode<TAB>away<TAB>expected
# alreadyAsked is a boolean in the JSON contract; the bash function takes the
# per-turn count, so true → 1, false → 0. away is optional in the JSON (absent
# = false, as on the TS side) and is a 0/1 flag here.
while IFS=$'\t' read -r name tool nonreadonly asked marker mode away expected; do
    record "$name" "$expected" "$(hwip_gate_decide "$tool" "$nonreadonly" "$asked" "$marker" "$mode" "$away")"
done < <(jq -r '.[] |
    [ .name,
      (.input.toolCount | tostring),
      (.input.nonReadonlyCount | tostring),
      (if .input.alreadyAsked then "1" else "0" end),
      .input.marker,
      .input.pushMode,
      (if .input.away then "1" else "0" end),
      (if .expect.push then "push \(.expect.priority)" else "silent" end)
    ] | @tsv' "$VECTORS")

# ── hwip_gate_decide stays symmetric with its TS twin ───────────────────────
#
# The pure function must answer every input the way decidePush does, including
# the ones the vector file never sends. A mode it does not recognise — absent,
# empty, or garbage — is `normal` on both sides, so a vector could be written
# for any of these and both CIs would still agree. The shipped default is NOT
# decided here; it lives one layer down, in hwip_read_pushmode.
echo
echo "[hwip_gate_decide — inputs outside the vector file]"
record "a missing mode argument is normal, like decidePush's fallthrough" \
    "push normal" "$(hwip_gate_decide 2 1 0 none)"
record "an empty mode argument is normal" \
    "push normal" "$(hwip_gate_decide 2 1 0 none "")"
record "an unrecognised mode is normal (and its floors still apply)" \
    silent "$(hwip_gate_decide 1 1 0 none banana)"
record "away is the literal flag 1 — 'true' is present, like decidePush's away !== true" \
    silent "$(hwip_gate_decide 2 1 0 none quiet true)"
record "an empty away argument is present" \
    silent "$(hwip_gate_decide 2 1 0 none quiet "")"

# ── hwip_read_pushmode — where the shipped default actually lives ───────────
#
# The bash twin of cli/src/gate.ts readPushMode, and the reason the vectors
# cannot reach the default: neither side's PURE function decides it. Both
# resolvers answer the same four shapes the same way, and this block is the
# mirror of gate.test.ts's "the default: no dial file" cases.
echo
echo "[hwip_read_pushmode — dial resolution]"
STATE_TMP=$(mktemp -d)
XDG_STATE_HOME="$STATE_TMP" HWIP_STATE_DIR="$STATE_TMP/hwip"
mkdir -p "$HWIP_STATE_DIR"
DIAL="$HWIP_STATE_DIR/pushmode-testhash"

record "no dial file anywhere is the shipped quiet default" \
    quiet "$(hwip_read_pushmode testhash)"
record "an unhashable project is normal, not the default" \
    normal "$(hwip_read_pushmode "")"

printf 'loud\n' > "$DIAL"
record "a readable dial wins over the default" loud "$(hwip_read_pushmode testhash)"
printf ' quiet ' > "$DIAL"
record "surrounding whitespace is stripped" quiet "$(hwip_read_pushmode testhash)"
printf '' > "$DIAL"
record "an empty dial file is normal, not the default" normal "$(hwip_read_pushmode testhash)"
printf '  \n' > "$DIAL"
record "a whitespace-only dial file is normal too" normal "$(hwip_read_pushmode testhash)"
printf 'banana' > "$DIAL"
record "an unrecognised dial value is normal — a garbled dial stays debuggable" \
    normal "$(hwip_read_pushmode testhash)"

rm -rf "$STATE_TMP"

echo
echo "[hwip_wrap_timeout — stock macOS: neither timeout nor gtimeout on PATH]"
# A PATH holding only what the fallback and the probe commands need, so this
# runs the same on Linux CI, where /usr/bin/timeout exists.
WRAP_BIN=$(mktemp -d)
for tool in perl sh sleep; do ln -s "$(command -v "$tool")" "$WRAP_BIN/$tool"; done

# wrap_run <seconds> <command words…> — prints "<rc> <elapsed> <output>"
wrap_run() {
    local seconds="$1"; shift
    (
        PATH="$WRAP_BIN"
        wrapped=$(hwip_wrap_timeout "$1" "$seconds"); shift
        start=$SECONDS
        # shellcheck disable=SC2086 -- a command line, the way the hooks use it
        out=$($wrapped "$@")
        rc=$?
        echo "$rc $((SECONDS - start)) $out"
    )
}

record "perl stands in when neither timeout nor gtimeout exists" \
    perl "$(PATH="$WRAP_BIN"; w=$(hwip_wrap_timeout sh 1); echo "${w%% *}")"

# The grandchild matters: a cold `npx -y @hwip/cli` keeps the real CLI one level
# down, and a survivor holding stdout would keep $(...) waiting past the bound.
# SECONDS counts whole seconds, so a 1s bound reads as 1–2s, more on a busy
# machine. The child sleeps 6s: anything under 5 means the bound ended it.
read -r rc elapsed out <<< "$(wrap_run 1 sh -c 'sleep 6; echo late')"
record "a hung command ends at the bound with timeout's exit code" 124 "$rc"
record "a hung command's children end with it, so \$(...) returns at the bound" \
    yes "$([ "$elapsed" -lt 5 ] && echo yes || echo "no (${elapsed}s)")"
record "a hung command leaves no output" "" "$out"

read -r rc elapsed out <<< "$(wrap_run 5 sh -c 'echo hi; exit 3')"
record "a command that finishes in time keeps its exit code" 3 "$rc"
record "a command that finishes in time keeps its output" hi "$out"

read -r rc elapsed out <<< "$(wrap_run 5 sh -c 'kill -9 $$')"
record "a command killed by a signal is not reported as success" 137 "$rc"

rm -rf "$WRAP_BIN"

echo
echo "[hwip_bound_prefix — P30: which timeout counts]"
# Windows Git Bash exposes a native timeout.exe (a wait, not a command runner)
# under the same name. The stub answers neither --version nor --help, the way
# the native one answers neither.
WIN_BIN=$(mktemp -d)
printf '#!/bin/sh\nexit 1\n' > "$WIN_BIN/timeout"
chmod +x "$WIN_BIN/timeout"
for tool in perl sh sleep; do ln -s "$(command -v "$tool")" "$WIN_BIN/$tool"; done
record "a timeout answering neither --version nor --help (Windows native) is skipped for perl" \
    perl "$(PATH="$WIN_BIN"; w=$(hwip_wrap_timeout sh 1); echo "${w%% *}")"
rm -rf "$WIN_BIN"

EMPTY_BIN=$(mktemp -d)
ln -s "$(command -v sh)" "$EMPTY_BIN/sh"
record "no timeout, gtimeout or perl leaves the command bare (P30 deferred: the plugin.json cap is the only bound)" \
    sh "$(PATH="$EMPTY_BIN"; hwip_wrap_timeout sh 1)"
record "…and leaves the bound array empty" \
    0 "$(PATH="$EMPTY_BIN"; hwip_bound_prefix 1 >/dev/null; echo "${#HWIP_BOUND[@]}")"
rm -rf "$EMPTY_BIN"

if command -v timeout >/dev/null 2>&1 && timeout --version >/dev/null 2>&1; then
    GNU_BIN=$(mktemp -d)
    ln -s "$(command -v timeout)" "$GNU_BIN/timeout"
    for tool in perl sh sleep; do ln -s "$(command -v "$tool")" "$GNU_BIN/$tool"; done
    record "a GNU timeout is still used first" \
        timeout "$(PATH="$GNU_BIN"; w=$(hwip_wrap_timeout sh 1); echo "${w%% *}")"
    rm -rf "$GNU_BIN"
else
    echo "  – skipped: no GNU timeout on PATH"
fi

echo
echo "=========================================="
echo "Total: $TOTAL  |  Passed: $PASS  |  Failed: $FAIL"
echo "=========================================="
if [ "$FAIL" -gt 0 ]; then
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
    exit 1
fi
[ "$TOTAL" -gt 0 ] || { echo "no vectors ran" >&2; exit 1; }
