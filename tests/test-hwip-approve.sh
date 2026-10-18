#!/usr/bin/env bash
# Fixture-based tests for hooks/hwip-approve.sh.
#
# The gate is opt-in and blocking, so the rows that matter most are the ones
# where it must NOT act: not enabled, muted, or an ordinary command. A gate that
# blocks when it shouldn't freezes someone's terminal for 90 seconds.
#
# The `hwip` CLI is stubbed, so no push is ever sent.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/../hooks/hwip-approve.sh"

[ -f "$HOOK_SCRIPT" ] || { echo "hook script not found: $HOOK_SCRIPT" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STUB_DIR="$WORK/stub"
mkdir -p "$STUB_DIR" "$WORK/state/hwip"

PROJECT_DIR="$WORK/project"
mkdir -p "$PROJECT_DIR"
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

# Stub `hwip ask`: prints whatever the current scenario wants, and records that
# it was called at all.
stub_ask() {
    cat > "$STUB_DIR/hwip" <<EOF
#!/bin/bash
touch "$WORK/ask-was-called"
printf '%s' '$1'
EOF
    chmod +x "$STUB_DIR/hwip"
}

# Presence probe stub (hwip_presence) ahead of the real ioreg, so no run reads
# this machine's idle time. No control file → the probe fails → presence is
# unknown, which keeps the phone approval: every section above the presence one
# runs that way.
PROBE_DIR="$WORK/probe"
mkdir -p "$PROBE_DIR"
cat > "$PROBE_DIR/ioreg" <<EOF
#!/bin/bash
[ -f "$WORK/ioreg-idle-ns" ] || exit 1
printf '    | |   "HIDIdleTime" = %s\n' "\$(cat "$WORK/ioreg-idle-ns")"
EOF
cat > "$PROBE_DIR/tmux" <<EOF
#!/bin/bash
case "\$1" in
    show-environment) f="$WORK/tmux-ssh" ;;
    display-message)  f="$WORK/tmux-pane" ;;
    list-clients)     case "\$*" in *client_control_mode*) f="$WORK/tmux-control" ;; *) f="$WORK/tmux-clients" ;; esac ;;
    *)                exit 1 ;;
esac
[ -f "\$f" ] || exit 1
cat "\$f"
EOF
chmod +x "$PROBE_DIR/ioreg" "$PROBE_DIR/tmux"
idle_for() { printf '%s' "$(( $1 * 1000000000 ))" > "$WORK/ioreg-idle-ns"; }
no_presence() { rm -f "$WORK/ioreg-idle-ns"; }

run_hook() {
    rm -f "$WORK/ask-was-called"
    printf '%s' "$1" \
      | env -u TMUX -u TMUX_PANE -u SSH_CONNECTION -u HWIP_AWAY_SEC \
        CLAUDE_PROJECT_DIR="$PROJECT_DIR" PATH="$PROBE_DIR:$STUB_DIR:$PATH" \
        XDG_STATE_HOME="$WORK/state" \
        bash "$HOOK_SCRIPT" 2>/dev/null
}

decision_is() { [ "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" = "$1" ]; }
reason_has()  { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null | grep -qF -- "$1"; }
asked()       { [ -f "$WORK/ask-was-called" ]; }
silent()      { [ -z "$OUT" ]; }

RM='{"tool_input":{"command":"rm -rf ./dist"}}'

echo "[not enabled — the hook is inert]"
stub_ask '{"answered":true,"actionId":"approve"}'
OUT=$(run_hook "$RM")
assert "emits no decision"          silent
assert_not "never asks"             asked

touch "$WORK/state/hwip/approve-$HASH"

echo
echo "[enabled + dangerous command — waits for the phone]"
stub_ask '{"answered":true,"actionId":"approve"}'
OUT=$(run_hook "$RM")
assert "asks the user"              asked
assert "allows on approval"         decision_is allow

echo
echo "[a command that reads like a flag of the CLI stays one word of the body]"
# The command text is untrusted. Handed over as a separate word, `--base-url=…`
# would be a flag of the CLI itself and the API key would go to that host.
cat > "$STUB_DIR/hwip" <<EOF
#!/bin/bash
touch "$WORK/ask-was-called"
printf '%s\n' "\$@" > "$WORK/ask-argv"
printf '%s' '{"answered":true,"actionId":"approve"}'
EOF
chmod +x "$STUB_DIR/hwip"
EVIL='--base-url=http://127.0.0.1:9/evil; rm -rf build'
OUT=$(run_hook "$(jq -cn --arg c "$EVIL" '{tool_input:{command:$c}}')")
assert "asks"                                 asked
assert "the body is the command, whole"       grep -qxF -- "--body=$EVIL" "$WORK/ask-argv"
assert_not "no word of its own starts a --base-url" grep -q -- '^--base-url' "$WORK/ask-argv"
assert "every flag carries its value in one word" bash -c '! grep -qE "^--(title|body|actions|timeout)$" "$1"' _ "$WORK/ask-argv"

