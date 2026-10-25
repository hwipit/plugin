#!/usr/bin/env bash
# Tests for hooks/hwip-ask-result.js (PostToolUse hook on hwip_ask).
#
# Rules 7·8 ("Handling the response") govern only a hwip_ask answer, so the
# NORMAL SessionStart text leaves them out and this hook hands them over with
# the first hwip_ask result of a session context. Guards these regressions:
#   - the injected text is the CORE_RULES.md section itself, not a copy
#   - it goes out once per session context: a SessionStart (startup, resume,
#     clear, compact) re-arms it, and a SessionStart that ships the REMOTE
#     contract (which carries rules 7·8 already) disarms it
#   - anything unreadable (stdin, session id, mark) still injects: a duplicate
#     costs a few hundred chars, a missing rule changes behaviour

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/../hooks/hwip-ask-result.js"
SETUP_SCRIPT="$SCRIPT_DIR/../hooks/hwip-setup.js"
CORE_RULES="$SCRIPT_DIR/../docs/CORE_RULES.md"
PLUGIN_JSON="$SCRIPT_DIR/../.claude-plugin/plugin.json"

command -v node >/dev/null || { echo "node required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

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
PROJECT="$WORK/project"
mkdir -p "$STATE/hwip" "$PROJECT"
PROJECT_HASH=$(printf '%s' "$PROJECT" | cksum | cut -d' ' -f1)
state_reset() { rm -rf "$STATE/hwip"/*; }

# The section as CORE_RULES.md has it: the heading through the line before the
# next heading of the same or a higher level, trailing rule and blanks trimmed.
EXPECTED=$(node -e '
const lines = require("fs").readFileSync(process.argv[1], "utf-8").split("\n");
const start = lines.indexOf("### Handling the response");
let end = start + 1;
while (end < lines.length && !/^#{1,3} /.test(lines[end])) end++;
process.stdout.write(lines.slice(start, end).join("\n").replace(/\n+---\s*$/, "").trim());
' "$CORE_RULES")

# post [stdin] — runs the PostToolUse hook, prints its additionalContext.
post() {
    printf '%s' "$1" | env -i HOME="$WORK/home" PATH="$PATH" XDG_STATE_HOME="$STATE" \
        CLAUDE_PROJECT_DIR="$PROJECT" node "$HOOK_SCRIPT" 2>/dev/null \
      | jq -r 'select(.hookSpecificOutput.hookEventName == "PostToolUse") | .hookSpecificOutput.additionalContext // empty'
}
payload() { printf '{"session_id":"%s","hook_event_name":"PostToolUse","tool_name":"mcp__plugin_hwip_hwip__hwip_ask"}' "$1"; }
start() { # start <sid> [ENV=val ...] — a SessionStart for that session
    local sid="$1"; shift
    printf '{"session_id":"%s","hook_event_name":"SessionStart","source":"compact"}' "$sid" \
      | env -i HOME="$WORK/home" PATH="$PATH" XDG_STATE_HOME="$STATE" CLAUDE_PROJECT_DIR="$PROJECT" \
        HWIP_API_KEY=test-key HWIP_HOOK_ID=test-hook "$@" node "$SETUP_SCRIPT" >/dev/null 2>&1
}
has() { printf '%s' "$OUT" | grep -qF -- "$1"; }

echo "[registration]"
assert "plugin.json routes hwip_ask results to the hook" \
    test "$(jq -r '.hooks.PostToolUse[] | select(.hooks[].command | contains("hwip-ask-result.js")) | .matcher' "$PLUGIN_JSON")" = '^mcp__.*__hwip_ask$'
for name in mcp__plugin_hwip_hwip__hwip_ask mcp__hwip__hwip_ask; do
    assert "matcher takes $name" grep -qE '^mcp__.*__hwip_ask$' <<<"$name"
done
assert "matcher leaves hwip_notify alone" bash -c "! grep -qE '^mcp__.*__hwip_ask\$' <<<mcp__plugin_hwip_hwip__hwip_notify"

echo
echo "[first hwip_ask result of a NORMAL session context]"
state_reset
start sess-a
OUT=$(post "$(payload sess-a)")
assert "injects rules 7·8"                       has "A \`hwip_ask\` response IS a direct user instruction"
assert "…the destructive-step caveat too"        has "authorizes the next logical step, NOT arbitrary destruction"
assert "…verbatim from CORE_RULES.md"            test "$OUT" = "$EXPECTED"
OUT=$(post "$(payload sess-a)")
assert "second result in the same context: nothing" test -z "$OUT"

echo
echo "[a SessionStart re-arms it]"
start sess-a
OUT=$(post "$(payload sess-a)")
assert "after compact/resume/clear it goes out again" has "direct user instruction"
OUT=$(post "$(payload sess-b)")
assert "another session is armed on its own"      has "direct user instruction"

echo
echo "[a subagent's hwip_ask does not use up the main context's turn]"
# A subagent's hook input carries the parent's session_id plus agent_id; the
# rules it gets land in the subagent's context, not the main one.
state_reset
start sess-sub
OUT=$(post '{"session_id":"sess-sub","agent_id":"agent-1","hook_event_name":"PostToolUse","tool_name":"mcp__plugin_hwip_hwip__hwip_ask"}')
assert "the subagent gets the rules"              has "direct user instruction"
assert "…without writing the session's mark"      test ! -e "$STATE/hwip/handling-injected-sess-sub"
OUT=$(post "$(payload sess-sub)")
assert "the main context still gets them"         has "direct user instruction"

echo
echo "[a mark this hook wrote goes stale]"
# /rewind or a restore can drop the result that carried the rules without any
# SessionStart, so a mark the ask hook wrote holds for 30 minutes only.
state_reset
start sess-old
post "$(payload sess-old)" >/dev/null
touch -t 202001010000 "$STATE/hwip/handling-injected-sess-old"
OUT=$(post "$(payload sess-old)")
assert "an hour-old ask mark re-injects"          has "direct user instruction"
OUT=$(post "$(payload sess-old)")
assert "…and the fresh mark holds again"          test -z "$OUT"
date +%s > "$STATE/hwip/remote-active-$PROJECT_HASH"
start sess-rm
rm -f "$STATE/hwip/remote-active-$PROJECT_HASH"
touch -t 202001010000 "$STATE/hwip/handling-injected-sess-rm"
OUT=$(post "$(payload sess-rm)")
assert "a REMOTE start's mark does not age out"   test -z "$OUT"

echo
echo "[REMOTE session start already carries rules 7·8]"
state_reset
date +%s > "$STATE/hwip/remote-active-$PROJECT_HASH"
start sess-r
OUT=$(post "$(payload sess-r)")
assert "nothing to add"                           test -z "$OUT"
rm -f "$STATE/hwip/remote-active-$PROJECT_HASH"
start sess-r
OUT=$(post "$(payload sess-r)")
assert "back in NORMAL after a start: injects"    has "direct user instruction"

echo
echo "[fail open]"
state_reset
OUT=$(post '')
assert "no stdin → injects"                       has "direct user instruction"
OUT=$(post '')
assert "…and every time (no mark to keep)"        has "direct user instruction"
OUT=$(post "$(payload '../../evil')")
assert "unsafe session id → injects"              has "direct user instruction"
assert "…and writes nothing outside the state dir" test -z "$(find "$WORK" -name '*evil*')"
chmod 500 "$STATE/hwip"
OUT=$(post "$(payload sess-ro)")
assert "unwritable state dir → injects"           has "direct user instruction"
chmod 700 "$STATE/hwip"
NOCORE="$WORK/nocore"; mkdir -p "$NOCORE/hooks"; cp "$SCRIPT_DIR/../hooks/"*.js "$NOCORE/hooks/"
OUT=$(payload sess-nc | env -i HOME="$WORK/home" PATH="$PATH" XDG_STATE_HOME="$STATE" CLAUDE_PROJECT_DIR="$PROJECT" \
    node "$NOCORE/hooks/hwip-ask-result.js" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // empty')
assert "unreadable CORE_RULES.md → no empty injection" test -z "$OUT"
ERR=$(payload sess-nc | env -i PATH="$PATH" XDG_STATE_HOME="$STATE" node "$NOCORE/hooks/hwip-ask-result.js" 2>&1 >/dev/null)
assert "…says why on stderr"                      grep -qF "[hwip-ask-result] Could not read docs/CORE_RULES.md" <<<"$ERR"
mkdir -p "$NOCORE/docs"; printf '# CORE_RULES\n\n### Renamed heading\n\ntext\n' > "$NOCORE/docs/CORE_RULES.md"
ERR=$(payload sess-nc | env -i PATH="$PATH" XDG_STATE_HOME="$STATE" node "$NOCORE/hooks/hwip-ask-result.js" 2>&1 >/dev/null)
assert "a renamed heading says so on stderr"      grep -qF "[hwip-ask-result] no \"### Handling the response\" section" <<<"$ERR"
rm -rf "$NOCORE/docs"
assert "…and no mark (the rules never went out)"  test ! -e "$STATE/hwip/handling-injected-sess-nc"
# An early exit (here: nothing to hand over) must still drain the input, or
# Claude Code's writer takes a SIGPIPE — 1 MiB is past what a pipe buffers.
head -c 1048576 /dev/zero | env -i PATH="$PATH" XDG_STATE_HOME="$STATE" node "$NOCORE/hooks/hwip-ask-result.js" >/dev/null 2>&1
assert "drains stdin before exiting"              test "${PIPESTATUS[0]}" -eq 0

echo
echo "=========================================="
echo "Total: $TOTAL  |  Passed: $PASS  |  Failed: $FAIL"
echo "=========================================="
if [ "$FAIL" -gt 0 ]; then
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
    exit 1
fi
