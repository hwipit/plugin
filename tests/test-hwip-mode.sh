#!/usr/bin/env bash
# Tests for scripts/hwip-mode.sh — the one script behind /hwip-mode.
#
# Guards these regressions:
#   - each word writes the state file the hooks read (gate.sh hwip_state_present),
#     keyed by the same project hash, so a dial set here is the dial the Stop
#     hook sees
#   - --global only for push dials; a bad argument writes nothing
#   - status names where the dial came from (project / global / built-in default)
#   - after a change the script re-emits the SessionStart rules for the NEW
#     state: those rules never re-run mid-session, so without this a
#     quiet→normal switch leaves the model without the skip/push markers
#   - a failing rules refresh never undoes the change the user asked for

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE_SCRIPT="$SCRIPT_DIR/../scripts/hwip-mode.sh"

[ -f "$MODE_SCRIPT" ] || { echo "script not found: $MODE_SCRIPT" >&2; exit 1; }
command -v node >/dev/null || { echo "node required" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home"

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

STATE="$WORK/state"
S="$STATE/hwip"
# A space in the path: the project dir reaches the script as one stdin line
# and must hash exactly as the hooks hash CLAUDE_PROJECT_DIR.
PROJECT="$WORK/my project"
mkdir -p "$S" "$PROJECT"
HASH=$(printf '%s' "$PROJECT" | cksum | cut -d' ' -f1)
state_reset() { rm -f "$S"/* "/tmp/hwip-muted-$HASH" "/tmp/hwip-pushmode-$HASH" "$WORK/pwned" "$WORK/pwned2" "$WORK/pwned3"; }

# run_mode_raw <dir-line> <args-line> — feeds stdin the way the skill's
# heredoc does; stdout+stderr into OUT, exit code into RC. HWIP_HOOK_ID makes
# the re-emitted rules the two-way NORMAL branch.
run_mode_raw() {
    OUT=$(printf '%s\n%s\n' "$1" "$2" | env -i HOME="$WORK/home" PATH="$PATH" \
        XDG_STATE_HOME="$STATE" HWIP_API_KEY=test-key HWIP_HOOK_ID=test-hook \
        bash "$MODE_SCRIPT" 2>&1)
    RC=$?
}
run_mode() { run_mode_raw "$PROJECT" "$*"; }

out_has()   { printf '%s' "$OUT" | grep -qF -- "$1"; }
out_lacks() { ! out_has "$1"; }
rc_is()     { [ "$RC" -eq "$1" ]; }
file_is()   { [ -f "$1" ] && [ "$(cat "$1")" = "$2" ]; }
exists()    { [ -e "$1" ]; }
absent()    { [ ! -e "$1" ]; }
state_empty() { [ -z "$(ls -A "$S")" ]; }

# ── tests ──────────────────────────────────────────────────────────────────

echo "[status — no dial anywhere]"
state_reset
run_mode
assert "exits 0"                               rc_is 0
assert "reports active"                        out_has "NOTIFICATIONS: active"
assert "quiet is the built-in default"         out_has "PUSH MODE: quiet (built-in default"
assert "prints the usage line"                 out_has "/hwip-mode [quiet|normal|loud|mute|unmute] [--global]"
assert "writes nothing"                        state_empty
assert "does not re-emit rules"                out_lacks "Hwip rules"
assert "says the settings are shared per directory" out_has "SCOPE: mute, push dial, approval gate and auto mode are shared with every other session in this directory"

echo "[project dials]"
for m in quiet normal loud; do
    state_reset
    run_mode "$m"
    assert "$m: exits 0"                       rc_is 0
    assert "$m: writes pushmode-<hash>"        file_is "$S/pushmode-$HASH" "$m"
    assert "$m: status says this project"      out_has "PUSH MODE: $m (this project)"
done

echo "[--global dial]"
state_reset
run_mode --global loud
assert "flag order does not matter"            rc_is 0
assert "writes pushmode-default"               file_is "$S/pushmode-default" loud
assert "leaves the project dial alone"         absent "$S/pushmode-$HASH"
assert "status says global default"            out_has "PUSH MODE: loud (global default)"
run_mode normal
assert "project dial wins over global"         out_has "PUSH MODE: normal (this project)"

echo "[mute / unmute]"
state_reset
run_mode mute
assert "mute touches muted-<hash>"             exists "$S/muted-$HASH"
assert "status says muted"                     out_has "NOTIFICATIONS: muted"
assert "muted status keeps the scope line"     out_has "SCOPE: mute, push dial, approval gate and auto mode are shared with every other session in this directory"
assert "re-emitted rules are the muted note"   out_has "muted for this project"
assert "muted note points at the new command"  out_has "/hwip-mode unmute"
touch "/tmp/hwip-muted-$HASH"
run_mode unmute
assert "unmute removes muted-<hash>"           absent "$S/muted-$HASH"
assert "unmute removes the legacy /tmp file"   absent "/tmp/hwip-muted-$HASH"
assert "status says active"                    out_has "NOTIFICATIONS: active"

echo "[legacy /tmp state counts in status]"
state_reset
touch "/tmp/hwip-muted-$HASH"
printf 'loud' > "/tmp/hwip-pushmode-$HASH"
run_mode
assert "status reports it muted"               out_has "NOTIFICATIONS: muted"
assert "legacy dial reads as this project"     out_has "PUSH MODE: loud (this project)"
state_reset

echo "[auto state]"
state_reset
printf '%s 90\n' "$(( $(date +%s) + 3600 ))" > "$S/auto-$HASH"
run_mode
assert "reports the remaining budget"          out_has "m remaining of 90m"
# No spaces in the payload: `read` splits on them, which would defuse it.
printf 'a[$(date>%s)] 90\n' "$WORK/pwned" > "$S/auto-$HASH"
run_mode
assert "a non-numeric auto file is reported"   out_has "AUTO MODE: unreadable state file"
assert "and never evaluated"                   absent "$WORK/pwned"
assert "status still finishes"                 out_has "/hwip-mode [quiet|normal|loud|mute|unmute] [--global]"
state_reset

echo "[shell text in the arguments is data, not code]"
state_reset
run_mode_raw "$PROJECT" "quiet; touch $WORK/pwned2 \$(touch $WORK/pwned3)"
assert "rejected as a bad argument"            rc_is 2
assert "nothing ran"                           absent "$WORK/pwned2"
assert "nothing ran in \$( )"                   absent "$WORK/pwned3"
assert "no state written"                      state_empty

echo "[rules refresh after a change]"
state_reset
run_mode normal
assert "normal: rules carry the skip marker"   out_has "hwip: skip"
assert "normal: tells the model to replace"    out_has "replace the Hwip rules from session start"
run_mode quiet
assert "quiet: rules say the dial is quiet"    out_has "push dial is **quiet**"
assert "quiet: no skip marker"                 out_lacks "hwip: skip"

echo "[a change that leaves the rules as they were prints one line]"
state_reset
run_mode normal
run_mode loud
assert "normal → loud: no rules block"         out_lacks "replace the Hwip rules from session start"
assert "says the rules still apply"            out_has "Session rules unchanged"
assert "the dial still changed"                file_is "$S/pushmode-$HASH" loud

echo "[approval gate — /hwip-mode approve on|off]"
state_reset
run_mode
assert "off by default"                        out_has "APPROVAL GATE: off"
run_mode approve on
assert "on: exits 0"                           rc_is 0
assert "on: writes approve-<hash>"             exists "$S/approve-$HASH"
assert "on: status says on"                    out_has "APPROVAL GATE: on"
assert "on: no rules refresh (not in the rules)" out_lacks "Hwip rules"
run_mode mute
assert "muted: says the gate is inactive"      out_has "APPROVAL GATE: on, but inactive while muted"
run_mode approve off
assert "off: removes the file"                 absent "$S/approve-$HASH"
assert "off: status says off"                  out_has "APPROVAL GATE: off"
assert "a change keeps the scope line"         out_has "SCOPE: mute, push dial, approval gate and auto mode are shared with every other session in this directory"
state_reset

echo "[auto mode — an expired deadline is cleared, not shown as negative time]"
state_reset
printf '%s 30\n' "$(( $(date +%s) - 600 ))" > "$S/auto-$HASH"
run_mode
assert "says off and cleared"                  out_has "AUTO MODE: off (an expired 30m session"
assert "no negative minutes"                   out_lacks "m remaining"
assert "file removed"                          absent "$S/auto-$HASH"
printf '%s 30\n' "$(( $(date +%s) + 630 ))" > "$S/auto-$HASH"
run_mode
assert "a live deadline still shows"           out_has "AUTO MODE: 10m remaining of 30m"
state_reset

echo "[bad arguments write nothing]"
for args in "mute --global" "quiet loud" "shout" "unmute --global" "--global" "approve" "approve maybe" "approve on --global" "approve on off" "quiet approve on"; do
    state_reset
    # shellcheck disable=SC2086 # word-splitting the case is the point
    run_mode $args
    assert "'$args': exit 2"                   rc_is 2
    assert "'$args': usage shown"              out_has "/hwip-mode [quiet|normal|loud|mute|unmute] [--global]"
    assert "'$args': no state written"         state_empty
done

echo "[empty or unsubstituted project dir falls back to pwd]"
state_reset
OUT=$(cd "$PROJECT" && printf '\nloud\n' | env -i HOME="$WORK/home" PATH="$PATH" \
    XDG_STATE_HOME="$STATE" bash "$MODE_SCRIPT" 2>&1); RC=$?
# env -i drops PWD, so bash takes getcwd — the physical path (/private/var on macOS).
PWD_HASH=$(cd "$PROJECT" && pwd -P | tr -d '\n' | cksum | cut -d' ' -f1)
assert "exits 0"                               rc_is 0
assert "hashes the working directory"          file_is "$S/pushmode-$PWD_HASH" loud
state_reset
OUT=$(cd "$PROJECT" && printf '%s\nnormal\n' '${CLAUDE_PROJECT_DIR}' | env -i HOME="$WORK/home" \
    PATH="$PATH" XDG_STATE_HOME="$STATE" bash "$MODE_SCRIPT" 2>&1); RC=$?
assert "a literal placeholder hashes pwd too"  file_is "$S/pushmode-$PWD_HASH" normal

echo "[rules refresh failure keeps the change]"
state_reset
NODELESS="$WORK/bin"; mkdir -p "$NODELESS"
for tool in bash cksum cut tr cat mkdir rm touch printf date ls dirname; do
    p=$(command -v "$tool") && ln -sf "$p" "$NODELESS/$tool"
done
OUT=$(printf '%s\nloud\n' "$PROJECT" | env -i HOME="$WORK/home" PATH="$NODELESS" \
    XDG_STATE_HOME="$STATE" "$NODELESS/bash" "$MODE_SCRIPT" 2>&1); RC=$?
assert "exits 0 without node"                  rc_is 0
assert "dial still written"                    file_is "$S/pushmode-$HASH" loud
assert "warns that rules were not refreshed"   out_has "could not refresh"
assert "last push unknown, not 'none'"         out_has "LAST PUSH: unknown (node not found)"

echo
echo "[last push failure — the CLI's record, read only]"
# tests/fixtures/last-notify-failure.json is the exact line cli
# src/notify-failure.test.ts pins as what `hwip notify` writes.
state_reset
run_mode
assert "no record → says none"                 out_has "LAST PUSH: no failure recorded"
cp "$SCRIPT_DIR/fixtures/last-notify-failure.json" "$S/last-notify-failure.json"
run_mode
assert "names the failure"                     out_has "LAST PUSH: Last Hwip push failed at 2026-10-02T00:00:00.000Z: API key rejected"
assert "carries the HTTP status"               out_has "(HTTP 401)"
assert "points at hwip verify"                 out_has "Details: hwip verify"
assert "status leaves the record in place"     exists "$S/last-notify-failure.json"
# Refusals the CLI made before anything was sent: the fact, and no HTTP status.
printf '%s\n' '{"v":1,"at":"2026-10-02T00:00:00.000Z","kind":"no-app","status":null,"code":"NO_APP_DEVICE"}' > "$S/last-notify-failure.json"
run_mode
assert "no app → says to sign in to the app"   out_has "LAST PUSH: Last Hwip push failed at 2026-10-02T00:00:00.000Z: no app is signed in — sign in to the Hwip app on an iPhone or Android phone. Details: hwip verify"
assert "no app → no HTTP status"               out_lacks "(HTTP"
printf '%s\n' '{"v":1,"at":"2026-10-02T00:00:00.000Z","kind":"unsealed","status":null,"code":"E2E_REQUIRED"}' > "$S/last-notify-failure.json"
run_mode
assert "unsealed → nothing was sent"          out_has "LAST PUSH: Last Hwip push failed at 2026-10-02T00:00:00.000Z: could not encrypt the push, so nothing was sent — run: hwip verify."
assert "unsealed → names hwip verify once"    test "$(printf '%s\n' "$OUT" | grep '^LAST PUSH:' | grep -o 'hwip verify' | wc -l)" -eq 1
# A changed key is key-changes.json's now (below); the retired kind is unknown.
printf '%s\n' '{"v":1,"at":"2026-10-02T00:00:00.000Z","kind":"key-changed","status":null,"code":"KEY_CHANGED"}' > "$S/last-notify-failure.json"
run_mode
assert "retired key-change kind → none"       out_has "LAST PUSH: no failure recorded"
# The CLI no longer writes `plaintext`; a leftover record is an unknown kind.
printf '%s\n' '{"v":1,"at":"2026-10-02T00:00:00.000Z","kind":"plaintext","status":null,"code":"E2E_TIMEOUT"}' > "$S/last-notify-failure.json"
run_mode
assert "old plaintext kind → none"            out_has "LAST PUSH: no failure recorded"
printf '%s\n' '{"v":2,"at":"2026-10-02T00:00:00.000Z","kind":"auth"}' > "$S/last-notify-failure.json"
run_mode
assert "unknown version → none"                out_has "LAST PUSH: no failure recorded"
printf '{"v":1,"at":"$(touch %s)","kind":"auth","status":401}\n' "$WORK/pwned" > "$S/last-notify-failure.json"
run_mode
assert "non-ISO timestamp → none"              out_has "LAST PUSH: no failure recorded"
printf '%s\n' '{"v":1,"at":"2026-10-02T00:00:00.000Z","kind":"toString","status":1}' > "$S/last-notify-failure.json"
run_mode
assert "prototype key as kind → none"          out_has "LAST PUSH: no failure recorded"
state_reset

echo
echo "[key changes — kept by whoever replaced a pin, shown once]"
# tests/fixtures/key-changes.json is the line cli src/key-changes.test.ts pins.
KC="$WORK/home/.hwip/key-changes.json"
mkdir -p "$WORK/home/.hwip"
cp "$SCRIPT_DIR/fixtures/key-changes.json" "$KC"
run_mode
assert "names the device and the change"       out_has "Hwip: iPhone changed its encryption key — the new key is trusted. Not expecting that? Check: hwip trust"
assert "the record is gone once shown"         absent "$KC"
assert "nothing left beside it"               test -z "$(ls -A "$WORK/home/.hwip")"
run_mode
assert "a second run says nothing"            out_lacks "changed its encryption key"
# Nothing from the file is echoed as written: a name loses its control
# characters, an entry whose id or time is not one is dropped.
printf '{"v":1,"changes":[{"deviceId":"dev_a","at":"$(touch %s)"},{"deviceId":"no spaces","at":"2026-10-13T09:00:00.000Z"},{"deviceId":"dev_b","at":"2026-10-13T09:00:00.000Z","name":"\\u001b[2JPhone\\u202e"}]}\n' "$WORK/pwned" > "$KC"
run_mode
assert "a name without its control characters" out_has "Hwip: [2JPhone changed its encryption key"
assert "no escape byte in the output"         test "$(printf '%s' "$OUT" | grep -c $'\033')" -eq 0
assert "an id that is not one → dropped"      out_lacks "no spaces"
assert "a time that is not one → dropped"     out_lacks "dev_a"
assert "nothing from the file ran"            absent "$WORK/pwned"
printf 'garbage' > "$KC"
run_mode
assert "a broken record → nothing shown"      out_lacks "changed its encryption key"
assert "…and it is cleared"                   absent "$KC"
printf '%s\n' '{"v":2,"changes":[{"deviceId":"dev_ios_1","at":"2026-10-13T09:00:00.000Z"}]}' > "$KC"
run_mode
assert "another version → nothing shown"      out_lacks "changed its encryption key"
rm -f "$KC"
# The CLI and the MCP server hold ~/.hwip/trusted-devices.lock from reading
# the record to renaming the new one over it: a take in between would be
# put back and shown twice, so the take waits for the same lock.
LOCK="$WORK/home/.hwip/trusted-devices.lock"
cp "$SCRIPT_DIR/fixtures/key-changes.json" "$KC"
printf '%s %s000\n' "$$" "$(date +%s)" > "$LOCK"
run_mode
assert "a writer holds the lock → nothing shown" out_lacks "changed its encryption key"
assert "…the record kept for later"           test -e "$KC"
assert "…the writer's lock left alone"        test -e "$LOCK"
rm -f "$LOCK"
run_mode
assert "lock free again → shown"              out_has "Hwip: iPhone changed its encryption key — the new key is trusted. Not expecting that? Check: hwip trust"
assert "…and no lock left behind"             absent "$LOCK"
cp "$SCRIPT_DIR/fixtures/key-changes.json" "$KC"
printf '1 1\n' > "$LOCK"
touch -t 202001010000 "$LOCK"
run_mode
assert "a lock a dead process left → broken, shown" out_has "Hwip: iPhone changed its encryption key — the new key is trusted. Not expecting that? Check: hwip trust"
assert "…and gone"                            absent "$LOCK"
rm -rf "$WORK/home/.hwip"
run_mode
assert "no record → no ~/.hwip made for a lock" absent "$WORK/home/.hwip"

# ── summary ────────────────────────────────────────────────────────────────

echo
echo "Result: $PASS/$TOTAL passed"
if [ "$FAIL" -gt 0 ]; then
    printf '  - %s\n' "${FAILED_TESTS[@]}"
    exit 1
fi
exit 0
