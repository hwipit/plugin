#!/usr/bin/env bash
# Fixture-based tests for hooks/hwip-denied.sh (PermissionDenied) and the
# one-use approval it hands to hooks/hwip-approve.sh (PreToolUse).
#
# The rows that matter most: an approval passes only the exact command, only in
# the asking session, only once, and only fresh — and nothing is asked of a
# user who is at the terminal.
#
# The `hwip` CLI is stubbed, so no push is ever sent.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DENIED="$SCRIPT_DIR/../hooks/hwip-denied.sh"
APPROVE="$SCRIPT_DIR/../hooks/hwip-approve.sh"
PLUGIN_JSON="$SCRIPT_DIR/../.claude-plugin/plugin.json"

[ -f "$DENIED" ] || { echo "hook script not found: $DENIED" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STUB_DIR="$WORK/stub"
STATE="$WORK/state/hwip"
mkdir -p "$STUB_DIR" "$STATE"

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

# Stub `hwip ask`: records its argv and prints the scenario's answer.
stub_ask() {
    cat > "$STUB_DIR/hwip" <<EOF
#!/bin/bash
touch "$WORK/ask-was-called"
printf '%s\n' "\$@" > "$WORK/ask-argv"
printf '%s' '$1'
EOF
    chmod +x "$STUB_DIR/hwip"
}

# Presence probe stub: no control file → unknown presence (not at the terminal).
PROBE_DIR="$WORK/probe"
mkdir -p "$PROBE_DIR"
cat > "$PROBE_DIR/ioreg" <<EOF
#!/bin/bash
[ -f "$WORK/ioreg-idle-ns" ] || exit 1
printf '    | |   "HIDIdleTime" = %s\n' "\$(cat "$WORK/ioreg-idle-ns")"
EOF
chmod +x "$PROBE_DIR/ioreg"
idle_for() { printf '%s' "$(( $1 * 1000000000 ))" > "$WORK/ioreg-idle-ns"; }
no_presence() { rm -f "$WORK/ioreg-idle-ns"; }

run() {
    rm -f "$WORK/ask-was-called"
    printf '%s' "$2" \
      | env -u TMUX -u TMUX_PANE -u SSH_CONNECTION -u HWIP_AWAY_SEC \
        CLAUDE_PROJECT_DIR="$PROJECT_DIR" PATH="$PROBE_DIR:$STUB_DIR:$PATH" \
        XDG_STATE_HOME="$WORK/state" \
        bash "$1" 2>/dev/null
}

denied_input() {  # <command> [session]
    jq -cn --arg c "$1" --arg s "${2-sess-a}" \
        '{hook_event_name:"PermissionDenied", tool_name:"Bash", session_id:$s, permission_mode:"auto",
          tool_input:{command:$c}, reason:"[Destructive or Unwanted Actions]"}'
}
pre_input() {  # <command> [session]
    jq -cn --arg c "$1" --arg s "${2-sess-a}" \
        '{hook_event_name:"PreToolUse", tool_name:"Bash", session_id:$s, permission_mode:"auto", tool_input:{command:$c}}'
}

retried()  { [ "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.retry // empty' 2>/dev/null)" = true ]; }
allowed()  { [ "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" = allow ]; }
asked()    { [ -f "$WORK/ask-was-called" ]; }
silent()   { [ -z "$OUT" ]; }
once_file() { echo "$STATE/approveonce-$HASH-${1:-sess-a}"; }
reset_state() { rm -f "$STATE"/approveonce-* "$STATE"/muted-* "$STATE"/remote-active-*; }

MERGE='gh pr merge 811 --squash'

echo "[registered as a PermissionDenied hook on Bash]"
assert "plugin.json wires hwip-denied.sh" \
    test "$(jq -r '.hooks.PermissionDenied[] | select(.hooks[].command | contains("hwip-denied.sh")) | .matcher' "$PLUGIN_JSON")" = Bash

echo
echo "[away + Run it — records the command once and lets the model retry]"
reset_state; no_presence
stub_ask '{"answered":true,"actionId":"run"}'
OUT=$(run "$DENIED" "$(denied_input "$MERGE")")
assert "asks the phone"                 asked
assert "answers retry"                  retried
assert "records the approval"           test -s "$(once_file)"
assert "the body carries the command"   grep -qxF -- "$MERGE" "$WORK/ask-argv"
assert "the body carries the reason"    grep -qF -- 'Auto mode: [Destructive or Unwanted Actions]' "$WORK/ask-argv"

echo
echo "[the retry of the same command passes once, even with approve off]"
OUT=$(run "$APPROVE" "$(pre_input "$MERGE")")
assert "allows the exact command"       allowed
assert_not "the phone is not asked again" asked
OUT=$(run "$APPROVE" "$(pre_input "$MERGE")")
assert "a second run is not allowed"    silent

