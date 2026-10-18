#!/usr/bin/env bash
# The Stop hook must finish inside plugin.json's 10 s cap however slowly tmux answers (P30-Stop).
#
# Before the fix every presence probe had its own 2 s bound and the quiet path asked twice, so a tmux that
# answers each call just inside its bound (1.8 s) cost 7.4 s per hwip_is_away and ~15 s through the hook —
# Claude Code kills a hook at the cap and the push is lost with it. The hook now keeps one deadline for the
# probes (HWIP_PROBE_DEADLINE) and one for the whole hook (HWIP_HOOK_BUDGET_SEC), probes once per run,
# and bounds the push CLI by what is left. A probe the deadline cuts reads as unknown → present → no push.
#
# These cases measure wall time, so they sleep for real: a slow stub tmux makes the suite take ~25 s. That
# is the point — a stubbed clock would not catch a bound that is missing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/../hooks/hwip-stop.sh"
FIXTURES="$SCRIPT_DIR/fixtures"
# What a run may take: plugin.json's Stop hook "timeout" is 10 s. The deadline design ends a run
# before ~9 s; the rest is CI jitter.
LIMIT_SEC=9.5

command -v jq >/dev/null      || { echo "jq required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 required" >&2; exit 1; }

WORK=$(mktemp -d)
PROJECT="$WORK/project"
mkdir -p "$PROJECT"
trap 'rm -rf "$WORK"; rm -f "/tmp/hwip-pushmode-$(printf "%s" "$PROJECT" | cksum | cut -d" " -f1)"' EXIT
STUB_DIR="$WORK/stub"
mkdir -p "$STUB_DIR"

# The hwip CLI stub records its argv and optionally sleeps (a hung CLI).
cat > "$STUB_DIR/hwip" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$WORK/last-call"
sleep "\$(cat "$WORK/hwip-sleep" 2>/dev/null || echo 0)"
EOF
# ioreg unreadable: the tmux probes decide, as on a Linux host or over SSH.
cat > "$STUB_DIR/ioreg" <<EOF
#!/bin/bash
exit 1
EOF
# tmux sleeps $WORK/tmux-sleep seconds before every answer.
cat > "$STUB_DIR/tmux" <<EOF
#!/bin/bash
echo "tmux \$*" >> "$WORK/tmux-calls"
sleep "\$(cat "$WORK/tmux-sleep" 2>/dev/null || echo 0)"
case "\$1" in
    list-clients)
        case "\$*" in
            *client_control_mode*) sleep "\$(cat "$WORK/tmux-control-sleep" 2>/dev/null || echo 0)"; echo 0 ;;
            *) cat "$WORK/tmux-clients" ;;
        esac ;;
    show-environment) exit 1 ;;
    display-message)  cat "$WORK/tmux-pane" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$STUB_DIR/hwip" "$STUB_DIR/ioreg" "$STUB_DIR/tmux"

printf 'quiet' > "/tmp/hwip-pushmode-$(printf '%s' "$PROJECT" | cksum | cut -d' ' -f1)"

PASS=0; FAIL=0; TOTAL=0
FAILED_TESTS=()
assert() {
    local desc="$1"; shift
    TOTAL=$((TOTAL + 1))
    if "$@"; then echo "  ✓ $desc"; PASS=$((PASS + 1))
    else echo "  ✗ $desc"; FAIL=$((FAIL + 1)); FAILED_TESTS+=("$desc"); fi
}

now() { python3 -c 'import time; print(time.time())'; }

