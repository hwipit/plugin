#!/usr/bin/env bash
# Fixture-based tests for hooks/hwip-remote.sh (ADR-0002).
#
# hwip-remote is a UserPromptSubmit hook — it flags prompts that the hwip
# listener injected from the user's phone (exact-text sha256 match against
# a one-shot marker file) and emits additionalContext that enters sticky
# REMOTE mode. Everything else must be a silent no-op with exit 0.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/../hooks/hwip-remote.sh"

[ -f "$HOOK_SCRIPT" ] || { echo "hook script not found: $HOOK_SCRIPT" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

WORK=$(mktemp -d)
mkdir -p "$WORK/home"   # empty HOME for run_hook: no ~/.hwip/config.json
LEGACY_MARKERS=()
cleanup() {
    rm -rf "$WORK"
    for f in ${LEGACY_MARKERS[@]+"${LEGACY_MARKERS[@]}"}; do rm -f "$f"; done
}
trap cleanup EXIT

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

hash_of() { printf '%s' "$1" | cksum | cut -d' ' -f1; }
sha_of()  { printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1; }

marker_path() { echo "$WORK/state/hwip/remote-$(hash_of "$1")"; }
state_path()  { echo "$WORK/state/hwip/remote-active-$(hash_of "$1")"; }

# write_state <project_dir> [age_seconds] — sticky REMOTE state, as the hook
# writes it: one epoch second naming the last time REMOTE was confirmed.
write_state() {
    local dir="$1" age="${2:-0}"
    mkdir -p "$WORK/state/hwip"
    printf '%s\n' "$(( $(date +%s) - age ))" > "$(state_path "$dir")"
}

# write_marker <project_dir> <text> [age_seconds]
write_marker() {
    local dir="$1" text="$2" age="${3:-0}"
    mkdir -p "$WORK/state/hwip"
    printf '%s %s\n' "$(( $(date +%s) - age ))" "$(sha_of "$text")" > "$(marker_path "$dir")"
}

# run_hook <prompt> <project_dir> [hook_id] [home]
# Echoes hook stdout; exit status is the hook's exit status.
# HOME is pinned to an empty dir by default: the hook falls back to
# $HOME/.hwip/config.json for the hook id, and the real one would otherwise
# turn every "HWIP_HOOK_ID unset" case two-way on a machine that runs hwip.
run_hook() {
    local prompt="$1" project_dir="$2" hook_id="${3:-}" home="${4:-$WORK/home}"
    # SID, when set, is the session_id Claude Code puts in every hook input.
    jq -n --arg p "$prompt" --arg s "${SID:-}" '{prompt: $p} + (if $s != "" then {session_id: $s} else {} end)' \
      | CLAUDE_PROJECT_DIR="$project_dir" XDG_STATE_HOME="$WORK/state" \
        HWIP_HOOK_ID="$hook_id" HOME="$home" bash "$HOOK_SCRIPT" 2>/dev/null
}

# home_with_config [hook_id] — a HOME whose ~/.hwip/config.json is what
# `hwip setup` writes; no hook_id = a notify-only install. One dir, rewritten
# per call.
home_with_config() {
    local home="$WORK/home-cfg"
    mkdir -p "$home/.hwip"
    if [ -n "${1:-}" ]; then
        printf '{"apiKey":"k","hookId":"%s"}\n' "$1" > "$home/.hwip/config.json"
    else
        printf '{"apiKey":"k"}\n' > "$home/.hwip/config.json"
    fi
    echo "$home"
}

ctx_of() { jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null; }

# ── tests ──────────────────────────────────────────────────────────────────

echo "[fresh marker + matching prompt + HWIP_HOOK_ID → REMOTE context]"
P="$WORK/proj-a"
write_marker "$P" "fix the login bug"
OUT=$(run_hook "fix the login bug" "$P" "hook_123")
RC=$?
CTX=$(printf '%s' "$OUT" | ctx_of)
assert "exit 0"                          [ "$RC" -eq 0 ]
assert "emits additionalContext"         [ -n "$CTX" ]
assert "context enters REMOTE mode"      grep -q "REMOTE mode" <<<"$CTX"
assert "context names UserPromptSubmit"  grep -q '"hookEventName": *"UserPromptSubmit"' <<<"$OUT"
assert "marker consumed (one-shot)"      [ ! -f "$(marker_path "$P")" ]
# The transition turn is the only channel that ships Rule 9 in full: the
# SessionStart hook gives a NORMAL session a two-line stub, because it cannot
# know a phone message is coming. If this stops arriving, that stub is a
# promise nothing keeps.
assert "carries Rule 9 in full"          grep -q "State Detection" <<<"$CTX"
assert "including the exit marker"       grep -q "hwip: exit" <<<"$CTX"
assert "and the REMOTE timeout window"   grep -q "300–600 s" <<<"$CTX"
# Same ceiling the SessionStart hook is held to: above 10,000 chars Claude
# Code persists additionalContext to a file and hands the model a 2,000-char
# preview, which would cut Rule 9 off right where it starts.
assert "stays under the inline ceiling"  [ "${#CTX}" -le 10000 ]

echo
echo "[matching prompt, HWIP_HOOK_ID unset → one-way conversion CTA]"
P="$WORK/proj-oneway"
write_marker "$P" "check the deploy status"
CTX=$(run_hook "check the deploy status" "$P" | ctx_of)
assert "emits additionalContext"      [ -n "$CTX" ]
assert "mentions setup CTA"           grep -q "npx @hwip/cli setup" <<<"$CTX"
assert_not "does not claim two-way"   grep -q "end EVERY response" <<<"$CTX"
assert "marker consumed"              [ ! -f "$(marker_path "$P")" ]

echo
echo "[HWIP_HOOK_ID unset, hookId in ~/.hwip/config.json → two-way (env is not the only store)]"
# The shape `hwip setup` leaves behind — see gate.sh hwip_hook_id.
P="$WORK/proj-config"
write_marker "$P" "from the phone, config only"
CTX=$(run_hook "from the phone, config only" "$P" "" "$(home_with_config hook_cfg)" | ctx_of)
assert "enters REMOTE"           grep -q "REMOTE mode" <<<"$CTX"
assert_not "no setup CTA"        grep -q "npx @hwip/cli setup" <<<"$CTX"
assert "state written"           [ -f "$(state_path "$P")" ]

echo
echo "[unresolved \${HWIP_HOOK_ID} placeholder → treated as unset (one-way when config has no id)]"
P="$WORK/proj-placeholder"
write_marker "$P" "placeholder in env"
CTX=$(run_hook "placeholder in env" "$P" '${HWIP_HOOK_ID}' "$(home_with_config)" | ctx_of)
assert "mentions setup CTA"          grep -q "npx @hwip/cli setup" <<<"$CTX"
assert_not "does not enter REMOTE"   grep -q "end EVERY response" <<<"$CTX"

echo
echo "[config.json without hookId, env unset → one-way CTA (a notify-only install)]"
P="$WORK/proj-config-noid"
write_marker "$P" "notify-only install"
CTX=$(run_hook "notify-only install" "$P" "" "$(home_with_config)" | ctx_of)
assert "mentions setup CTA"          grep -q "npx @hwip/cli setup" <<<"$CTX"
assert_not "does not enter REMOTE"   grep -q "end EVERY response" <<<"$CTX"
assert "no state written"            [ ! -f "$(state_path "$P")" ]

echo
echo "[sticky state alive, env unset, hookId in config.json → terminal turn still ends REMOTE]"
P="$WORK/proj-sticky-config"
write_state "$P"
CTX=$(run_hook "typed at the terminal" "$P" "" "$(home_with_config hook_cfg)" | ctx_of)
assert "says REMOTE has ended"  grep -q "LEFT sticky REMOTE mode" <<<"$CTX"
assert "state cleared"          [ ! -f "$(state_path "$P")" ]

echo
echo "[text mismatch → silent, marker kept (terminal race can't false-match)]"
P="$WORK/proj-mismatch"
write_marker "$P" "the phone message"
OUT=$(run_hook "something typed at the terminal" "$P" "hook_123")
assert "no output"     [ -z "$OUT" ]
assert "marker kept"   [ -f "$(marker_path "$P")" ]

echo
echo "[within the 15-min window (e.g. long agent turn) → still matches]"
P="$WORK/proj-longturn"
write_marker "$P" "sent during a long turn" 600
CTX=$(run_hook "sent during a long turn" "$P" "hook_123" | ctx_of)
assert "matches at 10 min"  [ -n "$CTX" ]

echo
echo "[stale marker (>15min) → silent, marker deleted (housekeeping)]"
P="$WORK/proj-stale"
write_marker "$P" "old command" 1000
OUT=$(run_hook "old command" "$P" "hook_123")
assert "no output"       [ -z "$OUT" ]
assert "marker deleted"  [ ! -f "$(marker_path "$P")" ]

echo
echo "[muted project → silent, marker left unconsumed]"
P="$WORK/proj-muted"
write_marker "$P" "while muted"
touch "$WORK/state/hwip/muted-$(hash_of "$P")"
OUT=$(run_hook "while muted" "$P" "hook_123")
assert "no output"     [ -z "$OUT" ]
assert "marker kept"   [ -f "$(marker_path "$P")" ]

echo
echo "[no marker at all → silent no-op]"
P="$WORK/proj-none"
OUT=$(run_hook "any prompt" "$P" "hook_123")
RC=$?
assert "no output"  [ -z "$OUT" ]
assert "exit 0"     [ "$RC" -eq 0 ]

echo
echo "[whitespace-padded prompt still matches (trim mirrors listener)]"
P="$WORK/proj-trim"
write_marker "$P" "run the tests"
CTX=$(run_hook "  run the tests
" "$P" "hook_123" | ctx_of)
assert "matches after trim"  [ -n "$CTX" ]

echo
echo "[multi-line prompt matches byte-for-byte]"
P="$WORK/proj-multiline"
ML=$'first line\nsecond line'
write_marker "$P" "$ML"
CTX=$(run_hook "$ML" "$P" "hook_123" | ctx_of)
assert "multi-line match"  [ -n "$CTX" ]

echo
echo "[trailing U+00A0 NBSP survives the trim on both sides (ASCII-only parity)]"
P="$WORK/proj-nbsp"
NB=$'nbsp end\xc2\xa0'
write_marker "$P" "$NB"
CTX=$(run_hook "$NB" "$P" "hook_123" | ctx_of)
assert "NBSP-suffixed text matches"  [ -n "$CTX" ]

echo
echo "[malformed marker content → silent, no crash]"
P="$WORK/proj-garbage"
mkdir -p "$WORK/state/hwip"
printf 'not-a-timestamp junk\n' > "$(marker_path "$P")"
OUT=$(run_hook "whatever" "$P" "hook_123")
RC=$?
assert "no output"        [ -z "$OUT" ]
assert "marker deleted"   [ ! -f "$(marker_path "$P")" ]
assert "exit 0"     [ "$RC" -eq 0 ]

echo
echo "[empty prompt → silent no-op]"
P="$WORK/proj-empty"
write_marker "$P" "phone text"
OUT=$(printf '{"prompt":""}' \
  | CLAUDE_PROJECT_DIR="$P" XDG_STATE_HOME="$WORK/state" HWIP_HOOK_ID=x bash "$HOOK_SCRIPT" 2>/dev/null)
assert "no output"    [ -z "$OUT" ]
assert "marker kept"  [ -f "$(marker_path "$P")" ]

echo
echo "[legacy /tmp marker owned by current user → honored]"
P="$WORK/proj-legacy"
LEGACY="/tmp/hwip-remote-$(hash_of "$P")"
LEGACY_MARKERS+=("$LEGACY")
printf '%s %s\n' "$(date +%s)" "$(sha_of "legacy path text")" > "$LEGACY"
CTX=$(run_hook "legacy path text" "$P" "hook_123" | ctx_of)
assert "legacy marker matches"   [ -n "$CTX" ]
assert "legacy marker consumed"  [ ! -f "$LEGACY" ]

echo
echo "[sticky state alive, no marker → the user is back at the terminal: leave REMOTE]"
P="$WORK/proj-sticky"
write_state "$P"
OUT=$(run_hook "typed at the terminal mid-session" "$P" "hook_123")
RC=$?
CTX=$(printf '%s' "$OUT" | ctx_of)
assert "exit 0"                  [ "$RC" -eq 0 ]
assert "says REMOTE has ended"   grep -q "LEFT sticky REMOTE mode" <<<"$CTX"
# This turn returns the session to NORMAL, and NORMAL owes no hwip_ask. The
# note used to say "Rule 3 still holds" here — re-imposing the REMOTE rule
# on the exact turn the session left it.
assert "owes no hwip_ask"        grep -q "you owe no" <<<"$CTX"
assert_not "no leftover Rule 3"  grep -q "Rule 3 still holds" <<<"$CTX"
assert "state cleared"           [ ! -f "$(state_path "$P")" ]
assert_not "not the entry note"  grep -q "arrived from the user's phone" <<<"$CTX"

echo
echo "[the exit note is emitted once — later terminal turns are silent]"
OUT=$(run_hook "and another one" "$P" "hook_123")
assert "no output"  [ -z "$OUT" ]

echo
echo "[sticky state alive, Claude Code task-notification turn → not the keyboard, REMOTE kept]"
# A hwip_ask that outlives Claude Code's MCP auto-background window returns the
# phone answer as a <task-notification> turn — a prompt with no marker.
P="$WORK/proj-system-turn"
write_state "$P"
TN='<task-notification>
<task-id>ks07i7m2l</task-id>
<status>completed</status>
<summary>MCP task ks07i7m2 (plugin:hwip:hwip/hwip_ask) completed.</summary>
<result>
{"value":"answered on the phone","timedOut":false,"hwipState":"REMOTE"}
</result>
</task-notification>'
OUT=$(run_hook "$TN" "$P" "hook_123")
RC=$?
assert "exit 0"      [ "$RC" -eq 0 ]
assert "no output"   [ -z "$OUT" ]
assert "state kept"  [ -f "$(state_path "$P")" ]

echo
echo "[sticky state alive, subagent/peer report turn → not the keyboard, REMOTE kept]"
OUT=$(run_hook 'Another Claude session sent a message:
<agent-message from="a1b2c3">
  report body
</agent-message>' "$P" "hook_123")
assert "no output"   [ -z "$OUT" ]
assert "state kept"  [ -f "$(state_path "$P")" ]

echo
echo "[the other system wordings (mid-turn peer, cross-session wrapper, plugin) → REMOTE kept]"
for SYS in \
    'Another Claude session sent a message while you were working:
report body' \
    'A peer session sent a message while you were working:
report body' \
    '<cross-session-message from="a1b2c3">
report body
</cross-session-message>' \
    'The ralph plugin sent a message:
keep going'; do
    OUT=$(run_hook "$SYS" "$P" "hook_123")
    assert "no output: ${SYS%%$'\n'*}"   [ -z "$OUT" ]
    assert "state kept: ${SYS%%$'\n'*}"  [ -f "$(state_path "$P")" ]
done

echo
echo "[a prompt typed at the terminal after those → still leaves REMOTE]"
CTX=$(run_hook "typed at the terminal after the notification" "$P" "hook_123" | ctx_of)
assert "says REMOTE has ended"  grep -q "LEFT sticky REMOTE mode" <<<"$CTX"
assert "state cleared"          [ ! -f "$(state_path "$P")" ]

echo
echo "[the prefix must lead the prompt — typed text that mentions it still leaves]"
P="$WORK/proj-system-mention"
write_state "$P"
CTX=$(run_hook "why did <task-notification> end REMOTE?" "$P" "hook_123" | ctx_of)
assert "says REMOTE has ended"  grep -q "LEFT sticky REMOTE mode" <<<"$CTX"
assert "state cleared"          [ ! -f "$(state_path "$P")" ]

echo
echo "[fresh marker left unmatched → REMOTE survives (a phone message is in flight)]"
# The digest missing is not evidence the user typed: the message may be queued
# behind a long turn, or the two sides may hash a composition differently.
# Dropping REMOTE here strands a user who is still holding the phone.
P="$WORK/proj-pending"
write_state "$P"
write_marker "$P" "the phone message"
OUT=$(run_hook "not the injected text" "$P" "hook_123")
assert "no output"     [ -z "$OUT" ]
assert "state kept"    [ -f "$(state_path "$P")" ]
assert "marker kept"   [ -f "$(marker_path "$P")" ]

echo
echo "[empty prompt with a marker pending → no evidence, state kept]"
P="$WORK/proj-empty-sticky"
write_state "$P"
write_marker "$P" "the phone message"
OUT=$(printf '{"prompt":""}' \
  | CLAUDE_PROJECT_DIR="$P" XDG_STATE_HOME="$WORK/state" HWIP_HOOK_ID=x bash "$HOOK_SCRIPT" 2>/dev/null)
assert "no output"   [ -z "$OUT" ]
assert "state kept"  [ -f "$(state_path "$P")" ]

echo
echo "[stale marker on a live REMOTE session → still a terminal turn, REMOTE ends]"
P="$WORK/proj-stale-sticky"
write_state "$P"
write_marker "$P" "old phone text" 1000
CTX=$(run_hook "typed at the terminal" "$P" "hook_123" | ctx_of)
assert "says REMOTE has ended"  grep -q "LEFT sticky REMOTE mode" <<<"$CTX"
assert "state cleared"          [ ! -f "$(state_path "$P")" ]
assert "stale marker swept"     [ ! -f "$(marker_path "$P")" ]

echo
echo "[a phone message after that re-enters REMOTE (re-entry is one message)]"
P="$WORK/proj-sticky"
write_marker "$P" "back on the phone"
CTX=$(run_hook "back on the phone" "$P" "hook_123" | ctx_of)
assert "entry note again"  grep -q "arrived from the user's phone" <<<"$CTX"
assert "state written"     [ -f "$(state_path "$P")" ]

echo
echo "[marker match writes the sticky state]"
P="$WORK/proj-enter"
write_marker "$P" "start from the phone"
CTX=$(run_hook "start from the phone" "$P" "hook_123" | ctx_of)
assert "entered REMOTE"   [ -n "$CTX" ]
assert "state written"    [ -f "$(state_path "$P")" ]
assert "marker consumed"  [ ! -f "$(marker_path "$P")" ]

echo
echo "[sticky state alive but muted → silent (mute outranks, Rule 12)]"
P="$WORK/proj-sticky-muted"
write_state "$P"
touch "$WORK/state/hwip/muted-$(hash_of "$P")"
OUT=$(run_hook "anything" "$P" "hook_123")
assert "no output"   [ -z "$OUT" ]
assert "state kept"  [ -f "$(state_path "$P")" ]

echo
echo "[sticky state past the TTL → silent, state swept (no SessionEnd hook exists)]"
P="$WORK/proj-sticky-stale"
write_state "$P" 20000
OUT=$(run_hook "much later" "$P" "hook_123")
RC=$?
assert "no output"       [ -z "$OUT" ]
assert "exit 0"          [ "$RC" -eq 0 ]
assert "state deleted"   [ ! -f "$(state_path "$P")" ]

echo
echo "[sticky state alive, HWIP_HOOK_ID unset → silent (no hwip_ask to remind about)]"
P="$WORK/proj-sticky-oneway"
write_state "$P"
OUT=$(run_hook "typed at the terminal" "$P")
assert "no output"   [ -z "$OUT" ]
assert "state kept"  [ -f "$(state_path "$P")" ]

echo
echo "[garbled sticky state → silent, swept]"
P="$WORK/proj-sticky-garbage"
mkdir -p "$WORK/state/hwip"
printf 'not-a-timestamp\n' > "$(state_path "$P")"
OUT=$(run_hook "whatever" "$P" "hook_123")
RC=$?
assert "no output"      [ -z "$OUT" ]
assert "exit 0"         [ "$RC" -eq 0 ]
assert "state deleted"  [ ! -f "$(state_path "$P")" ]

echo
echo "[state written as an exponent is swept, not read as a far-future stamp]"
# Parity regression: bash rejects any non-digit, so the TS twin must too —
# Number('1e10') would otherwise resolve to a year-2286 timestamp and keep
# REMOTE alive forever on a file bash throws away.
P="$WORK/proj-sticky-exponent"
mkdir -p "$WORK/state/hwip"
printf '1e10\n' > "$(state_path "$P")"
OUT=$(run_hook "whatever" "$P" "hook_123")
assert "no output"      [ -z "$OUT" ]
assert "state deleted"  [ ! -f "$(state_path "$P")" ]

echo
echo "[unremovable marker still enters REMOTE (housekeeping is not the verdict)]"
# Regression: the match function used to return `rm`'s status, so a state dir
# the user cannot write turned a verified phone message into a no-match.
if [ "$(id -u)" -eq 0 ]; then
    echo "  – skipped (running as root; rm cannot be made to fail)"
else
    P="$WORK/proj-rm-fails"
    write_marker "$P" "phone text under a locked dir"
    chmod 555 "$WORK/state/hwip"
    CTX=$(run_hook "phone text under a locked dir" "$P" "hook_123" | ctx_of)
    chmod 755 "$WORK/state/hwip"
    assert "still enters REMOTE"  grep -q "REMOTE mode" <<<"$CTX"
    rm -f "$(marker_path "$P")"
fi

# ── P18: the full contract once per session, a reminder after ───────────────
#
# Rule 9 in full is ~2.7 KB and used to ride on EVERY phone message, REMOTE or
# not. A session that has already been given it (this hook on an earlier phone
# message, or SessionStart on a REMOTE session) gets a short reminder instead.
# "Already given" is per session, not per project: remote-active is keyed by the
# project directory, so a second session in the same directory sees a live
# REMOTE it was never told about.

injected_path() { echo "$WORK/state/hwip/remote-injected-$1"; }
P="$WORK/proj-p18"

echo
echo "[P18: first phone message of a session — Rule 9 in full, session marked]"
SID=sess-aaaa
write_marker "$P" "first message"
CTX=$(run_hook "first message" "$P" "hook_123" | ctx_of)
assert "carries Rule 9 in full"             grep -q "State Detection" <<<"$CTX"
assert "the session is marked as given"     [ -f "$(injected_path sess-aaaa)" ]

echo
echo "[P18: second phone message, same session — a short reminder]"
write_marker "$P" "second message"
rm -f "$(state_path "$P")"
CTX=$(run_hook "second message" "$P" "hook_123" | ctx_of)
assert_not "no Rule 9 body"                 grep -q "State Detection" <<<"$CTX"
assert "still says it came from the phone"  grep -q "phone" <<<"$CTX"
assert "keeps the hwip_ask duty"            grep -q 'end EVERY response with `hwip_ask`' <<<"$CTX"
assert "keeps actions and the Done-like fallback" grep -q "Done-like" <<<"$CTX"
assert "keeps the timeout window"           grep -q "300–600" <<<"$CTX"
assert "names the exits"                    grep -q "send and exit" <<<"$CTX"
assert "…including the exit marker"         grep -q "hwip: exit" <<<"$CTX"
assert "…and a prompt typed at the terminal" grep -q "terminal" <<<"$CTX"
assert "a few lines, not the section"       [ "${#CTX}" -le 1200 ]
assert "REMOTE state still (re)written"     [ -f "$(state_path "$P")" ]
assert "marker consumed"                    [ ! -f "$(marker_path "$P")" ]

echo
echo "[P18: another session's first phone message — full, though REMOTE is live]"
SID=sess-bbbb
write_state "$P"
write_marker "$P" "hello from the other session"
CTX=$(run_hook "hello from the other session" "$P" "hook_123" | ctx_of)
assert "carries Rule 9 in full"             grep -q "State Detection" <<<"$CTX"
assert "that session is marked too"         [ -f "$(injected_path sess-bbbb)" ]

echo
echo "[P18: no session id in the hook input — always full]"
SID=""
write_marker "$P" "no id one"
CTX=$(run_hook "no id one" "$P" "hook_123" | ctx_of)
assert "carries Rule 9 in full"             grep -q "State Detection" <<<"$CTX"
write_marker "$P" "no id two"
CTX=$(run_hook "no id two" "$P" "hook_123" | ctx_of)
assert "…every time"                        grep -q "State Detection" <<<"$CTX"
assert "nothing marked"                     [ "$(ls "$WORK/state/hwip" | grep -c '^remote-injected-')" -eq 2 ]

echo
echo "[P18: a session id that is not a plain token never becomes a path]"
# A dot is not in [A-Za-z0-9_-]: unfiltered, it would create remote-injected-sess.1.
SID='sess.1'
write_marker "$P" "path trick"
CTX=$(run_hook "path trick" "$P" "hook_123" | ctx_of)
assert "still answers in full"              grep -q "State Detection" <<<"$CTX"
assert "writes no mark for it"              [ ! -e "$(injected_path 'sess.1')" ]
SID=""

# ── summary ────────────────────────────────────────────────────────────────

echo
echo "────────────────────────────────"
echo "PASS: $PASS / $TOTAL"
if [ "$FAIL" -gt 0 ]; then
    echo "FAILED:"
    for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
    exit 1
fi
