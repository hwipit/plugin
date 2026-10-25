#!/usr/bin/env bash
# Tests for hooks/hwip-setup.js (SessionStart hook).
#
# Guards these regressions:
#   - the section extraction from CORE_RULES.md must be non-empty for every
#     branch (a heading rename there would silently inject empty rules —
#     lint-rules-sync validates a different extractor, not this one)
#   - the Mode label must render exactly once ("Mode: Mode: two-way" shipped
#     once from a doubled prefix)
#   - the unconfigured path must emit the setup note, not rules
#   - EVERY branch must stay under Claude Code's inline hook-context ceiling.
#     Above 10,000 chars the harness persists additionalContext to a file and
#     hands the model a 2,000-char preview instead, so the rules below the cut
#     never arrive. The unconditional block was 15,483 bytes and lost most of
#     itself that way; these assertions are what stops that recurring.
#   - each branch injects only what its state can act on: no Push Signal in
#     REMOTE (markers are ignored there), no ask rules without a hook id

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/../hooks/hwip-setup.js"

[ -f "$HOOK_SCRIPT" ] || { echo "hook script not found: $HOOK_SCRIPT" >&2; exit 1; }
command -v node >/dev/null || { echo "node required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# Empty HOME so the real ~/.hwip/config.json can't leak keys into the test.
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

# Claude Code persists a hook's additionalContext above this many chars
# (cli.js `Pyt(e,t,r,n=k$d)`, `k$d=1e4`) and replaces it with a 2,000-char
# preview. Measured against 2.1.234.
INLINE_CEILING=10000

# State the branches key on lives under XDG_STATE_HOME, keyed by project dir.
STATE="$WORK/state"
PROJECT="$WORK/project"
mkdir -p "$STATE/hwip" "$PROJECT"
PROJECT_HASH=$(printf '%s' "$PROJECT" | cksum | cut -d' ' -f1)
state_reset() { rm -f "$STATE/hwip"/*; }

# run_hook [ENV=val ...] — prints extracted additionalContext.
run_hook() {
    env -i HOME="$WORK/home" PATH="$PATH" XDG_STATE_HOME="$STATE" \
        CLAUDE_PROJECT_DIR="$PROJECT" "$@" node "$HOOK_SCRIPT" 2>/dev/null </dev/null \
      | jq -r '.hookSpecificOutput.additionalContext // empty'
}

ctx_has()     { printf '%s' "$CTX" | grep -qF -- "$1"; }
ctx_min_len() { [ "${#CTX}" -ge "$1" ]; }
ctx_max_len() { [ "${#CTX}" -le "$1" ]; }
ctx_inline()  { ctx_max_len "$INLINE_CEILING"; }
# The branch/doc-only markers are how CORE_RULES.md carries text for more than
# one state; the hook resolves them and none may reach the model.
ctx_no_markers() { ! printf '%s' "$CTX" | grep -qE '<!-- /?hwip-(branch|doc-only)'; }

# ── tests ──────────────────────────────────────────────────────────────────

echo "[NORMAL — API key + hook ID, no remote state]"
state_reset
CTX=$(run_hook HWIP_API_KEY=test-key HWIP_HOOK_ID=test-hook)
assert "emits non-trivial rules (≥500 chars)"  ctx_min_len 500
assert "fits inline, uncut"                    ctx_inline
assert "no branch markers leak"                ctx_no_markers
assert "carries two-way rule content"          ctx_has "hwip_ask"
assert "says the user is at the terminal"      ctx_has "the user is at the terminal"
assert "states no ask is owed"                 ctx_has "You owe no"
assert "names what starts REMOTE"              ctx_has "What starts REMOTE"
# A session that enters REMOTE mid-turn has only this stub, so the phone's
# send-and-exit must be among its exits or the model keeps asking.
assert "names the phone's send-and-exit"       ctx_has '"send and exit"'
assert "ends send-and-exit with no ask"        ctx_has 'carry it out, no `hwip_ask`'
assert "keeps Rule 13 (compaction)"            ctx_has "after context compaction"
# Rules 7·8 govern only a hwip_ask answer; hooks/hwip-ask-result.js hands them
# over with the first hwip_ask result (tests/test-hwip-ask-result.sh).
assert_not "NORMAL leaves rules 7·8 to the hwip_ask result" ctx_has "### Handling the response"
# Rules 3/4/5/6/10/11 are REMOTE-scoped. Injecting them here is the regression
# that made a terminal session block on a phone answer nobody was there to give.
assert_not "no MANDATORY-ask rule"             ctx_has "NEVER end a response"
assert_not "no AskUserQuestion override"       ctx_has "MUST go through"
assert_not "no sticky-REMOTE full text"        ctx_has "State Detection"
assert "labels mode two-way"                   ctx_has "Mode: two-way"
assert_not "no doubled Mode prefix"            ctx_has "Mode: Mode:"

echo
echo "[NORMAL — the Push Signal block follows the project's dial]"
state_reset
CTX=$(run_hook HWIP_API_KEY=test-key HWIP_HOOK_ID=test-hook)
assert "no dial → quiet, high is the channel" ctx_has "push dial is **quiet**"
assert_not "quiet hides the skip marker"      ctx_has "hwip: skip"
# Every NORMAL session pays for this block, so it stays short — but keeps each
# fact: only high pushes, skip/push are inert, once on an awaited completion,
# never routine, not on a hwip_ask turn, not to reach someone away.
QUIET=$(printf '%s\n' "$CTX" | awk '/^### Push Signal/{on=1; print; next} on && /^### /{exit} on')
assert "quiet Push Signal fits in 400 chars"  test "$(printf '%s' "$QUIET" | wc -m)" -le 400
for fact in 'only `<!-- hwip: high -->`' '`skip`/`push` do nothing' 'once on a completion' 'never on routine work' 'a `hwip_ask` turn ignores it' 'never emit `high` to reach them'; do
    assert "…still says $fact"                grep -qF -- "$fact" <<<"$QUIET"
done
echo normal > "$STATE/hwip/pushmode-$PROJECT_HASH"
CTX=$(run_hook HWIP_API_KEY=test-key HWIP_HOOK_ID=test-hook)
assert "normal dial → all three markers"      ctx_has "hwip: skip"
assert "and the heuristic it overrides"       ctx_has "read-only (Read/Grep/Glob)"
assert "still fits inline"                    ctx_inline
assert "no branch markers leak"                ctx_no_markers

echo
echo "[REMOTE — sticky state is live for this project]"
state_reset
date +%s > "$STATE/hwip/remote-active-$PROJECT_HASH"
CTX=$(run_hook HWIP_API_KEY=test-key HWIP_HOOK_ID=test-hook)
assert "fits inline, uncut"                    ctx_inline
assert "no branch markers leak"                ctx_no_markers
assert "says the session is in REMOTE"         ctx_has "this session is in REMOTE"
assert "carries the sticky-REMOTE contract"    ctx_has "State Detection"
assert "carries the MANDATORY-ask rule"        ctx_has "NEVER end a response"
assert "carries the AskUserQuestion override"  ctx_has "MUST go through"
assert "carries rules 7·8 (every turn asks)"   ctx_has "### Handling the response"
assert "carries the exit marker"               ctx_has "hwip: exit"
assert "keeps Rule 13 (compaction)"            ctx_has "after context compaction"
assert_not "no Push Signal section (ignored in REMOTE)" ctx_has "### Push Signal"

echo
echo "[REMOTE — an expired state file is not REMOTE]"
state_reset
echo $(( $(date +%s) - 14401 )) > "$STATE/hwip/remote-active-$PROJECT_HASH"
CTX=$(run_hook HWIP_API_KEY=test-key HWIP_HOOK_ID=test-hook)
assert "falls back to NORMAL"                  ctx_has "the user is at the terminal"

echo
echo "[muted — the hooks are silent, so the rules are three lines]"
state_reset
touch "$STATE/hwip/muted-$PROJECT_HASH"
CTX=$(run_hook HWIP_API_KEY=test-key HWIP_HOOK_ID=test-hook)
assert "under 400 chars"                       ctx_max_len 400
assert "says it is muted"                      ctx_has "muted"
assert "says how to lift it"                   ctx_has "/hwip-mode unmute"
assert_not "no ask rules"                      ctx_has "MANDATORY"
state_reset

echo
echo "[one-way — API key only]"
state_reset
CTX=$(run_hook HWIP_API_KEY=test-key)
assert "emits non-trivial rules (≥300 chars)"  ctx_min_len 300
assert "fits inline, uncut"                    ctx_inline
assert "no branch markers leak"                ctx_no_markers
assert "carries one-way rule content"          ctx_has "hwip_notify"
assert "labels mode one-way"                   ctx_has "Mode: one-way"
assert "notes two-way tools unavailable"       ctx_has "HWIP_HOOK_ID"
assert_not "no doubled Mode prefix"            ctx_has "Mode: Mode:"
assert_not "no dead ask rules"                 ctx_has "MANDATORY"
assert_not "no sticky REMOTE"                  ctx_has "State Detection"

echo
echo "[unconfigured — no key anywhere]"
CTX=$(run_hook)
assert "emits the not-configured note"         ctx_has "not configured"
assert_not "does not inject rules"             ctx_has "Mode: "

echo
echo "[unresolved \${VAR} placeholders count as unset]"
CTX=$(run_hook 'HWIP_API_KEY=${HWIP_API_KEY}')
assert "placeholder key → not-configured note" ctx_has "not configured"

echo
echo "[user-visible systemMessage — only the states that silence the plugin]"
# additionalContext reaches only the model; systemMessage is what the user sees.
sysmsg() {
    env -i HOME="$WORK/home" PATH="${SYSMSG_PATH:-$PATH}" XDG_STATE_HOME="$STATE" \
        CLAUDE_PROJECT_DIR="$PROJECT" "$@" "$NODE_BIN" "$HOOK_SCRIPT" 2>/dev/null \
      | jq -r '.systemMessage // empty'
}
NODE_BIN=$(command -v node)
state_reset
MSG=$(sysmsg)
assert "unconfigured → tells the user to run setup" test -n "$(printf '%s' "$MSG" | grep -F 'npx @hwip/cli setup')"
touch "$STATE/hwip/muted-$PROJECT_HASH"
MSG=$(sysmsg HWIP_API_KEY=test-key HWIP_HOOK_ID=test-hook)
assert "muted → tells the user how to unmute"      test -n "$(printf '%s' "$MSG" | grep -F '/hwip-mode unmute')"
state_reset
MSG=$(sysmsg HWIP_API_KEY=test-key HWIP_HOOK_ID=test-hook)
assert "configured with jq → no message"           test -z "$MSG"
NOJQ="$WORK/nojq"
mkdir -p "$NOJQ"
ln -sf "$(command -v cksum)" "$NOJQ/cksum"
MSG=$(SYSMSG_PATH="$NOJQ" sysmsg HWIP_API_KEY=test-key HWIP_HOOK_ID=test-hook)
assert "no jq → tells the user to install it"      test -n "$(printf '%s' "$MSG" | grep -F 'brew install jq')"

echo
echo "[no CLAUDE_PROJECT_DIR — hashes what the shell hooks hash (\$PWD)]"
# A symlinked cwd: the shell hooks key state on ${CLAUDE_PROJECT_DIR:-$PWD}, and
# bash keeps the symlinked PWD it inherits. process.cwd() is the physical path,
# so this hook used to miss a mute the shell side had written.
REAL_DIR="$WORK/real-project"; LINK_DIR="$WORK/link-project"
mkdir -p "$REAL_DIR"; ln -s "$REAL_DIR" "$LINK_DIR"
LINK_HASH=$(printf '%s' "$LINK_DIR" | cksum | cut -d' ' -f1)
REAL_HASH=$(cd "$REAL_DIR" && pwd -P | tr -d '\n' | cksum | cut -d' ' -f1)
from_dir() {
    (cd "$LINK_DIR" && env -i HOME="$WORK/home" PATH="$PATH" XDG_STATE_HOME="$STATE" "$@" \
        HWIP_API_KEY=test-key HWIP_HOOK_ID=test-hook node "$HOOK_SCRIPT" 2>/dev/null \
      | jq -r '.hookSpecificOutput.additionalContext // empty')
}
state_reset
touch "$STATE/hwip/muted-$LINK_HASH"
CTX=$(from_dir PWD="$LINK_DIR")
assert "symlinked PWD → the shell hooks' key"      ctx_has "muted"
state_reset
touch "$STATE/hwip/muted-$REAL_HASH"
CTX=$(from_dir)
assert "no PWD → the physical path, as bash does"  ctx_has "muted"
CTX=$(from_dir PWD="/somewhere/else")
assert "a PWD that is not the cwd → physical path" ctx_has "muted"
state_reset

echo "[last push failure — shown to the user in every configured state]"
# Same fixture the /hwip-mode test and cli's notify-failure.test.ts pin.
state_reset
cp "$SCRIPT_DIR/fixtures/last-notify-failure.json" "$STATE/hwip/last-notify-failure.json"
MSG=$(sysmsg HWIP_API_KEY=test-key HWIP_HOOK_ID=test-hook)
assert "configured → the failure line"             test -n "$(printf '%s' "$MSG" | grep -F 'Last Hwip push failed at 2026-10-02T00:00:00.000Z')"
touch "$STATE/hwip/muted-$PROJECT_HASH"
MSG=$(sysmsg HWIP_API_KEY=test-key HWIP_HOOK_ID=test-hook)
assert "muted → mute note and the failure"         test "$(printf '%s\n' "$MSG" | grep -cE 'muted for this project|Last Hwip push failed')" -eq 2
rm -f "$STATE/hwip/muted-$PROJECT_HASH"
MSG=$(SYSMSG_PATH="$NOJQ" sysmsg HWIP_API_KEY=test-key HWIP_HOOK_ID=test-hook)
assert "no jq → jq note and the failure"           test "$(printf '%s\n' "$MSG" | grep -cE 'brew install jq|Last Hwip push failed')" -eq 2
# A refusal before anything was sent: the fact, no HTTP status.
printf '%s\n' '{"v":1,"at":"2026-10-02T00:00:00.000Z","kind":"no-app","status":null,"code":"NO_APP_DEVICE"}' > "$STATE/hwip/last-notify-failure.json"
MSG=$(sysmsg HWIP_API_KEY=test-key HWIP_HOOK_ID=test-hook)
assert "no-app record → sign in to the app"        test -n "$(printf '%s' "$MSG" | grep -F 'no app is signed in — sign in to the Hwip app on an iPhone or Android phone')"
assert "no-app record → no HTTP status"           test -z "$(printf '%s' "$MSG" | grep -F 'HTTP')"
rm -f "$STATE/hwip/last-notify-failure.json"
MSG=$(sysmsg HWIP_API_KEY=test-key HWIP_HOOK_ID=test-hook)
assert "record gone → no message"                  test -z "$MSG"

echo "[key changes — shown once at session start, then gone]"
# Same fixture the /hwip-mode test and cli's key-changes.test.ts pin.
state_reset
mkdir -p "$WORK/home/.hwip"
cp "$SCRIPT_DIR/fixtures/key-changes.json" "$WORK/home/.hwip/key-changes.json"
MSG=$(sysmsg HWIP_API_KEY=test-key HWIP_HOOK_ID=test-hook)
assert "configured → the key-change line"         test -n "$(printf '%s' "$MSG" | grep -F 'Hwip: iPhone changed its encryption key — the new key is trusted. Not expecting that? Check: hwip trust')"
assert "the record is gone once shown"           test ! -e "$WORK/home/.hwip/key-changes.json"
MSG=$(sysmsg HWIP_API_KEY=test-key HWIP_HOOK_ID=test-hook)
assert "next session start → no message"         test -z "$MSG"
cp "$SCRIPT_DIR/fixtures/key-changes.json" "$WORK/home/.hwip/key-changes.json"
touch "$STATE/hwip/muted-$PROJECT_HASH"
MSG=$(sysmsg HWIP_API_KEY=test-key HWIP_HOOK_ID=test-hook)
assert "muted → mute note and the key change"     test "$(printf '%s\n' "$MSG" | grep -cE 'muted for this project|changed its encryption key')" -eq 2
rm -f "$STATE/hwip/muted-$PROJECT_HASH" "$WORK/home/.hwip/key-changes.json"
# A writer holding ~/.hwip/trusted-devices.lock (cli, MCP server): nothing is
# taken, so nothing is lost — the next session start shows it.
cp "$SCRIPT_DIR/fixtures/key-changes.json" "$WORK/home/.hwip/key-changes.json"
printf '%s %s000\n' "$$" "$(date +%s)" > "$WORK/home/.hwip/trusted-devices.lock"
MSG=$(sysmsg HWIP_API_KEY=test-key HWIP_HOOK_ID=test-hook)
assert "lock held → no key-change line"           test -z "$(printf '%s' "$MSG" | grep -F 'changed its encryption key')"
assert "lock held → the record kept"              test -e "$WORK/home/.hwip/key-changes.json"
rm -f "$WORK/home/.hwip/trusted-devices.lock"
MSG=$(sysmsg HWIP_API_KEY=test-key HWIP_HOOK_ID=test-hook)
assert "lock free → shown at the next start"      test -n "$(printf '%s' "$MSG" | grep -F 'Hwip: iPhone changed its encryption key — the new key is trusted. Not expecting that? Check: hwip trust')"
assert "…and the record gone"                    test ! -e "$WORK/home/.hwip/key-changes.json"

echo
echo "[P18: SessionStart keeps the per-session 'Rule 9 given' mark honest]"
# hwip-remote.sh sends a short reminder to a session marked as already given the
# full contract. Compaction (and resume, clear) drops that text from the
# context, so SessionStart has to take the mark back, and set it only when it
# is the one shipping the full contract.
run_hook_sid() {
    local sid="$1"; shift
    printf '{"session_id":"%s","hook_event_name":"SessionStart","source":"compact"}' "$sid" \
      | env -i HOME="$WORK/home" PATH="$PATH" XDG_STATE_HOME="$STATE" \
        CLAUDE_PROJECT_DIR="$PROJECT" "$@" node "$HOOK_SCRIPT" 2>/dev/null \
      | jq -r '.hookSpecificOutput.additionalContext // empty'
}
injected="$STATE/hwip/remote-injected-sess-s1"
state_reset
date +%s > "$STATE/hwip/remote-active-$PROJECT_HASH"
OUT=$(run_hook_sid sess-s1 HWIP_API_KEY=test-key HWIP_HOOK_ID=test-hook)
assert "REMOTE session start ships the contract"   grep -q "State Detection" <<<"$OUT"
assert "…and marks the session as given"           [ -f "$injected" ]
rm -f "$STATE/hwip/remote-active-$PROJECT_HASH"
OUT=$(run_hook_sid sess-s1 HWIP_API_KEY=test-key HWIP_HOOK_ID=test-hook)
assert_not "NORMAL session start has no full contract" grep -q "State Detection" <<<"$OUT"
assert "…and takes the mark back (compact dropped the text)" [ ! -f "$injected" ]
touch "$STATE/hwip/remote-injected-sess-s2"
touch "$STATE/hwip/muted-$PROJECT_HASH"
run_hook_sid sess-s2 HWIP_API_KEY=test-key HWIP_HOOK_ID=test-hook >/dev/null
assert "muted start takes the mark back too"       [ ! -f "$STATE/hwip/remote-injected-sess-s2" ]
rm -f "$STATE/hwip/muted-$PROJECT_HASH"
date +%s > "$STATE/hwip/remote-active-$PROJECT_HASH"
run_hook_sid '../../evil' HWIP_API_KEY=test-key HWIP_HOOK_ID=test-hook >/dev/null
assert "an unsafe session id marks nothing"        [ -z "$(find "$WORK" -name '*evil*')" ]
# Old marks do not pile up: a start prunes ones untouched for a week.
touch -t 202001010000 "$STATE/hwip/remote-injected-old-one"
run_hook_sid sess-s3 HWIP_API_KEY=test-key HWIP_HOOK_ID=test-hook >/dev/null
assert "a week-old mark is pruned"                 [ ! -f "$STATE/hwip/remote-injected-old-one" ]
state_reset
# A prune that fails (here: an old mark that is a directory) must not keep this
# session's own stale mark from being removed.
mkdir "$STATE/hwip/remote-injected-aaa-olddir"; touch -t 202001010000 "$STATE/hwip/remote-injected-aaa-olddir"
touch "$STATE/hwip/remote-injected-sess-s4"
run_hook_sid sess-s4 HWIP_API_KEY=test-key HWIP_HOOK_ID=test-hook >/dev/null
assert "a failing prune does not strand this session's stale mark" [ ! -f "$STATE/hwip/remote-injected-sess-s4" ]
rmdir "$STATE/hwip/remote-injected-aaa-olddir"
# No readable session id: no mark can be addressed, so none survive.
touch "$STATE/hwip/remote-injected-sess-s5"
printf '' | env -i HOME="$WORK/home" PATH="$PATH" XDG_STATE_HOME="$STATE" CLAUDE_PROJECT_DIR="$PROJECT" \
    HWIP_API_KEY=test-key HWIP_HOOK_ID=test-hook node "$HOOK_SCRIPT" >/dev/null 2>&1
assert "no session id → every mark is dropped"     [ ! -f "$STATE/hwip/remote-injected-sess-s5" ]
# Unreadable CORE_RULES.md: the REMOTE contract ships without Rule 9, so the
# session is not 'given' it.
NOCORE="$WORK/nocore"; mkdir -p "$NOCORE/hooks"; cp "$SCRIPT_DIR/../hooks/"*.js "$NOCORE/hooks/"
date +%s > "$STATE/hwip/remote-active-$PROJECT_HASH"
printf '{"session_id":"sess-s6"}' | env -i HOME="$WORK/home" PATH="$PATH" XDG_STATE_HOME="$STATE" CLAUDE_PROJECT_DIR="$PROJECT" \
    HWIP_API_KEY=test-key HWIP_HOOK_ID=test-hook node "$NOCORE/hooks/hwip-setup.js" >/dev/null 2>&1
assert "Rule 9 unreadable → no mark"               [ ! -f "$STATE/hwip/remote-injected-sess-s6" ]
state_reset

echo
echo "=========================================="
echo "Total: $TOTAL  |  Passed: $PASS  |  Failed: $FAIL"
echo "=========================================="
if [ "$FAIL" -gt 0 ]; then
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
    exit 1
fi
