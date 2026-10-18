#!/usr/bin/env bash
# How the hooks start the CLI, and how they read a timestamp out of a state file.
#
#   P27 — a `hwip` whose path holds a space, a CLI that cannot be started, and the
#         reason the approval hook gives for each of them.
#   P28 — a state file whose number bash would read as octal, is too long to be a
#         time, or lies in the future. A hook must not let the arithmetic error
#         skip the check it sits in, and must not trust such a file forever.
#
# The `hwip` CLI is stubbed, so no push is ever sent.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$SCRIPT_DIR/../hooks"
FIXTURES="$SCRIPT_DIR/fixtures"

command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/state/hwip" "$WORK/home" "$WORK/project"
PROJECT_DIR="$WORK/project"
HASH=$(printf '%s' "$PROJECT_DIR" | cksum | cut -d' ' -f1)

PASS=0; FAIL=0; TOTAL=0
FAILED_TESTS=()
assert() {
    local desc="$1"; shift
    TOTAL=$((TOTAL + 1))
    if "$@"; then echo "  ✓ $desc"; PASS=$((PASS + 1));
    else echo "  ✗ $desc"; FAIL=$((FAIL + 1)); FAILED_TESTS+=("$desc"); fi
}
assert_not() {
    local desc="$1"; shift
    TOTAL=$((TOTAL + 1))
    if ! "$@"; then echo "  ✓ $desc"; PASS=$((PASS + 1));
    else echo "  ✗ $desc"; FAIL=$((FAIL + 1)); FAILED_TESTS+=("$desc"); fi
}

# A CLI stub that records its argv (one word per line) and answers like `hwip ask`.
write_cli() { # <dir> <stdout> [exit code]
    mkdir -p "$1"
    cat > "$1/hwip" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$WORK/argv"
printf '%s' '$2'
exit ${3:-0}
EOF
    chmod +x "$1/hwip"
}
called() { [ -s "$WORK/argv" ]; }

# A PATH with the tools the hooks need and no `hwip` and no `npx`. The wrapper
# tools stay when the machine has them, so the bounded path is the one under test.
MIN="$WORK/min"; mkdir -p "$MIN"
for tool in shasum sha256sum bash cat cksum cut date dirname grep head jq ls mkdir rm sed sleep tail tr awk timeout gtimeout perl python3 git env sh; do
    found=$(command -v "$tool" 2>/dev/null) && [ -x "$found" ] && ln -sf "$found" "$MIN/$tool"
done

# run <hook> <path> [stdin] — the hook with a clean environment and its own state dir.
run() {
    printf '%s' "${3:-}" \
      | env -u TMUX -u TMUX_PANE -u SSH_CONNECTION -u HWIP_AWAY_SEC -u HWIP_HOOK_DEBUG \
        CLAUDE_PROJECT_DIR="$PROJECT_DIR" PATH="$2" HOME="$WORK/home" \
        XDG_STATE_HOME="$WORK/state" HWIP_HOOK_ID=hook-1 \
        bash "$HOOKS/$1" 2>/dev/null
}
decision() { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null; }
reason()   { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null; }
reason_has() { reason | grep -qF -- "$1"; }
decision_is() { [ "$(decision)" = "$1" ]; }

RM='{"tool_input":{"command":"rm -rf ./dist"}}'
touch "$WORK/state/hwip/approve-$HASH"
echo normal > "$WORK/state/hwip/pushmode-$HASH"

# ── P27 ──────────────────────────────────────────────────────────────────────

SPACED="$WORK/sp ace dir"
write_cli "$SPACED" '{"answered":true,"actionId":"approve"}'

echo "[P27: a hwip whose path holds a space — the approval hook]"
rm -f "$WORK/argv"
OUT=$(run hwip-approve.sh "$SPACED:$MIN" "$RM")
assert "the CLI is called"                    called
assert "the answer is read: allow"            decision_is allow
assert "ask is the first word it gets"        bash -c '[ "$(head -1 "$1")" = ask ]' _ "$WORK/argv"