# run_hook <transcript> — runs the hook as Claude Code would, in tmux, and leaves the wall time in $ELAPSED.
run_hook() {
    rm -f "$WORK/last-call" "$WORK/tmux-calls"
    local t0 t1
    t0=$(now)
    echo "{\"transcript_path\":\"$1\"}" \
      | env -u SSH_CONNECTION -u HWIP_AWAY_SEC TMUX=/tmp/tmux-test/default,1,0 TMUX_PANE=%1 \
        CLAUDE_PROJECT_DIR="$PROJECT" PATH="$STUB_DIR:$PATH" XDG_STATE_HOME="$WORK/state" \
        bash "$HOOK_SCRIPT" >/dev/null 2>&1
    t1=$(now)
    ELAPSED=$(python3 -c "print(round($t1 - $t0, 1))")
}
within_limit() { python3 -c "import sys; sys.exit(0 if $ELAPSED < $LIMIT_SEC else 1)"; }
pushed()       { [ -f "$WORK/last-call" ]; }
silent()       { [ ! -f "$WORK/last-call" ]; }
tmux_calls()   { [ -f "$WORK/tmux-calls" ] && wc -l < "$WORK/tmux-calls" | tr -d ' ' || echo 0; }

NOW=$(date +%s)
T="$FIXTURES/main-2-tools.jsonl"   # 2 tools, no marker: quiet is silent unless the user is away

echo "[a tmux that answers instantly — same verdicts as before]"
echo 0 > "$WORK/tmux-sleep"; echo 0 > "$WORK/hwip-sleep"
printf '%s\n' "$NOW" > "$WORK/tmux-clients"; echo "1 0 1 0" > "$WORK/tmux-pane"
run_hook "$T"
assert "a hidden pane is away → push (${ELAPSED}s)"          pushed
printf '%s\n' "$NOW" > "$WORK/tmux-clients"; echo "1 1 1 0" > "$WORK/tmux-pane"
run_hook "$T"
assert "a visible pane is present → silent (${ELAPSED}s)"    silent
: > "$WORK/tmux-clients"
run_hook "$T"
assert "no client attached is away → push (${ELAPSED}s)"     pushed

echo
echo "[a tmux that answers each call just inside its 2 s bound (1.8 s)]"
echo 1.8 > "$WORK/tmux-sleep"
printf '%s\n' "$NOW" > "$WORK/tmux-clients"; echo "1 0 1 0" > "$WORK/tmux-pane"
run_hook "$T"
assert "the hook ends inside the cap, ${ELAPSED}s (14.8s before the deadline)" within_limit
assert "the deadline cut the probes: unknown reads as present → no push" silent
assert "the presence probes ran once for the hook, not once per gate call" [ "$(tmux_calls)" -le 4 ]

echo
echo "[the same slow tmux, but its first answer settles it: no client attached → away]"
: > "$WORK/tmux-clients"
run_hook "$T"
assert "away from the first probe still pushes"              pushed
assert "…inside the cap, ${ELAPSED}s"                        within_limit

echo
echo "[…and a hung push CLI after that — it gets what is left, not a fresh 8 s]"
echo 30 > "$WORK/hwip-sleep"
run_hook "$T"
assert "the whole hook still ends inside the cap, ${ELAPSED}s (11.9s before the deadline)" within_limit
assert "…and the CLI was still started" pushed
echo 0 > "$WORK/hwip-sleep"

echo
echo "[only the control-mode probe hangs, after the pane read hidden]"
echo 0 > "$WORK/tmux-sleep"; echo 30 > "$WORK/tmux-control-sleep"
printf '%s\n' "$NOW" > "$WORK/tmux-clients"; echo "1 0 1 0" > "$WORK/tmux-pane"
run_hook "$T"
assert "a cut probe is not a verdict: not hidden → no push, ${ELAPSED}s" silent
rm -f "$WORK/tmux-control-sleep"

echo
echo "[a tmux that never answers (sleeps 30 s)]"
echo 30 > "$WORK/tmux-sleep"
printf '%s\n' "$NOW" > "$WORK/tmux-clients"; echo "1 0 1 0" > "$WORK/tmux-pane"
run_hook "$T"
assert "ends inside the cap, ${ELAPSED}s"                    within_limit
assert "no answer is present, never away → no push"          silent

echo
echo "============================================================"
echo "Total: $TOTAL  Pass: $PASS  Fail: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo "Failed:"; printf '  - %s\n' "${FAILED_TESTS[@]}"
    exit 1
fi
echo "============================================================"