echo
echo "[the approval is bound to the command and the session]"
reset_state; no_presence
stub_ask '{"answered":true,"actionId":"run"}'
OUT=$(run "$DENIED" "$(denied_input "$MERGE")")
OUT=$(run "$APPROVE" "$(pre_input "$MERGE --admin")")
assert_not "a changed command is not allowed"   allowed
OUT=$(run "$APPROVE" "$(pre_input "$MERGE" sess-b)")
assert_not "another session is not allowed"     allowed
OUT=$(run "$APPROVE" "$(pre_input "$MERGE")")
assert "the original still passes once"         allowed

echo
echo "[recording sweeps the expired files of other sessions]"
reset_state; no_presence
printf '%s %s\n' "$(( $(date +%s) - 700 ))" deadbeef > "$(once_file sess-old)"
printf '%s %s\n' "$(date +%s)" cafe > "$(once_file sess-live)"
stub_ask '{"answered":true,"actionId":"run"}'
OUT=$(run "$DENIED" "$(denied_input "$MERGE")")
assert_not "an expired file is gone"            test -e "$(once_file sess-old)"
assert "a fresh one stays"                      test -e "$(once_file sess-live)"

echo
echo "[a stale approval is no approval]"
reset_state; no_presence
H=$(printf '%s' "$MERGE" | shasum -a 256 | cut -d' ' -f1)
printf '%s %s\n' "$(( $(date +%s) - 700 ))" "$H" > "$(once_file)"
OUT=$(run "$APPROVE" "$(pre_input "$MERGE")")
assert_not "older than the TTL is not allowed"  allowed
printf '%s %s\n' "$(( $(date +%s) + 3600 ))" "$H" > "$(once_file)"
OUT=$(run "$APPROVE" "$(pre_input "$MERGE")")
assert_not "a stamp from the future is not allowed" allowed

echo
echo "[Keep blocked, silence, or an error — the denial stands]"
for ans in '{"answered":true,"actionId":"keep"}' '{"answered":false,"reason":"timeout"}' '{"error":"boom","reason":"error"}' 'not-json'; do
    reset_state; no_presence
    stub_ask "$ans"
    OUT=$(run "$DENIED" "$(denied_input "$MERGE")")
    assert "no retry for $ans"          silent
    assert_not "no record for $ans"     test -e "$(once_file)"
done

echo
echo "[at the terminal — nothing is asked]"
reset_state; idle_for 5
stub_ask '{"answered":true,"actionId":"run"}'
OUT=$(run "$DENIED" "$(denied_input "$MERGE")")
assert "silent"                         silent
assert_not "never asks"                 asked

echo
echo "[at the terminal but in REMOTE — the phone is the way in]"
reset_state; idle_for 5
date +%s > "$STATE/remote-active-$HASH"
OUT=$(run "$DENIED" "$(denied_input "$MERGE")")
assert "asks"                           asked
assert "answers retry"                  retried

echo
echo "[muted or no session id — inert]"
reset_state; no_presence
touch "$STATE/muted-$HASH"
OUT=$(run "$DENIED" "$(denied_input "$MERGE")")
assert "muted: silent"                  silent
assert_not "muted: never asks"          asked
reset_state
OUT=$(run "$DENIED" "$(denied_input "$MERGE" '')")
assert_not "no session id: never asks"  asked
OUT=$(run "$DENIED" "$(denied_input "$MERGE" 'a/../b')")
assert_not "unsafe session id: never asks" asked
OUT=$(run "$DENIED" 'not-json-at-all{')
assert "malformed input: silent"        silent

echo
echo "[a command that reads like a CLI flag stays one word of the body]"
reset_state; no_presence
EVIL='--base-url=http://127.0.0.1:9/evil; rm -rf build'
cat > "$STUB_DIR/hwip" <<EOF
#!/bin/bash
for a in "\$@"; do case "\$a" in --base-url*) touch "$WORK/flag-leaked" ;; esac; done
printf '%s' '{"answered":true,"actionId":"keep"}'
EOF
chmod +x "$STUB_DIR/hwip"
rm -f "$WORK/flag-leaked"
OUT=$(run "$DENIED" "$(denied_input "$EVIL")")
assert_not "no word of its own starts a --base-url" test -e "$WORK/flag-leaked"

echo
echo "=========================================="
echo "Total: $TOTAL  |  Passed: $PASS  |  Failed: $FAIL"
echo "=========================================="
if [ "$FAIL" -gt 0 ]; then
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
    exit 1
fi
