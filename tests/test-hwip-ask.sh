#!/usr/bin/env bash
# Fixture-based tests for hooks/hwip-ask.sh.
#
# hwip-ask is a PreToolUse(AskUserQuestion) hook — it fires when the
# assistant invokes the local AskUserQuestion tool. The hook extracts
# the question text, trims it, and pushes a notification so the user
# knows Claude is waiting even when they're away from the terminal.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/../hooks/hwip-ask.sh"

[ -f "$HOOK_SCRIPT" ] || { echo "hook script not found: $HOOK_SCRIPT" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

WORK=$(mktemp -d)
# The project the hooks run in. It lives under $WORK: a fixed path (it used to be one under /tmp)
# gives every run, and every other session running these tests, the same project hash — and a legacy
# /tmp/hwip-muted-<hash> file left for it silenced 35 of these cases.
TEST_PROJECT="$WORK/test-project"
trap 'rm -rf "$WORK"' EXIT
STUB_DIR="$WORK/stub"
mkdir -p "$STUB_DIR"

cat > "$STUB_DIR/hwip" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$WORK/last-call"
EOF
chmod +x "$STUB_DIR/hwip"

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

# Every runner pins the whole environment the hook reads — HWIP_HOOK_ID, HOME,
# TMUX — rather than inheriting any of it. Each one changes an assertion:
# a hook id routes the question to hwip_ask instead of pushing, and HOME + TMUX
# decide whether the body offers the phone's terminal mirror. Inherited, they
# make these tests pass in CI and fail on the machine of anyone who runs hwip.
run_hook() {
    local input="$1"
    local project_dir="${2:-$TEST_PROJECT}"
    rm -f "$WORK/last-call"
    printf '%s' "$input" \
      | CLAUDE_PROJECT_DIR="$project_dir" PATH="$STUB_DIR:$PATH" \
        XDG_STATE_HOME="$WORK/state" XDG_CACHE_HOME="$WORK/cache" \
        HWIP_HOOK_ID="" HOME="$WORK/no-listener-home" TMUX="" \
        bash "$HOOK_SCRIPT" 2>/dev/null
}

# Runner for the routing path: a hook id exists AND sticky REMOTE is live, so a
# push-shaped question is denied and handed back for hwip_ask. Each call gets
# its own state dir so a replay marker from one case can't allow the next one
# through — which means the REMOTE state has to be seeded per call too.
PROJECT_HASH=$(printf '%s' "$TEST_PROJECT" | cksum | cut -d' ' -f1)

# run_hook_routed <input> [state_dir] [hook_id] [home] — hook_id may be empty
# to make ~/.hwip/config.json under <home> the only source of the id.
run_hook_routed() {
    local input="$1"
    local state_dir="${2:-$(mktemp -d "$WORK/routed-state.XXXXXX")}"
    local hook_id="${3-hook_test_id}" home="${4:-$WORK/no-listener-home}"
    rm -f "$WORK/last-call"
    mkdir -p "$state_dir/hwip"
    date +%s > "$state_dir/hwip/remote-active-$PROJECT_HASH"
    printf '%s' "$input" \
      | CLAUDE_PROJECT_DIR="$TEST_PROJECT" PATH="$STUB_DIR:$PATH" \
        XDG_STATE_HOME="$state_dir" XDG_CACHE_HOME="$WORK/cache" \
        HWIP_HOOK_ID="$hook_id" HOME="$home" TMUX="" \
        bash "$HOOK_SCRIPT" 2>/dev/null
}

# Same, minus the REMOTE state: a hook id on its own must not take the local
# picker away from a user who is demonstrably at the keyboard.
run_hook_normal() {
    local input="$1"
    rm -f "$WORK/last-call"
    printf '%s' "$input" \
      | CLAUDE_PROJECT_DIR="$TEST_PROJECT" PATH="$STUB_DIR:$PATH" \
        XDG_STATE_HOME="$(mktemp -d "$WORK/normal-state.XXXXXX")" XDG_CACHE_HOME="$WORK/cache" \
        HWIP_HOOK_ID="hook_test_id" HOME="$WORK/no-listener-home" TMUX="" \
        bash "$HOOK_SCRIPT" 2>/dev/null
}

# Same as run_hook, but with control over the two signals that decide whether
# the phone can drive this pane: $TMUX and the listener pid file under $HOME.
run_hook_mirror() {
    local input="$1" home="$2" tmux_val="$3"
    rm -f "$WORK/last-call"
    printf '%s' "$input" \
      | CLAUDE_PROJECT_DIR="$TEST_PROJECT" PATH="$STUB_DIR:$PATH" \
        XDG_STATE_HOME="$WORK/state" XDG_CACHE_HOME="$WORK/cache" \
        HOME="$home" TMUX="$tmux_val" HWIP_HOOK_ID="" \
        bash "$HOOK_SCRIPT" 2>/dev/null
}

hwip_called()       { [ -f "$WORK/last-call" ]; }
hwip_silent()       { [ ! -f "$WORK/last-call" ]; }
hwip_body_has()     { [ -f "$WORK/last-call" ] && grep -qF -- "$1" "$WORK/last-call"; }
hwip_title_has()    { [ -f "$WORK/last-call" ] && grep -qF -- "$1" "$WORK/last-call"; }
hwip_body_bytes_le() {
    [ -f "$WORK/last-call" ] || return 1
    local body bytes
    body=$(awk '/^--body=/{sub(/^--body=/, ""); print; exit}' "$WORK/last-call")
    bytes=$(printf '%s' "$body" | wc -c | tr -d ' ')
    [ "$bytes" -le "$1" ]
}
# argv is one word per line and every flag carries its value as `--flag=value`.
hwip_session_is() {
    [ -f "$WORK/last-call" ] || return 1
    local got
    got=$(awk '/^--session=/{sub(/^--session=/, ""); print; exit}' "$WORK/last-call")
    [ "$got" = "$1" ]
}
hwip_no_session()   { [ -f "$WORK/last-call" ] && ! grep -q -- '^--session=' "$WORK/last-call"; }
hwip_priority_is() {
    [ -f "$WORK/last-call" ] || return 1
    local got
    got=$(awk '/^--priority=/{sub(/^--priority=/, ""); print; exit}' "$WORK/last-call")
    [ "$got" = "$1" ]
}

# ── tests ──────────────────────────────────────────────────────────────────

echo "[basic — single .tool_input.question field]"
run_hook '{"tool_input":{"question":"Continue with deployment?"}}'
assert "fires hwip notify"             hwip_called
assert "title prefixed 'Claude asks:'" hwip_title_has "Claude asks:"
assert "body contains question text"   hwip_body_has "Continue with deployment?"

echo
echo "[newer multi-question format — .tool_input.questions[0].question]"
run_hook '{"tool_input":{"questions":[{"question":"Pick one","options":["a","b"]}]}}'
assert "fires hwip notify"             hwip_called
assert "extracts first question"       hwip_body_has "Pick one"

echo
echo "[no question field at all]"
run_hook '{"tool_input":{}}'
assert "fires with fallback text"      hwip_called
assert "body shows 'Question pending'" hwip_body_has "Question pending"

echo
echo "[Korean — UTF-8 safe truncation (≤200 codepoints, never mid-byte)]"
# Build a 250-codepoint Korean string (750 bytes UTF-8).
LONG_KO=$(python3 -c "print('가나다라마바사아자차카타파하 ' * 20)")
run_hook "$(printf '{"tool_input":{"question":"%s"}}' "$LONG_KO")"
assert "fires hwip notify"             hwip_called
# Each Korean char is 3 UTF-8 bytes; 200 codepoints ≈ 600 bytes max.
assert "body stays ≤ 600 bytes (UTF-8 safe)" hwip_body_bytes_le 600

echo
echo "[mute file present — stays silent]"
PROJECT_DIR="$WORK/muted-project"
mkdir -p "$PROJECT_DIR" "$WORK/state/hwip"
MUTE_HASH=$(printf '%s' "$PROJECT_DIR" | cksum | cut -d' ' -f1)
touch "$WORK/state/hwip/muted-$MUTE_HASH"
run_hook '{"tool_input":{"question":"would normally fire"}}' "$PROJECT_DIR"
assert "muted project skips push"      hwip_silent
rm -f "$WORK/state/hwip/muted-$MUTE_HASH"

echo
echo "[user-owned legacy /tmp mute file — stays silent]"
touch "/tmp/hwip-muted-$MUTE_HASH"
run_hook '{"tool_input":{"question":"would normally fire"}}' "$PROJECT_DIR"
assert "legacy mute file still honored" hwip_silent
rm -f "/tmp/hwip-muted-$MUTE_HASH"

echo
echo "[title carries project basename]"
PROJECT_DIR="$WORK/my-fancy-project"
mkdir -p "$PROJECT_DIR"
run_hook '{"tool_input":{"question":"ready?"}}' "$PROJECT_DIR"
assert "title includes project name"   hwip_title_has "my-fancy-project"

echo
echo "[no CLAUDE_PROJECT_DIR — title falls back to the working directory]"
FALLBACK_DIR="$WORK/fallback-project"
mkdir -p "$FALLBACK_DIR"
rm -f "$WORK/last-call"
( cd "$FALLBACK_DIR" \
  && printf '%s' '{"tool_input":{"question":"ready?"}}' \
   | env -u CLAUDE_PROJECT_DIR PATH="$STUB_DIR:$PATH" \
     XDG_STATE_HOME="$WORK/state" XDG_CACHE_HOME="$WORK/cache" \
     HWIP_HOOK_ID="" HOME="$WORK/no-listener-home" TMUX="" \
     bash "$HOOK_SCRIPT" 2>/dev/null )
assert "title names the working directory" hwip_title_has "Claude asks: fallback-project"

echo
echo "[python3 that fails to run — body still carries the question, capped]"
# macOS ships a /usr/bin/python3 stub that exits non-zero until the developer
# tools are installed.
BROKEN_PY="$WORK/broken-python"
mkdir -p "$BROKEN_PY"
printf '#!/bin/sh\nexit 1\n' > "$BROKEN_PY/python3"
chmod +x "$BROKEN_PY/python3"
LONG_Q=$(printf 'QSTART %01000d' 0)
rm -f "$WORK/last-call"
printf '{"tool_input":{"question":"%s"}}' "$LONG_Q" \
  | CLAUDE_PROJECT_DIR="$TEST_PROJECT" PATH="$BROKEN_PY:$STUB_DIR:$PATH" \
    XDG_STATE_HOME="$WORK/state" XDG_CACHE_HOME="$WORK/cache" \
    HWIP_HOOK_ID="" HOME="$WORK/no-listener-home" TMUX="" \
    bash "$HOOK_SCRIPT" 2>/dev/null
assert "body keeps the question"       hwip_body_has "QSTART"
assert "body stays capped"             hwip_body_bytes_le 600

echo
echo "[a question that reads like a flag of the CLI stays one word of the body]"
EVIL_Q='--base-url=http://127.0.0.1:9/evil'
run_hook "$(jq -cn --arg q "$EVIL_Q" '{tool_input:{question:$q}}')"
assert "pushes"                                  hwip_called
assert "the body is a single --body= word"       grep -q -- '^--body=.*--base-url=http://127.0.0.1:9/evil' "$WORK/last-call"
assert_not "no word of its own starts a --base-url" grep -q -- '^--base-url' "$WORK/last-call"
assert "every flag carries its value in one word" bash -c '! grep -qE "^--(title|body|priority|session|type)$" "$1"' _ "$WORK/last-call"

echo
echo "[invalid JSON input — jq fails gracefully]"
run_hook 'not-json-at-all{'
# hwip-ask uses .tool_input.question // .tool_input.questions[0].question // "Question pending"
# but if the input isn't valid JSON, jq returns empty/fails; the hook then
# still calls hwip notify with the fallback "Question pending".
assert "doesn't crash; pushes fallback" hwip_called

echo
echo "[priority — the suppressed blocked twin was high, so this must be too]"
run_hook '{"tool_input":{"question":"ready?"}}'
assert "sends --priority high"           hwip_priority_is "high"

echo
echo "[session id — transcript_path carries the Claude session UUID]"
# The server correlates this push with the listener's `blocked` agent.state push
# by session id; without it the same question notifies twice.
UUID="8f14e45f-ceea-467a-9f43-2b8c1e4f9a01"
run_hook "$(printf '{"transcript_path":"/Users/x/.claude/projects/p/%s.jsonl","tool_input":{"question":"ready?"}}' "$UUID")"
assert "passes --session with the UUID"  hwip_session_is "$UUID"

echo
echo "[session id — absent transcript_path stays unflagged]"
run_hook '{"tool_input":{"question":"ready?"}}'
assert "fires without --session"         hwip_no_session

echo
echo "[session id — falls back to the MCP session cache]"
CACHE_PROJECT="$WORK/cached-project"
mkdir -p "$CACHE_PROJECT" "$WORK/cache/hwip"
CACHE_HASH=$(printf '%s' "$CACHE_PROJECT" | cksum | cut -d' ' -f1)
printf 'sess_abc123\n' > "$WORK/cache/hwip/session-$CACHE_HASH"
run_hook '{"tool_input":{"question":"ready?"}}' "$CACHE_PROJECT"
assert "uses cached session id"          hwip_session_is "sess_abc123"

echo
echo "[session id — tampered cache can't inject argv]"
printf 'sess_abc; rm -rf /\n' > "$WORK/cache/hwip/session-$CACHE_HASH"
run_hook '{"tool_input":{"question":"ready?"}}' "$CACHE_PROJECT"
assert "rejects non-token cache value"   hwip_no_session
rm -f "$WORK/cache/hwip/session-$CACHE_HASH"

echo
echo "[mirror hint — listener alive AND in tmux, so the phone can drive the picker]"
# The picker renders in `tmux capture-pane` and a `send-keys Down` moves the
# selection, so a user on the phone CAN answer it — but only when the listener
# daemon is up and this session sits in a tmux pane. Both signals or neither.
MIRROR_HOME="$WORK/mirror-home"
mkdir -p "$MIRROR_HOME/.hwip"
printf '%s\n' "$$" > "$MIRROR_HOME/.hwip/listener.pid"   # $$ is alive by definition
run_hook_mirror '{"tool_input":{"question":"ready?"}}' "$MIRROR_HOME" '/tmp/tmux-501/default,1,0'
assert "body offers the phone's mirror"      hwip_body_has "terminal mirror"

echo
echo "[mirror hint — outside tmux, no mirror to offer]"
run_hook_mirror '{"tool_input":{"question":"ready?"}}' "$MIRROR_HOME" ''
assert "still points at the terminal"        hwip_body_has "answer at the terminal"
assert_not "makes no mirror claim"           hwip_body_has "terminal mirror"

echo
echo "[mirror hint — in tmux but listener never ran]"
NO_LISTENER_HOME="$WORK/no-listener-home"
mkdir -p "$NO_LISTENER_HOME"
run_hook_mirror '{"tool_input":{"question":"ready?"}}' "$NO_LISTENER_HOME" '/tmp/tmux-501/default,1,0'
assert_not "makes no mirror claim"           hwip_body_has "terminal mirror"

echo
echo "[mirror hint — stale pid file (daemon gone)]"
STALE_HOME="$WORK/stale-home"
mkdir -p "$STALE_HOME/.hwip"
sh -c 'exit 0' & DEAD_PID=$!; wait "$DEAD_PID" 2>/dev/null
printf '%s\n' "$DEAD_PID" > "$STALE_HOME/.hwip/listener.pid"
run_hook_mirror '{"tool_input":{"question":"ready?"}}' "$STALE_HOME" '/tmp/tmux-501/default,1,0'
assert_not "dead pid claims nothing"         hwip_body_has "terminal mirror"

echo
echo "[mirror hint — garbage pid file can't reach kill]"
GARBAGE_HOME="$WORK/garbage-home"
mkdir -p "$GARBAGE_HOME/.hwip"
printf '%s\n' '-1; rm -rf /' > "$GARBAGE_HOME/.hwip/listener.pid"
run_hook_mirror '{"tool_input":{"question":"ready?"}}' "$GARBAGE_HOME" '/tmp/tmux-501/default,1,0'
assert "still pushes"                        hwip_called
assert_not "non-numeric pid claims nothing"  hwip_body_has "terminal mirror"

echo
echo "[routing — a push-shaped question is blocked and handed to hwip_ask]"
OUT=$(run_hook_routed '{"tool_input":{"questions":[{"question":"Apply fix A or B?","options":[{"label":"Apply A"},{"label":"Apply B"}]}]}}')
deny_json_has() { printf '%s' "$OUT" | jq -e "$1" >/dev/null 2>&1; }
assert "emits a PreToolUse deny"       deny_json_has '.hookSpecificOutput.permissionDecision == "deny"'
assert "echoes the hook event name"    deny_json_has '.hookSpecificOutput.hookEventName == "PreToolUse"'
assert "names hwip_ask in the reason"  deny_json_has '.hookSpecificOutput.permissionDecisionReason | test("hwip_ask")'
assert "carries the question verbatim" deny_json_has '.hookSpecificOutput.permissionDecisionReason | test("Apply fix A or B\\?")'
assert "carries the option labels"     deny_json_has '.hookSpecificOutput.permissionDecisionReason | test("Apply A")'
# The model's hwip_ask will push; a notify here would double-send the question.
assert "sends no push of its own"      hwip_silent

echo
echo "[routing — the reason is not truncated like a feed preview]"
LONG_Q=$(python3 -c "print('Should we ' + 'really ' * 30 + 'do it?')")   # ~230 chars, under the 400 limit
OUT=$(run_hook_routed "$(printf '{"tool_input":{"questions":[{"question":"%s","options":[{"label":"Yes"}]}]}}' "$LONG_Q")")
assert "keeps the whole question"      deny_json_has "$(printf '.hookSpecificOutput.permissionDecisionReason | test("do it\\\\?")')"

echo
echo "[routing — carve-out (a): an option preview needs the terminal]"
OUT=$(run_hook_routed '{"tool_input":{"questions":[{"question":"Which layout?","options":[{"label":"A","preview":"+---+\n|   |\n+---+"},{"label":"B"}]}]}}')
assert_not "does not deny"             deny_json_has '.hookSpecificOutput.permissionDecision == "deny"'
assert "falls through to the push"     hwip_called

echo
echo "[routing — carve-out (b): a long option description needs the terminal]"
LONG_D=$(python3 -c "print('detail ' * 40)")   # ~280 chars, over the 240 limit
OUT=$(run_hook_routed "$(printf '{"tool_input":{"questions":[{"question":"Pick","options":[{"label":"A","description":"%s"},{"label":"B"}]}]}}' "$LONG_D")")
assert_not "does not deny"             deny_json_has '.hookSpecificOutput.permissionDecision == "deny"'
assert "falls through to the push"     hwip_called

echo
echo "[routing — no hook id means no hwip_ask to route to]"
run_hook '{"tool_input":{"questions":[{"question":"Apply fix?","options":[{"label":"Yes"}]}]}}'
assert "pushes instead of denying"     hwip_called

echo
echo "[routing — hook id from ~/.hwip/config.json routes too (env is not the only store)]"
CONFIG_HOME="$WORK/config-home"; mkdir -p "$CONFIG_HOME/.hwip"
printf '{"apiKey":"k","hookId":"hook_from_config"}\n' > "$CONFIG_HOME/.hwip/config.json"
OUT=$(run_hook_routed '{"tool_input":{"questions":[{"question":"Apply fix?","options":[{"label":"Yes"}]}]}}' "" "" "$CONFIG_HOME")
assert "denies with a config-only hook id"  deny_json_has '.hookSpecificOutput.permissionDecision == "deny"'
assert "sends no push of its own"           hwip_silent

echo
echo "[routing — a retry gets through so the session cannot be trapped]"
REPLAY_STATE="$WORK/replay-state"
SAME='{"tool_input":{"questions":[{"question":"Proceed?","options":[{"label":"Yes"},{"label":"No"}]}]}}'
OUT=$(run_hook_routed "$SAME" "$REPLAY_STATE")
assert "first attempt is denied"       deny_json_has '.hookSpecificOutput.permissionDecision == "deny"'
OUT=$(run_hook_routed "$SAME" "$REPLAY_STATE")
assert_not "second attempt is allowed" deny_json_has '.hookSpecificOutput.permissionDecision == "deny"'
assert "and pushes as before"          hwip_called

echo
echo "[routing — a different question in the same window is still denied]"
OTHER='{"tool_input":{"questions":[{"question":"Continue?","options":[{"label":"Yes"},{"label":"No"}]}]}}'
OUT=$(run_hook_routed "$OTHER" "$REPLAY_STATE")
assert "no collision with the first"   deny_json_has '.hookSpecificOutput.permissionDecision == "deny"'

echo
echo "[NORMAL — a hook id alone does not take the picker away]"
# The regression this guards: with the deny keyed on HWIP_HOOK_ID alone, a user
# sitting at the terminal in a session nobody ever drove from a phone had every
# AskUserQuestion blocked. REMOTE is the state that makes the picker unreachable.
PICKER='{"tool_input":{"questions":[{"question":"Apply fix A or B?","options":[{"label":"Apply A"},{"label":"Apply B"}]}]}}'
OUT=$(run_hook_normal "$PICKER")
assert_not "not denied outside REMOTE" deny_json_has '.hookSpecificOutput.permissionDecision == "deny"'
assert "and the question still pushes" hwip_called

echo
echo "[routing — input jq cannot read is pushed, not denied]"
# A deny here would block the picker over a question the hook never managed to
# read, leaving the model a reason built from empty strings.
run_hook_routed 'not-json-at-all{'
assert "unmeasurable input still pushes" hwip_called

echo
echo "[routing — the deny path never shells out to the CLI]"
# A stub that fails loudly stands in for the real binary: if the deny path
# called it, the marker file would exist. The undocumented hook-timeout
# behaviour is why this path must not be able to block at all.
cat > "$STUB_DIR/hwip" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$WORK/last-call"
touch "$WORK/cli-was-called"
EOF
chmod +x "$STUB_DIR/hwip"
rm -f "$WORK/cli-was-called"
run_hook_routed '{"tool_input":{"questions":[{"question":"Deploy now?","options":[{"label":"Yes"}]}]}}' >/dev/null
assert "no CLI invocation on deny"     test ! -f "$WORK/cli-was-called"

echo
echo "=========================================="
echo "Total: $TOTAL  |  Passed: $PASS  |  Failed: $FAIL"
echo "=========================================="
if [ "$FAIL" -gt 0 ]; then
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
    exit 1
fi