echo
echo "[P27: a hwip whose path holds a space — the stop hook]"
rm -f "$WORK/argv"
run hwip-stop.sh "$SPACED:$MIN" "{\"transcript_path\":\"$FIXTURES/main-2-tools.jsonl\"}" >/dev/null
assert "the push is sent"                     called
assert "the body is one word"                 grep -q '^--body=' "$WORK/argv"

echo
echo "[P27: a hwip whose path holds a space — the ask hook]"
rm -f "$WORK/argv"
run hwip-ask.sh "$SPACED:$MIN" '{"tool_input":{"question":"Proceed?"}}' >/dev/null
assert "the push is sent"                     called
assert "it carries the question"              grep -qF 'Proceed?' "$WORK/argv"

echo
echo "[P27: no hwip, so npx -y @hwip/cli — still three words, not one]"
NPXDIR="$WORK/npxdir"; mkdir -p "$NPXDIR"
cat > "$NPXDIR/npx" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$WORK/argv"
printf '%s' '{"answered":true,"actionId":"approve"}'
EOF
chmod +x "$NPXDIR/npx"
rm -f "$WORK/argv"
OUT=$(run hwip-approve.sh "$NPXDIR:$MIN" "$RM")
assert "npx is called"                        called
assert "the first two words are -y @hwip/cli" bash -c '[ "$(sed -n 1p "$1")" = -y ] && [ "$(sed -n 2p "$1")" = @hwip/cli ] && [ "$(sed -n 3p "$1")" = ask ]' _ "$WORK/argv"
assert "allows on approval"                   decision_is allow

echo
echo "[P27: the CLI cannot be started — the reason says so, not '75s']"
rm -f "$WORK/argv"
OUT=$(run hwip-approve.sh "$MIN" "$RM")
assert "denies (silence is a refusal)"        decision_is deny
assert "says the CLI could not be started"    reason_has "Could not start the hwip CLI"
assert "does not claim a 75s wait"            bash -c '! printf "%s" "$1" | grep -q "75s"' _ "$(reason)"

write_cli "$WORK/exit124" '' 124
OUT=$(run hwip-approve.sh "$WORK/exit124:$MIN" "$RM")
assert "exit 124 (the outer cap fired) → denies"       decision_is deny
assert "…and says the CLI did not finish"              reason_has "did not finish"

write_cli "$WORK/exit1" 'hwip 0.0.1 placeholder' 1
OUT=$(run hwip-approve.sh "$WORK/exit1:$MIN" "$RM")
assert "exit 1 with no answer → denies"                decision_is deny
assert "…and names the exit code"                      reason_has "exited with code 1"

write_cli "$WORK/ok-nothing" '{"answered":false}' 0
OUT=$(run hwip-approve.sh "$WORK/ok-nothing:$MIN" "$RM")
assert "exit 0, answered:false → the deadline message" reason_has "No approval came back"

# ── P28 ──────────────────────────────────────────────────────────────────────

NOW=$(date +%s)
GATE="$HOOKS/gate.sh"
# remote_active <file content> — rc and stderr of hwip_remote_active, the file left behind.
remote_active() {
    printf '%s\n' "$1" > "$WORK/state/hwip/remote-active-$HASH"
    RESULT=$(env XDG_STATE_HOME="$WORK/state" bash -c ". '$GATE'; hwip_remote_active $HASH && echo active || echo inactive; echo reached-the-end" 2>&1)
}
file_left() { [ -f "$WORK/state/hwip/remote-active-$HASH" ]; }

echo
echo "[P28: hwip_remote_active reads a time that bash would take for octal]"
remote_active "0$NOW"
assert "a leading 0 is a number, not an arithmetic error" bash -c '[ "$1" = "active
reached-the-end" ]' _ "$RESULT"
remote_active "00000000000000000008"
assert "more digits than a time → inactive, no error"     bash -c '[ "$1" = "inactive
reached-the-end" ]' _ "$RESULT"
assert "…and the file is dropped"                         bash -c '! [ -f "$1" ]' _ "$WORK/state/hwip/remote-active-$HASH"
remote_active "99999999999999999999999"
assert "23 digits → inactive, no error"                   bash -c '[ "$1" = "inactive
reached-the-end" ]' _ "$RESULT"
remote_active "$((NOW - 20000))"
assert "older than the TTL → inactive"                    bash -c '[ "$1" = "inactive
reached-the-end" ]' _ "$RESULT"