echo
echo "[a NUL in the command shows up in the body instead of vanishing]"
# A shell variable cannot hold a NUL: `$(jq …)` drops it without a word, so the
# approval window would show a string the command never was (`a\0b` as `ab`).
# The body names the byte with U+2400; the gate still matches the text around it.
stub_ask_argv() {
    cat > "$STUB_DIR/hwip" <<EOF
#!/bin/bash
touch "$WORK/ask-was-called"
printf '%s\n' "\$@" > "$WORK/ask-argv"
printf '%s' '{"answered":true,"actionId":"approve"}'
EOF
    chmod +x "$STUB_DIR/hwip"
    rm -f "$WORK/ask-argv"
}
stub_ask_argv
NULCMD=$(printf '%s' '{"tool_input":{"command":"echo a\u0000b; rm -rf ./dist"}}')
OUT=$(run_hook "$NULCMD")
assert "asks"                                 asked
assert "the NUL is shown as U+2400, not dropped" grep -qxF -- "--body=echo a␀b; rm -rf ./dist" "$WORK/ask-argv"

echo
echo "[enabled + ordinary command — runs untouched]"
stub_ask '{"answered":true,"actionId":"approve"}'
OUT=$(run_hook '{"tool_input":{"command":"npm run build"}}')
assert "emits no decision"          silent
assert_not "never asks"             asked

echo
echo "[explicit refusal from the phone]"
stub_ask '{"answered":true,"actionId":"deny"}'
OUT=$(run_hook "$RM")
assert "denies"                     decision_is deny
assert "says the user declined"     reason_has "declined"

echo
echo "[no answer within the deadline — silence is a refusal]"
# The opposite of the AskUserQuestion hook: there `allow` is the safe
# direction, here it is the dangerous one.
stub_ask '{"answered":false}'
OUT=$(run_hook "$RM")
assert "denies"                     decision_is deny
assert "says no approval came back" reason_has "No approval came back"

echo
echo "[cannot reach the server — still a refusal, and says why]"
stub_ask '{"answered":false,"error":"offline"}'
OUT=$(run_hook "$RM")
assert "denies"                     decision_is deny
assert "names the transport error"  reason_has "offline"

echo
echo "[free text instead of a button is not an approval]"
stub_ask '{"answered":true,"value":"maybe later"}'
OUT=$(run_hook "$RM")
assert "denies"                     decision_is deny

echo
echo "[the phone says why there was no answer (hwip ask .reason)]"
stub_ask '{"answered":false,"reason":"cancelled"}'
OUT=$(run_hook "$RM")
assert "cancelled → denies"                 decision_is deny
assert "says the user cancelled"            reason_has "cancelled this approval request"
stub_ask '{"answered":false,"reason":"timeout"}'
OUT=$(run_hook "$RM")
assert "timeout → says no approval came"    reason_has "No approval came back"
stub_ask '{"answered":false,"reason":"error","error":"HTTP 503"}'
OUT=$(run_hook "$RM")
assert "error → names the error"            reason_has "HTTP 503"

echo
echo "[at the terminal — Claude Code's own prompt, not the phone]"
RM_DEFAULT='{"permission_mode":"default","tool_input":{"command":"rm -rf ./dist"}}'
stub_ask '{"answered":true,"actionId":"approve"}'
idle_for 10
OUT=$(run_hook "$RM_DEFAULT")
assert "answers ask"                        decision_is ask
assert_not "never pings the phone"          asked
for mode in acceptEdits plan; do
    OUT=$(run_hook "{\"permission_mode\":\"$mode\",\"tool_input\":{\"command\":\"rm -rf ./dist\"}}")
    assert "$mode → ask"                    decision_is ask
done

echo
echo "[presence never turns the gate into an allow — every doubt keeps the phone]"
stub_ask '{"answered":false,"reason":"timeout"}'
idle_for 10
for mode in bypassPermissions dontAsk auto; do
    OUT=$(run_hook "{\"permission_mode\":\"$mode\",\"tool_input\":{\"command\":\"rm -rf ./dist\"}}")
    assert "$mode → phone, then deny"       decision_is deny
done
OUT=$(run_hook "$RM")
assert "no permission_mode → phone"         asked
idle_for 400
OUT=$(run_hook "$RM_DEFAULT")
assert "away → phone"                       asked
assert "away + no answer → deny"            decision_is deny
no_presence
OUT=$(run_hook "$RM_DEFAULT")
assert "presence unreadable → phone"        asked
idle_for 10
date +%s > "$WORK/state/hwip/remote-active-$HASH"
OUT=$(run_hook "$RM_DEFAULT")
assert "REMOTE → phone even at the desk"    asked
rm -f "$WORK/state/hwip/remote-active-$HASH"
no_presence
# Over SSH the local keyboard says nothing about the remote user, and with no
# tmux there is nothing else to read — unknown, so the phone.
rm -f "$WORK/ask-was-called"
idle_for 10
OUT=$(printf '%s' "$RM_DEFAULT" | env -u TMUX -u HWIP_AWAY_SEC SSH_CONNECTION="10.0.0.1 1 10.0.0.2 22" \
    CLAUDE_PROJECT_DIR="$PROJECT_DIR" PATH="$PROBE_DIR:$STUB_DIR:$PATH" XDG_STATE_HOME="$WORK/state" \
    bash "$HOOK_SCRIPT" 2>/dev/null)
assert "SSH, no tmux → phone (local idle ignored)" asked
no_presence

echo
echo "[at the terminal through tmux — a fresh keystroke counts as present]"
stub_ask '{"answered":true,"actionId":"approve"}'
date +%s > "$WORK/tmux-clients"
OUT=$(printf '%s' "$RM_DEFAULT" | env -u SSH_CONNECTION -u HWIP_AWAY_SEC TMUX="/tmp/fake,1,0" \
    CLAUDE_PROJECT_DIR="$PROJECT_DIR" PATH="$PROBE_DIR:$STUB_DIR:$PATH" XDG_STATE_HOME="$WORK/state" \
    bash "$HOOK_SCRIPT" 2>/dev/null)
assert "recent tmux activity → ask"         decision_is ask
rm -f "$WORK/tmux-clients"

echo
echo "[P24: a session nobody is looking at is not 'present' — the phone, not an unseen prompt]"
# Machine presence (keyboard, tmux client) says the user is at the desk; it says
# nothing about WHICH tmux session they are looking at. A session in a window
# nobody is viewing would get Claude Code's terminal prompt and no push, and wait
# for a person who is typing elsewhere. hwip_pane_visible asks tmux about this
# session's own pane ($TMUX_PANE): `#{session_attached} #{window_active}
# #{pane_active} #{window_zoomed_flag}`. Hidden → the phone. Unreadable → no
# narrowing (the machine verdict stands), so a tmux that will not answer cannot
# turn every at-the-desk approval into a phone round trip.
stub_ask '{"answered":false,"reason":"timeout"}'
date +%s > "$WORK/tmux-clients"
pane_run() {
    rm -f "$WORK/ask-was-called"
    printf '%s' "$RM_DEFAULT" | env -u SSH_CONNECTION -u HWIP_AWAY_SEC TMUX="/tmp/fake,1,0" TMUX_PANE="%7" \
        CLAUDE_PROJECT_DIR="$PROJECT_DIR" PATH="$PROBE_DIR:$STUB_DIR:$PATH" XDG_STATE_HOME="$WORK/state" \
        bash "$HOOK_SCRIPT" 2>/dev/null
}
pane_is() { printf '%s\n' "$1" > "$WORK/tmux-pane"; }
rm -f "$WORK/tmux-pane"
OUT=$(pane_run)
assert "tmux will not say → machine verdict stands (ask)"  decision_is ask
pane_is "1 1 1 0"
OUT=$(pane_run)
assert "attached, current window, active pane → ask"        decision_is ask
assert_not "…and no phone ping"                             asked
pane_is "1 1 0 0"
OUT=$(pane_run)
assert "a split pane that is not the active one is still on screen → ask" decision_is ask
pane_is "0 1 1 0"
OUT=$(pane_run)
assert "session has no client attached → phone"             asked
assert "…and no answer is a deny"                           decision_is deny
pane_is "1 0 1 0"
OUT=$(pane_run)
assert "another window is showing → phone"                  asked
pane_is "1 1 0 1"
OUT=$(pane_run)
assert "a different pane is zoomed over it → phone"         asked
pane_is "1 1 1 1"
OUT=$(pane_run)
assert "this pane zoomed is the one on screen → ask"        decision_is ask
pane_is "garbage"
OUT=$(pane_run)
assert "an answer that is not four numbers → machine verdict stands" decision_is ask
pane_is "1 1 1"
OUT=$(pane_run)
assert "a missing field is unknown, not a shifted read → ask" decision_is ask
pane_is "1 0 1 0"
printf '0\n1\n' > "$WORK/tmux-control"
OUT=$(pane_run)
assert "iTerm2 -CC (a control-mode client): a non-current window may be a tab on screen → ask" decision_is ask
assert_not "…and no phone ping"                             asked
printf '0\n' > "$WORK/tmux-control"
OUT=$(pane_run)
assert "ordinary clients only → still hidden → phone"       asked
rm -f "$WORK/tmux-control"
pane_is "0 1 1 0"
idle_for 10
OUT=$(pane_run)
assert "fresh keyboard idle does not rescue a hidden pane"  asked
no_presence
rm -f "$WORK/tmux-clients" "$WORK/tmux-pane" "$WORK/ask-was-called"

echo
echo "[muted — nobody can be asked, so nothing is blocked]"
touch "$WORK/state/hwip/muted-$HASH"
stub_ask '{"answered":true,"actionId":"approve"}'
OUT=$(run_hook "$RM")
assert "emits no decision"          silent
assert_not "never asks"             asked
rm -f "$WORK/state/hwip/muted-$HASH"

echo
echo "[malformed input cannot block a session]"
stub_ask '{"answered":true,"actionId":"approve"}'
OUT=$(run_hook 'not-json-at-all{')
assert "emits no decision"          silent

echo
echo "=========================================="
echo "Total: $TOTAL  |  Passed: $PASS  |  Failed: $FAIL"
echo "=========================================="
if [ "$FAIL" -gt 0 ]; then
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
    exit 1
fi