echo
echo "[P28: a time in the future does not keep REMOTE alive for good]"
remote_active "$((NOW + 999999))"
assert "it still counts as live now"                      bash -c '[ "$1" = "active
reached-the-end" ]' _ "$RESULT"
stored=$(head -1 "$WORK/state/hwip/remote-active-$HASH")
assert "…and the stored time is pulled back to now"       bash -c '[ "$1" -le "$(( $2 + 5 ))" ]' _ "$stored" "$NOW"
remote_active "999999999999"
stored=$(head -1 "$WORK/state/hwip/remote-active-$HASH")
assert "a 12-digit time far ahead is pulled back too"     bash -c '[ "$1" -le "$(( $2 + 5 ))" ]' _ "$stored" "$NOW"
remote_active "$((NOW + 999999))"
rm -f "$WORK/state/hwip/remote-active-$HASH"

echo
echo "[P28: the same values as cli gate.ts isRemoteActive (cli#44)]"
file_gone() { ! [ -f "$WORK/state/hwip/remote-active-$HASH" ]; }
verdict_is() { [ "$RESULT" = "$1
reached-the-end" ]; }
remote_active "000$NOW"
assert "13 digits that read as now (000 and the time) → swept"  verdict_is inactive
assert "…and the file is dropped"                               file_gone
remote_active "9999999999999"
assert "13 digits → swept"                                      verdict_is inactive
printf '  %s\t\n' "$NOW" > "$WORK/state/hwip/remote-active-$HASH"
RESULT=$(env XDG_STATE_HOME="$WORK/state" bash -c ". '$GATE'; hwip_remote_active $HASH && echo active || echo inactive; echo reached-the-end" 2>&1)
assert "spaces and a tab around the time → live"                verdict_is active
printf '%s\nnot a time\n' "$NOW" > "$WORK/state/hwip/remote-active-$HASH"
RESULT=$(env XDG_STATE_HOME="$WORK/state" bash -c ". '$GATE'; hwip_remote_active $HASH && echo active || echo inactive; echo reached-the-end" 2>&1)
assert "only the first line is read → live"                     verdict_is active
printf '%s\r\n' "$NOW" > "$WORK/state/hwip/remote-active-$HASH"
RESULT=$(env XDG_STATE_HOME="$WORK/state" bash -c ". '$GATE'; hwip_remote_active $HASH && echo active || echo inactive; echo reached-the-end" 2>&1)
assert "a carriage return in the time → swept"                  verdict_is inactive
assert "…and the file is dropped"                               file_gone
printf '\357\273\277%s\n' "$NOW" > "$WORK/state/hwip/remote-active-$HASH"
RESULT=$(env XDG_STATE_HOME="$WORK/state" bash -c ". '$GATE'; hwip_remote_active $HASH && echo active || echo inactive; echo reached-the-end" 2>&1)
assert "a byte order mark in front → swept"                     verdict_is inactive
printf '%s\n' "$((NOW - 100))" > "$WORK/state/hwip/remote-active-$HASH"
RESULT=$(env XDG_STATE_HOME="$WORK/state" bash -c ". '$GATE'; hwip_remote_active $HASH && echo active || echo inactive; echo reached-the-end" 2>&1)
assert "a past time is left as it is"                           bash -c '[ "$(head -1 "$1")" = "$2" ]' _ "$WORK/state/hwip/remote-active-$HASH" "$((NOW - 100))"

# A future time that cannot be rewritten as now would stay "ahead" for good: it is not REMOTE.
# (root writes through a read-only mode, so there is nothing to test as root.)
if [ "$(id -u)" != 0 ]; then
    printf '%s\n' "$((NOW + 999999))" > "$WORK/state/hwip/remote-active-$HASH"
    chmod 444 "$WORK/state/hwip/remote-active-$HASH"; chmod 555 "$WORK/state/hwip"
    RESULT=$(env XDG_STATE_HOME="$WORK/state" bash -c ". '$GATE'; hwip_remote_active $HASH && echo active || echo inactive; hwip_remote_active $HASH && echo active || echo inactive; echo reached-the-end" 2>&1)
    chmod 755 "$WORK/state/hwip"
    assert "a future time that cannot be rewritten → not REMOTE, every time, silently" bash -c '[ "$1" = "inactive
inactive
reached-the-end" ]' _ "$RESULT"
    rm -f "$WORK/state/hwip/remote-active-$HASH"
    printf '%s\n' "$((NOW + 999999))" > "$WORK/state/hwip/remote-active-$HASH"
    chmod 444 "$WORK/state/hwip/remote-active-$HASH"
    remote_unwritable_file_only=$(env XDG_STATE_HOME="$WORK/state" bash -c ". '$GATE'; hwip_remote_active $HASH && echo active || echo inactive" 2>&1)
    assert "…a read-only file in a folder that can be written is dropped" bash -c '[ "$1" = inactive ] && ! [ -f "$2" ]' _ "$remote_unwritable_file_only" "$WORK/state/hwip/remote-active-$HASH"
    chmod 644 "$WORK/state/hwip/remote-active-$HASH" 2>/dev/null; rm -f "$WORK/state/hwip/remote-active-$HASH"
fi

echo
echo "[P28: the approval hook, user at the terminal, reads the REMOTE file without an arithmetic error]"
PRESENT_DIR="$WORK/present"; mkdir -p "$PRESENT_DIR"
cat > "$PRESENT_DIR/ioreg" <<STUB
#!/bin/bash
printf '    | |   "HIDIdleTime" = 0\n'
STUB
chmod +x "$PRESENT_DIR/ioreg"
write_cli "$WORK/appr" '{"answered":true,"actionId":"approve"}'
DEFAULT_MODE='{"tool_input":{"command":"rm -rf ./dist"},"permission_mode":"default"}'
approve_with_remote() { # <remote-active content, or - for none>
    rm -f "$WORK/argv" "$WORK/state/hwip/remote-active-$HASH"
    [ "$1" = - ] || printf '%s\n' "$1" > "$WORK/state/hwip/remote-active-$HASH"
    OUT=$(printf '%s' "$DEFAULT_MODE" \
      | env -u TMUX -u TMUX_PANE -u SSH_CONNECTION -u HWIP_AWAY_SEC \
        CLAUDE_PROJECT_DIR="$PROJECT_DIR" PATH="$WORK/appr:$PRESENT_DIR:$MIN" HOME="$WORK/home" \
        XDG_STATE_HOME="$WORK/state" HWIP_HOOK_ID=hook-1 \
        bash "$HOOKS/hwip-approve.sh" 2>"$WORK/stderr")
}
no_arith_error() { ! grep -q "value too great for base" "$WORK/stderr"; }
approve_with_remote -
assert "control: no REMOTE file, user present → Claude Code's own prompt" decision_is ask
assert_not "…and the phone is not asked"                      called
approve_with_remote "0$NOW"
assert "a leading 0 reads as live REMOTE → the phone is asked" called
assert "…and the answer decides"                              decision_is allow
assert "…and no arithmetic error"                             no_arith_error
approve_with_remote "$((NOW + 999999))"
assert "a time ahead of the clock is live REMOTE → phone"     called
approve_with_remote "99999999999999999999999"
assert "a 23-digit file is not REMOTE → the terminal prompt"  decision_is ask
assert "…and no arithmetic error"                             no_arith_error
rm -f "$WORK/state/hwip/remote-active-$HASH"

echo
echo "[P28: the denied-question stamp and the phone-origin marker read the same way]"
printf '0%s\n' "$NOW" > "$WORK/state/hwip/askdeny-abc"
RESULT=$(env XDG_STATE_HOME="$WORK/state" bash -c ". '$GATE'; hwip_ask_replay_seen abc && echo seen || echo fresh; echo reached-the-end" 2>&1)
assert "askdeny with a leading 0: read, no error"         bash -c '[ "$1" = "seen
reached-the-end" ]' _ "$RESULT"
printf '%s\n' "$((NOW + 99999))" > "$WORK/state/hwip/askdeny-abc"
RESULT=$(env XDG_STATE_HOME="$WORK/state" bash -c ". '$GATE'; hwip_ask_replay_seen abc && echo seen || echo fresh" 2>&1)
assert "a stamp from the future is not a recent denial"   bash -c '[ "$1" = fresh ]' _ "$RESULT"
printf '%s\n' "$((NOW + 99999))" > "$WORK/state/hwip/askdeny-abc"
env XDG_STATE_HOME="$WORK/state" bash -c ". '$GATE'; hwip_ask_replay_mark other" >/dev/null 2>&1
assert "…and the sweep drops it"                          bash -c '! [ -f "$1" ]' _ "$WORK/state/hwip/askdeny-abc"
printf '0%s\n' "$NOW" > "$WORK/state/hwip/askdeny-abc"
RESULT=$(env XDG_STATE_HOME="$WORK/state" bash -c ". '$GATE'; hwip_ask_replay_mark other; echo reached-the-end" 2>&1)
assert "the sweep over such a stamp does not die"         bash -c '[ "$1" = "reached-the-end" ]' _ "$RESULT"
rm -f "$WORK/state/hwip/askdeny-abc" "$WORK/state/hwip/askdeny-other"

echo
echo "[P28: the idle time ioreg reports is read the same way]"
IOREG_DIR="$WORK/ioreg"; mkdir -p "$IOREG_DIR"
cat > "$IOREG_DIR/ioreg" <<STUB
#!/bin/bash
printf '    | |   "HIDIdleTime" = %s\n' "\$(cat "$WORK/idle")"
STUB
chmod +x "$IOREG_DIR/ioreg"
presence_with_idle() {
    printf '%s' "$1" > "$WORK/idle"
    env -u TMUX -u SSH_CONNECTION HWIP_AWAY_SEC=5 PATH="$IOREG_DIR:$MIN" bash -c ". '$GATE'; hwip_presence; echo reached-the-end" 2>&1 | tr '\n' ' '
}
assert "8 s idle written with leading zeros → away"       bash -c '[ "$1" = "away reached-the-end " ]' _ "$(presence_with_idle 0000008000000000)"
assert "1 s idle written with leading zeros → present"    bash -c '[ "$1" = "present reached-the-end " ]' _ "$(presence_with_idle 0000001900000000)"
assert "a number longer than a nanosecond count → unknown" bash -c '[ "$1" = "unknown reached-the-end " ]' _ "$(presence_with_idle 9999999999999999999)"

PROMPT='from the phone'
DIGEST=$(printf '%s' "$PROMPT" | { shasum -a 256 2>/dev/null || sha256sum; } | cut -d' ' -f1)
printf '0%s %s\n' "$NOW" "$DIGEST" > "$WORK/state/hwip/remote-$HASH"
OUT=$(run hwip-remote.sh "$MIN" "$(jq -cn --arg p "$PROMPT" '{prompt:$p,session_id:"s1"}')")
assert "a marker with a leading 0 still enters REMOTE"    bash -c 'printf "%s" "$1" | jq -e ".hookSpecificOutput.additionalContext | test(\"phone\")" >/dev/null' _ "$OUT"
rm -f "$WORK/state/hwip/remote-$HASH" "$WORK/state/hwip/remote-active-$HASH"

echo
echo "=========================================="
echo "Total: $TOTAL  |  Passed: $PASS  |  Failed: $FAIL"
echo "=========================================="
if [ "$FAIL" -gt 0 ]; then
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
    exit 1
fi
