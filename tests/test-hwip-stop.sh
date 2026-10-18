#!/usr/bin/env bash
# Fixture-based tests for hooks/hwip-stop.sh.
#
# No external test framework — plain bash with a tiny assert helper.
# Stubs `hwip` on PATH so we can assert on the CLI invocation arguments
# without sending real pushes.
#
# Usage:
#   ./tests/test-hwip-stop.sh           # run from repo root
#   bash tests/test-hwip-stop.sh
#
# Exit code 0 = all pass; non-zero = some failed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/../hooks/hwip-stop.sh"
FIXTURES="$SCRIPT_DIR/fixtures"

[ -f "$HOOK_SCRIPT" ] || { echo "hook script not found: $HOOK_SCRIPT" >&2; exit 1; }

# Ensure required deps for the hook itself
command -v jq >/dev/null     || { echo "jq required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 required" >&2; exit 1; }

# Generate the long-summary fixture if missing
[ -f "$FIXTURES/main-long-summary-ko.jsonl" ] || bash "$FIXTURES/gen-long-summary.sh" >/dev/null

WORK=$(mktemp -d)
# The project the hook runs in unless a case names another. It lives under $WORK: a fixed path
# (it was /tmp) gives every run, and every other session running these tests, the same project
# hash, and so the same legacy /tmp/hwip-pushmode-<hash> and /tmp/hwip-muted-<hash> files — two
# runs at once set each other's push mode under them.
DEFAULT_PROJECT="$WORK/default-project"
# The push-mode tests below write /tmp/hwip-pushmode-<hash of that project>; clean it
# on exit so a failed run never leaves a stray mode set on the machine.
TMP_PUSHMODE="/tmp/hwip-pushmode-$(printf '%s' "$DEFAULT_PROJECT" | cksum | cut -d' ' -f1)"
trap 'rm -rf "$WORK"; rm -f "$TMP_PUSHMODE"' EXIT
STUB_DIR="$WORK/stub"
mkdir -p "$STUB_DIR"

# Stub hwip CLI that records its arguments to a file we can grep.
cat > "$STUB_DIR/hwip" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$WORK/last-call"
EOF
chmod +x "$STUB_DIR/hwip"

# Presence probes (hwip_is_away) — stubbed on PATH ahead of the real ones so a
# run never reads this machine's idle time or tmux server. Each stub logs its
# call to $WORK/probe-calls and answers from a control file; a missing control
# file makes it fail, which is how "no ioreg" / "no tmux server" is modelled.
PROBE_DIR="$WORK/probe"
mkdir -p "$PROBE_DIR"
cat > "$PROBE_DIR/ioreg" <<EOF
#!/bin/bash
echo ioreg >> "$WORK/probe-calls"
[ -f "$WORK/ioreg-idle-ns" ] || exit 1
printf '    | |   "HIDIdleTime" = %s\n' "\$(cat "$WORK/ioreg-idle-ns")"
EOF
cat > "$PROBE_DIR/tmux" <<EOF
#!/bin/bash
echo "tmux \$*" >> "$WORK/probe-calls"
case "\$1" in
    list-clients)     case "\$*" in *client_control_mode*) f="$WORK/tmux-control" ;; *) f="$WORK/tmux-clients" ;; esac ;;
    show-environment) f="$WORK/tmux-ssh" ;;
    display-message)  f="$WORK/tmux-pane" ;;
    *)                exit 1 ;;
esac
[ -f "\$f" ] || exit 1
cat "\$f"
EOF
chmod +x "$PROBE_DIR/ioreg" "$PROBE_DIR/tmux"
# Extra env for the next run_hook (e.g. TMUX=…, HWIP_AWAY_SEC=…).
HOOK_ENV=()

# Assertion plumbing — collected + reported at the end.
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

# Hook invocation helper. Wipes the last-call record, optionally puts
# transcript at a custom path, then pipes the input JSON to the hook.
run_hook() {
    local transcript="$1"
    local project_dir="${2:-$DEFAULT_PROJECT}"
    rm -f "$WORK/last-call"
    echo "{\"transcript_path\":\"$transcript\"}" \
      | env -u TMUX -u TMUX_PANE -u SSH_CONNECTION -u HWIP_AWAY_SEC \
        CLAUDE_PROJECT_DIR="$project_dir" PATH="$PROBE_DIR:$STUB_DIR:$PATH" \
        XDG_STATE_HOME="$WORK/state" ${HOOK_ENV[@]+"${HOOK_ENV[@]}"} \
        bash "$HOOK_SCRIPT" 2>/dev/null
}

# Push-mode helpers — write/clear the per-project push-mode file the hook reads.
# Hash matches the hook's `printf '%s' "$dir" | cksum` keying.
pushmode_file() { printf '/tmp/hwip-pushmode-%s' "$(printf '%s' "${1:-$DEFAULT_PROJECT}" | cksum | cut -d' ' -f1)"; }
set_pushmode()   { printf '%s' "$1" > "$(pushmode_file "${2:-$DEFAULT_PROJECT}")"; }
clear_pushmode() { rm -f "$(pushmode_file "${1:-$DEFAULT_PROJECT}")"; }

hwip_called()   { [ -f "$WORK/last-call" ]; }
hwip_silent()   { [ ! -f "$WORK/last-call" ]; }
hwip_body_has() { [ -f "$WORK/last-call" ] && grep -qF -- "$1" "$WORK/last-call"; }
hwip_body_bytes_gt() {
    [ -f "$WORK/last-call" ] || return 1
    local body bytes
    body=$(awk '/^--body=/{sub(/^--body=/, ""); print; exit}' "$WORK/last-call")
    bytes=$(printf '%s' "$body" | wc -c | tr -d ' ')
    [ "$bytes" -gt "$1" ]
}

# ── tests ──────────────────────────────────────────────────────────────────

# The shipped default with no dial file is `quiet`, so every section that
# exercises the normal-mode heuristic or the Push Signal markers pins the dial
# explicitly — otherwise those cases would all read as "silent because quiet"
# and stop testing what they name. The default itself gets its own section
# below ("push mode: no dial").
set_pushmode normal

echo "[main 2-tool turn — happy path]"
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "fires hwip notify"               hwip_called
assert "body carries assistant summary"  hwip_body_has "all good"
assert "title includes project name"     hwip_body_has "Claude:"

echo
echo "[a last message that reads like a flag of the CLI stays one word of the body]"
# The model's message is untrusted text: as a separate word, `--base-url=…` would be
# a flag of the CLI itself and the API key would go to that host.
EVIL_TRANSCRIPT="$WORK/evil-transcript.jsonl"
sed 's#all good#--base-url=http://127.0.0.1:9/evil#' "$FIXTURES/main-2-tools.jsonl" > "$EVIL_TRANSCRIPT"
run_hook "$EVIL_TRANSCRIPT"
assert "fires hwip notify"                       hwip_called
assert "the evil text is in the body"            hwip_body_has "--base-url=http://127.0.0.1:9/evil"
assert "it sits inside the single --body= word"  grep -q -- '^--body=.*--base-url=http://127.0.0.1:9/evil' "$WORK/last-call"
assert_not "no word of its own starts a --base-url" grep -q -- '^--base-url' "$WORK/last-call"
assert "every flag carries its value in one word" bash -c '! grep -qE "^--(title|body|type|session|priority)$" "$1"' _ "$WORK/last-call"

echo
echo "[main 1-tool turn — below threshold]"
run_hook "$FIXTURES/main-1-tool.jsonl"
assert "stays silent (TOOL_COUNT < 2)"   hwip_silent

echo
echo "[main turn with hwip_ask — dedup]"
run_hook "$FIXTURES/main-with-hwip-ask.jsonl"
assert "stays silent (ALREADY_ASKED > 0)" hwip_silent

echo
echo "[regression: hwip_ask under its real MCP tool name — dedup]"
# Claude Code logs an MCP call under its namespaced name: the plugin's server
# as mcp__plugin_hwip_hwip__hwip_ask, a hand-registered one as
# mcp__hwip__hwip_ask. The bare-name fixture above never matches a real
# transcript, so dedup silently never fired and every ask turn could push twice.
run_hook "$FIXTURES/main-with-hwip-ask-mcp.jsonl"
assert "plugin MCP name stays silent" hwip_silent
run_hook "$FIXTURES/main-with-hwip-ask-mcp-manual.jsonl"
assert "manual MCP name stays silent" hwip_silent

echo
echo "[regression: string-content turn detection]"
# Real Claude Code logs typed user messages with .message.content as a
# STRING (not an array of blocks). is_real_user must still recognise them
# as turn boundaries — otherwise since_last_user falls back to the whole
# transcript and every per-turn check breaks. main-2-tools.jsonl uses
# string-content user messages throughout; this documents the scenario
# explicitly (the happy path above also exercises it).
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "string-content user turn is detected" hwip_called
assert "summary scoped to this turn"          hwip_body_has "all good"

echo
echo "[legacy array-form user message — is_real_user 'or' branch]"
# Older transcripts wrap typed user input in an array carrying a text
# block. is_real_user must keep matching that shape too.
run_hook "$FIXTURES/main-array-user-2-tools.jsonl"
assert "array-form user turn is detected" hwip_called
assert "summary scoped to this turn"      hwip_body_has "legacy array form summary"

echo
echo "[off-by-one regression — turn-2 push must NOT leak turn-1 text]"
# The bug the string-content fix targets: turn 1 ends with a text answer;
# turn 2 does 2 tools and the Stop hook fires before turn 2's final text
# is flushed. Broken scoping → SUMMARY = turn-1 text → the push leaks the
# previous answer. Fixed → scope to turn 2 → empty summary → default body.
run_hook "$FIXTURES/main-stale-summary.jsonl"
assert     "fires (turn-2 crossed the >=2 gate)"   hwip_called
assert_not "body does NOT leak previous turn text" hwip_body_has "PREV_TURN_ANSWER"
assert     "body falls back to default form"       hwip_body_has "tools"

echo
echo "[multi-turn — scoping respects the LAST real user turn]"
# First turn: 5 tools. Second turn: 1 tool. Stop hook runs at the end of
# the second turn — TOOL_COUNT must count only that turn's 1 tool, not
# 5+1=6. With broken string-content detection it would count all 6 and
# wrongly fire.
run_hook "$FIXTURES/main-multi-turn.jsonl"
assert "ignores tool_use from earlier turns" hwip_silent

echo
echo "[subagent transcript — must be skipped]"
SUB_DIR="$WORK/sub/subagents"
mkdir -p "$SUB_DIR"
cp "$FIXTURES/main-2-tools.jsonl" "$SUB_DIR/agent-test.jsonl"
run_hook "$SUB_DIR/agent-test.jsonl"
assert "subagent transcript silenced"    hwip_silent

echo
echo "[observer transcript — must be skipped]"
OBS_DIR="$WORK/projects/-Users-me--claude-mem-observer-sessions"
mkdir -p "$OBS_DIR"
cp "$FIXTURES/main-2-tools.jsonl" "$OBS_DIR/session.jsonl"
run_hook "$OBS_DIR/session.jsonl"
assert "observer transcript silenced"    hwip_silent

echo
echo "[a user project with 'observer' in its path still pushes]"
USER_OBS_DIR="$WORK/projects/-Users-me-code-observer-app"
mkdir -p "$USER_OBS_DIR"
cp "$FIXTURES/main-2-tools.jsonl" "$USER_OBS_DIR/session.jsonl"
run_hook "$USER_OBS_DIR/session.jsonl"
assert "observer-named project fires"    hwip_called

echo
echo "[mute file present — state dir]"
PROJECT_DIR="$WORK/mute-project"
mkdir -p "$PROJECT_DIR" "$WORK/state/hwip"
MUTE_HASH=$(printf '%s' "$PROJECT_DIR" | cksum | cut -d' ' -f1)
touch "$WORK/state/hwip/muted-$MUTE_HASH"
run_hook "$FIXTURES/main-2-tools.jsonl" "$PROJECT_DIR"
assert "muted project skips push"        hwip_silent
rm -f "$WORK/state/hwip/muted-$MUTE_HASH"

echo
echo "[mute file present — user-owned legacy /tmp]"
touch "/tmp/hwip-muted-$MUTE_HASH"
run_hook "$FIXTURES/main-2-tools.jsonl" "$PROJECT_DIR"
assert "legacy mute file still honored"  hwip_silent
rm -f "/tmp/hwip-muted-$MUTE_HASH"

echo
echo "[transcript_path missing — graceful exit]"
rm -f "$WORK/last-call"
echo '{}' | CLAUDE_PROJECT_DIR="$DEFAULT_PROJECT" PATH="$STUB_DIR:$PATH" XDG_STATE_HOME="$WORK/state" bash "$HOOK_SCRIPT" 2>/dev/null
assert "exits cleanly on empty input"    hwip_silent

echo
echo "[transcript file does not exist]"
run_hook "/tmp/nonexistent-hwip-test-transcript-$$.jsonl"
assert "skips when file missing"         hwip_silent

echo
echo "[empty SUMMARY — falls back to 'branch — N tools']"
run_hook "$FIXTURES/main-empty-summary.jsonl"
assert "still fires (≥2 tools, no text)" hwip_called
assert "body falls back to default form" hwip_body_has "tools"

echo
echo "[long Korean summary >512B — triggers CLI file-upload path]"
run_hook "$FIXTURES/main-long-summary-ko.jsonl"
assert "fires hwip notify"               hwip_called
assert "body exceeds 512 bytes"          hwip_body_bytes_gt 512

echo
echo "[trim cap — body never exceeds 5000 codepoints (~15000 bytes for Korean)]"
# Korean 1 char = 3 UTF-8 bytes. 5000 codepoints ≤ 15000 bytes.
run_hook "$FIXTURES/main-long-summary-ko.jsonl"
assert_not "body stays under 15000-byte safety cap" hwip_body_bytes_gt 15000

echo
echo "[B1 read-only floor — turn whose tools are all Read/Grep/Glob → skip]"
# Exploration noise: the #1 false-positive the old ≥2-tool gate produced.
# No marker + every tool read-only → suppress deterministically (no model dep).
run_hook "$FIXTURES/main-readonly-only.jsonl"
assert "read-only-only turn stays silent" hwip_silent

echo
echo "[marker: skip — suppress a turn that WOULD fire]"
# Read+Edit (mixed, crosses every heuristic) but the model tagged it skip.
run_hook "$FIXTURES/main-marker-skip.jsonl"
assert "skip marker silences a ≥2 mixed-tool turn" hwip_silent

echo
echo "[marker: push — force a push the heuristic would skip]"
# Single Bash (force-push): 1 tool < 2 → heuristic stays silent; push marker fires.
run_hook "$FIXTURES/main-marker-push.jsonl"
assert     "push marker fires below the heuristic" hwip_called
assert     "body carries the summary"              hwip_body_has "force-pushed main"
assert_not "marker stripped from body"             hwip_body_has "<!--"

echo
echo "[marker: high — force push at high priority]"
run_hook "$FIXTURES/main-marker-high.jsonl"
assert     "high marker fires"             hwip_called
assert     "push carries --priority flag"  hwip_body_has "--priority"
assert     "priority value is high"        hwip_body_has "high"
assert_not "marker stripped from body"     hwip_body_has "<!--"

echo
echo "[marker: malformed no-space variant — detected AND stripped (leak guard)]"
# `<!--hwip:push-->` (no spaces). Detect and strip share one pattern, so a
# slightly-off marker can never be detected-but-not-stripped → no plaintext leak.
run_hook "$FIXTURES/main-marker-nospace.jsonl"
assert     "no-space push marker still fires"   hwip_called
assert     "body carries the summary"           hwip_body_has "release tag"
assert_not "no-space marker stripped from body" hwip_body_has "<!--"
assert_not "no leftover hwip token in body"     hwip_body_has "hwip:"

echo
echo "[marker: newline-split — NOT a valid marker (detect/strip symmetry)]"
# A marker whose whitespace spans a newline is honoured by NEITHER detect nor
# strip: MARKER_RE uses [[:blank:]] (no newline), so bash's whole-buffer match
# and sed's line-by-line strip agree — it is simply not a marker. Guards against
# the asymmetry where bash detects (fires) a marker sed cannot strip (leak).
# Here a 1-tool turn → no marker detected → heuristic <2 → silent.
run_hook "$FIXTURES/main-marker-newline.jsonl"
assert "newline-split push marker is ignored (1-tool turn stays silent)" hwip_silent

echo
echo "[push mode: quiet — only a high marker survives]"
# User dial (mirrors mute): quiet suppresses every auto-push except high.
set_pushmode quiet
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "quiet suppresses a normal push (mixed-tool turn)" hwip_silent
run_hook "$FIXTURES/main-marker-high.jsonl"
assert     "quiet still lets a high marker through" hwip_called
assert     "high push keeps --priority"            hwip_body_has "--priority"
run_hook "$FIXTURES/main-marker-push.jsonl"
assert "quiet suppresses a plain push marker" hwip_silent
set_pushmode normal

echo
echo "[push mode: loud — push every turn, override skip / <2 / B1]"
set_pushmode loud
run_hook "$FIXTURES/main-1-tool.jsonl"
assert "loud fires on a <2-tool turn"            hwip_called
run_hook "$FIXTURES/main-readonly-only.jsonl"
assert "loud fires on an all-read-only turn"     hwip_called
run_hook "$FIXTURES/main-marker-skip.jsonl"
assert "loud overrides a skip marker"            hwip_called
run_hook "$FIXTURES/main-with-hwip-ask.jsonl"
assert "loud still respects dedup (ask already pushed)" hwip_silent
set_pushmode normal

echo
echo "[push mode: no dial — quiet is the default]"
# A fresh install has no dial file. The hook passes the (empty) dial contents
# straight to hwip_gate_decide, whose 5th-argument default decides. This is the
# behavior every existing install inherits on upgrade, so it is asserted
# directly rather than left to the gate unit tests.
clear_pushmode
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "no dial suppresses a mixed-tool turn" hwip_silent
run_hook "$FIXTURES/main-marker-push.jsonl"
assert "no dial suppresses a plain push marker" hwip_silent
run_hook "$FIXTURES/main-marker-high.jsonl"
assert "no dial still lets a high marker through" hwip_called

echo
echo "[push mode: dial file present but empty — normal, not quiet]"
# An empty dial file is a corrupted dial, not an absent one. Reading it as
# quiet would turn a broken write into silence the user cannot explain, and it
# would also split the two implementations: the TS twin's normalizePushMode('')
# returns normal. The hook substitutes normal before the gate sees it.
printf '' > "$(pushmode_file)"
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "empty dial falls back to the normal heuristic" hwip_called
clear_pushmode

echo
echo "[push mode: project hash unavailable — normal, not quiet]"
# Without `cksum` the hook cannot key any state file, so it cannot find a dial
# even if one exists. That is a broken environment, not a user who left the dial
# alone, and the quiet default must not absorb it — the TS twin's readPushMode
# returns `normal` for the same failure (`if (!hash) return 'normal'`), and
# silence is the one symptom the user cannot tell apart from working correctly.
cat > "$STUB_DIR/cksum" <<'CKSUM'
#!/bin/bash
exit 127
CKSUM
chmod +x "$STUB_DIR/cksum"
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "an unhashable project falls back to the normal heuristic" hwip_called
run_hook "$FIXTURES/main-readonly-only.jsonl"
assert "and the normal heuristic still applies its floors" hwip_silent
rm -f "$STUB_DIR/cksum"

echo
echo "[push mode: global default — /hwip-mode quiet --global]"
# `pushmode-default` is the machine-wide fallback, consulted only when the
# project has no dial of its own (state dir or legacy /tmp).
mkdir -p "$WORK/state/hwip"
printf 'quiet' > "$WORK/state/hwip/pushmode-default"
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "global quiet suppresses a normal push"          hwip_silent
run_hook "$FIXTURES/main-marker-high.jsonl"
assert "global quiet still lets a high marker through"  hwip_called
# A per-project dial outranks it — that's how /hwip-mode normal opts one project out.
GLOBAL_PROJECT="$WORK/global-project"
mkdir -p "$GLOBAL_PROJECT"
GP_HASH=$(printf '%s' "$GLOBAL_PROJECT" | cksum | cut -d' ' -f1)
printf 'normal' > "$WORK/state/hwip/pushmode-$GP_HASH"
run_hook "$FIXTURES/main-2-tools.jsonl" "$GLOBAL_PROJECT"
assert "project dial overrides the global default"      hwip_called
rm -f "$WORK/state/hwip/pushmode-default" "$WORK/state/hwip/pushmode-$GP_HASH"

echo
echo "[mute has no global default — project-only by design]"
# Mute is presence-keyed, so a global mute file could never be lifted for a
# single project. Only `pushmode` falls back to `-default`; lock that here.
set_pushmode normal
touch "$WORK/state/hwip/muted-default"
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "muted-default does not silence an unmuted project" hwip_called
rm -f "$WORK/state/hwip/muted-default"

echo
echo "[exit marker clears sticky REMOTE — including on the silent quiet path]"
# The free-text exit is the one signal the server cannot see, so the model
# marks it and this hook acts on it. It has to work on a stock quiet install,
# where the gate returns silent and everything after it never runs.
remote_state_file() { printf '%s/state/hwip/remote-active-%s' "$WORK" "$(printf '%s' "${1:-$DEFAULT_PROJECT}" | cksum | cut -d' ' -f1)"; }
clear_pushmode
mkdir -p "$WORK/state/hwip"
date +%s > "$(remote_state_file)"
run_hook "$FIXTURES/main-marker-exit.jsonl"
assert "no push on the quiet default"  hwip_silent
assert "REMOTE state cleared anyway"   [ ! -f "$(remote_state_file)" ]

echo
echo "[exit marker never leaks into the push body]"
set_pushmode loud
date +%s > "$(remote_state_file)"
run_hook "$FIXTURES/main-marker-exit.jsonl"
assert     "pushes (loud)"                hwip_called
assert     "body keeps the real summary"  hwip_body_has "Cleaned up the scratch files."
assert_not "body does not carry the raw marker"  hwip_body_has "hwip: exit"
assert     "REMOTE state cleared"         [ ! -f "$(remote_state_file)" ]
clear_pushmode

echo
echo "[no exit marker leaves sticky REMOTE alone]"
set_pushmode loud
date +%s > "$(remote_state_file)"
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "REMOTE state untouched"  [ -f "$(remote_state_file)" ]
rm -f "$(remote_state_file)"
clear_pushmode

# ── away: quiet still pushes when the user has left the terminal ───────────
#
# hwip_is_away probes, in order: inside tmux with no client attached anywhere
# → away; a readable HIDIdleTime (not over SSH) decides alone; otherwise, inside
# tmux, the newest client_activity. Probes that fail or are absent read as
# present.

NOW=$(date +%s)
reset_probes() { rm -f "$WORK/probe-calls" "$WORK/ioreg-idle-ns" "$WORK/tmux-clients" "$WORK/tmux-ssh" "$WORK/tmux-pane" "$WORK/tmux-control"; HOOK_ENV=(); }
pane_is()      { printf '%s\n' "$1" > "$WORK/tmux-pane"; }
tmux_ssh()     { printf '%s\n' "$1" > "$WORK/tmux-ssh"; }
probes_ran()   { [ -s "$WORK/probe-calls" ]; }
in_tmux()      { HOOK_ENV+=("TMUX=/tmp/tmux-test/default,1,0" "TMUX_PANE=%1"); }
clients()      { printf '%s\n' "$@" > "$WORK/tmux-clients"; }
hid_idle()     { printf '%s' "$(( $1 * 1000000000 ))" > "$WORK/ioreg-idle-ns"; }
priority_high() { [ -f "$WORK/last-call" ] && grep -qx -- "--priority=high" "$WORK/last-call"; }

set_pushmode quiet

echo
echo "[away: no probe answers — present, quiet stays silent]"
reset_probes
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "silent when presence cannot be read"  hwip_silent

echo
echo "[away: HID idle past the threshold — push at normal priority]"
reset_probes; hid_idle 400
run_hook "$FIXTURES/main-2-tools.jsonl"
assert     "push fired"                       hwip_called
assert_not "not escalated to high"            priority_high

echo
echo "[away: HID idle below the threshold — silent]"
reset_probes; hid_idle 5
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "silent while the user is typing"      hwip_silent

echo
echo "[away: a read-only turn still pushes when away (user decision)]"
reset_probes; hid_idle 400
run_hook "$FIXTURES/main-readonly-only.jsonl"
assert "read-only turn pushes"                hwip_called

echo
echo "[away: HWIP_AWAY_SEC tunes the threshold, 0 disables]"
reset_probes; hid_idle 100; HOOK_ENV+=("HWIP_AWAY_SEC=60")
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "100s idle is away at a 60s threshold" hwip_called
reset_probes; hid_idle 100000; HOOK_ENV+=("HWIP_AWAY_SEC=0")
run_hook "$FIXTURES/main-2-tools.jsonl"
assert     "0 disables away detection"        hwip_silent
assert_not "0 does not even probe"            probes_ran
reset_probes; hid_idle 400; HOOK_ENV+=("HWIP_AWAY_SEC=soon")
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "a non-numeric threshold falls back to 300s" hwip_called
reset_probes; hid_idle 200; HOOK_ENV+=("HWIP_AWAY_SEC=soon")
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "…so 200s is still present"            hwip_silent
reset_probes; hid_idle 400; HOOK_ENV+=("HWIP_AWAY_SEC=99999999999999999999")
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "an overflowing threshold falls back to 300s" hwip_called

echo
echo "[away: in tmux with no client attached anywhere — away]"
reset_probes; in_tmux; : > "$WORK/tmux-clients"; hid_idle 1
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "detached tmux server pushes even with fresh HID input" hwip_called

echo
echo "[away: in tmux but the server does not answer — present, not detached]"
reset_probes; in_tmux
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "a failed list-clients is not an empty one" hwip_silent

echo
echo "[away: readable HID wins over a stale tmux client (user in another app)]"
reset_probes; in_tmux; clients "$((NOW - 3600))"; hid_idle 5
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "silent — HID says present"            hwip_silent

echo
echo "[away: no HID (non-macOS) — tmux activity decides]"
reset_probes; in_tmux; clients "$((NOW - 3600))"
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "stale client → away"                  hwip_called

echo
echo "[away: over SSH the local HID is ignored, tmux activity decides]"
reset_probes; in_tmux; HOOK_ENV+=("SSH_CONNECTION=10.0.0.1 22 10.0.0.2 22"); hid_idle 5
clients "$((NOW - 3600))" "$((NOW - 7200))"
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "stale newest client → away"           hwip_called
reset_probes; in_tmux; HOOK_ENV+=("SSH_CONNECTION=10.0.0.1 22 10.0.0.2 22"); hid_idle 9999
clients "$((NOW - 3600))" "$((NOW - 2))"
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "one fresh client → present"           hwip_silent

echo
echo "[away: inside tmux the session environment decides SSH, not the frozen process env]"
reset_probes; in_tmux; HOOK_ENV+=("SSH_CONNECTION=10.0.0.1 22 10.0.0.2 22"); tmux_ssh "-SSH_CONNECTION"
hid_idle 5; clients "$((NOW - 3600))"
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "attached locally (tmux unset it) → HID decides, present" hwip_silent
reset_probes; in_tmux; tmux_ssh "SSH_CONNECTION=10.0.0.1 22 10.0.0.2 22"
hid_idle 5; clients "$((NOW - 3600))"
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "attached over SSH → HID ignored, stale client is away" hwip_called
reset_probes; in_tmux; tmux_ssh "SSH_CONNECTION=10.0.0.1 22 10.0.0.2 22"
hid_idle 9999; clients "$((NOW - 2))"
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "attached over SSH → a fresh client is present despite HID idle" hwip_silent

echo
echo "[away: a session nobody is looking at is away, whoever sits at the machine (P25)]"
# hwip_presence is the machine's: a keyboard or a tmux client says the user is at
# the desk, not which tmux session they are looking at. hwip_pane_visible asks
# about THIS session's pane; hidden reads as away, unknown (no answer, odd output,
# iTerm2 -CC, not in tmux) narrows nothing — an unreadable signal never adds a push.
reset_probes; in_tmux; clients "$NOW"; hid_idle 1; pane_is "1 1 1 0"
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "the pane on screen, user typing → silent"          hwip_silent
pane_is "0 1 1 0"
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "session with no client attached → push"            hwip_called
pane_is "1 0 1 0"
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "another window showing, user typing → push"        hwip_called
pane_is "1 1 0 1"
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "a different pane zoomed over it → push"            hwip_called
pane_is "1 1 0 0"
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "an inactive split that is still on screen → silent" hwip_silent
pane_is "1 1 1 1"
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "this pane zoomed is the one on screen → silent"    hwip_silent
pane_is "garbage"
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "an answer that is not four numbers → silent"       hwip_silent
pane_is "0 1 1"
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "a missing field is unknown, not a shifted read → silent" hwip_silent
rm -f "$WORK/tmux-pane"
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "tmux will not answer for the pane → silent"        hwip_silent
pane_is "1 0 1 0"; printf '0\n1\n' > "$WORK/tmux-control"
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "iTerm2 -CC client: a non-current window may be on screen → silent" hwip_silent
printf '0\n' > "$WORK/tmux-control"
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "ordinary clients only → hidden → push"             hwip_called
reset_probes; clients "$NOW"; hid_idle 1; pane_is "0 1 1 0"; HOOK_ENV+=("TMUX=/tmp/tmux-test/default,1,0")
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "no TMUX_PANE (cannot name the pane) → silent"      hwip_silent
reset_probes; hid_idle 1; pane_is "0 1 1 0"
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "outside tmux the pane is never asked → silent"     hwip_silent
reset_probes; in_tmux; clients "$NOW"; hid_idle 1; pane_is "0 1 1 0"; HOOK_ENV+=("HWIP_AWAY_SEC=0")
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "HWIP_AWAY_SEC=0 disables the pane check too → silent" hwip_silent
reset_probes; in_tmux; : > "$WORK/tmux-clients"; pane_is "0 1 1 0"
run_hook "$FIXTURES/main-2-tools.jsonl"
assert "no client anywhere answers alone: the pane is not asked" hwip_called
assert_not "…no display-message call" grep -q display-message "$WORK/probe-calls"
reset_probes; in_tmux; clients "$NOW"; hid_idle 1; pane_is "0 1 1 0"
run_hook "$FIXTURES/main-readonly-only.jsonl"
assert "a read-only turn on a hidden pane still pushes (same as away)" hwip_called
reset_probes; in_tmux; clients "$NOW"; hid_idle 1; pane_is "0 1 1 0"
run_hook "$FIXTURES/main-marker-skip.jsonl"
assert "a skip marker is a normal-mode marker: quiet pushes it on a hidden pane, as it does when away" hwip_called

echo
echo "[away: probes only run when quiet would otherwise be silent]"
reset_probes; hid_idle 400
run_hook "$FIXTURES/main-marker-high.jsonl"
assert_not "high marker needs no probe"       probes_ran
set_pushmode normal
reset_probes; hid_idle 400
run_hook "$FIXTURES/main-2-tools.jsonl"
assert_not "normal mode never probes"         probes_ran
set_pushmode loud
reset_probes; hid_idle 400
run_hook "$FIXTURES/main-1-tool.jsonl"
assert_not "loud mode never probes"           probes_ran
reset_probes
clear_pushmode

# ── late flush: wait for the turn's FINAL text, not just any text ─────────

echo
echo "[late flush — mid-turn text present, final text with a high marker lands late]"
# The transcript ends on a tool_result, with a line of text written between the
# tool calls. The final text (carrying the marker) is appended once the hook
# first sleeps — after its first read, inside the marker wait. A stub `sleep`
# signals that, so the test never races hook startup. Waiting only on EMPTY
# text never sleeps here: it reads the mid-turn line, misses the marker and
# stays silent under the quiet default (the writer gives up after 5 s).
clear_pushmode
SLEEP_DIR="$WORK/sleep-stub"
mkdir -p "$SLEEP_DIR"
REAL_SLEEP=$(command -v sleep)
cat > "$SLEEP_DIR/sleep" <<STUB
#!/bin/bash
echo slept >> "$WORK/hook-sleeps"
exec "$REAL_SLEEP" "\$@"
STUB
chmod +x "$SLEEP_DIR/sleep"
rm -f "$WORK/hook-sleeps"
# Blocks until the hook has slept $1 times (or 5 s pass).
await_sleeps() {
    local i=0
    while [ "$(cat "$WORK/hook-sleeps" 2>/dev/null | wc -l | tr -d ' ')" -lt "$1" ] && [ "$i" -lt 50 ]; do
        sleep 0.1; i=$((i + 1))
    done
}
LATE="$WORK/late-flush.jsonl"
cat > "$LATE" <<'JSONL'
{"type":"user","message":{"role":"user","content":"배포 돌려줘"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"MIDTURN_NOTE checking the config first"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"a","name":"Bash","input":{"command":"npm run deploy"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"a","content":"deployed"}]}}
JSONL
( await_sleeps 1
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"FINAL_TEXT production is live. <!-- hwip: high -->"}],"stop_reason":"end_turn"}}' >> "$LATE" ) &
HOOK_ENV=(PATH="$SLEEP_DIR:$PROBE_DIR:$STUB_DIR:$PATH")
run_hook "$LATE"
HOOK_ENV=()
wait
body_lacks() { hwip_called && ! hwip_body_has "$1"; }
assert "late high marker is seen"          hwip_body_has "--priority"
assert "body is the final text"            hwip_body_has "FINAL_TEXT"
assert "body is not the mid-turn text"     body_lacks "MIDTURN_NOTE"
set_pushmode normal

echo
echo "[late flush — a skip marker that lands during the body wait still cancels]"
# The marker wait sleeps 3 times; the final text lands on the 4th sleep, in the
# body wait that only runs once a push is committed. The gate re-runs on it.
# Two non-read-only tools, so normal mode would push without the marker.
cat > "$LATE" <<'JSONL'
{"type":"user","message":{"role":"user","content":"설정 확인해줘"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"a","name":"Bash","input":{"command":"ls"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"a","content":"ok"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"b","name":"Edit","input":{"file_path":"a"}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"b","content":"ok"}]}}
JSONL
rm -f "$WORK/hook-sleeps"
( await_sleeps 4
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"just a probe. <!-- hwip: skip -->"}],"stop_reason":"end_turn"}}' >> "$LATE" ) &
HOOK_ENV=(PATH="$SLEEP_DIR:$PROBE_DIR:$STUB_DIR:$PATH")
run_hook "$LATE"
HOOK_ENV=()
wait
assert "late skip marker silences the push" hwip_silent

# ── P12: the transcript tail is bounded in bytes, and quiet skips the parse ──
#
# `jq -s` parses everything it is fed. The tail was bounded in lines only
# (2000), so a session with large tool results fed it tens of MB on every Stop.
# A `jq` stub on PATH records how many bytes each call was given.

JQ_DIR="$WORK/jq-stub"
mkdir -p "$JQ_DIR"
REAL_JQ=$(command -v jq)
cat > "$JQ_DIR/jq" <<STUB
#!/bin/bash
if [ -t 0 ]; then exec "$REAL_JQ" "\$@"; fi
f=\$(mktemp)
cat > "\$f"
wc -c < "\$f" | tr -d ' ' >> "$WORK/jq-bytes"
"$REAL_JQ" "\$@" < "\$f"
rc=\$?
rm -f "\$f"
exit \$rc
STUB
chmod +x "$JQ_DIR/jq"
# The biggest input any one jq call got (a turn makes several passes, each over the window).
jq_max() { awk '$1 > m { m = $1 } END { print m + 0 }' "$WORK/jq-bytes" 2>/dev/null || echo 0; }
jq_max_le() { [ "$(jq_max)" -le "$1" ]; }
# make_big FILE TOOLS BYTES_PER_RESULT FINAL_TEXT — a turn of TOOLS Bash calls whose
# results are BYTES_PER_RESULT each, ending on a flushed assistant text.
make_big() {
    python3 - "$@" <<'PY'
import json, sys
path, tools, size, final = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
pad = 'x' * size
with open(path, 'w') as f:
    f.write(json.dumps({"type": "user", "message": {"role": "user", "content": "go"}}) + "\n")
    for i in range(tools):
        f.write(json.dumps({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": str(i), "name": "Bash", "input": {"command": "ls"}}]}}) + "\n")
        f.write(json.dumps({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": str(i), "content": pad}]}}) + "\n")
    f.write(json.dumps({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": final}], "stop_reason": "end_turn"}}) + "\n")
PY
}
BIG="$WORK/big.jsonl"
CAP=$((8 * 1024 * 1024))

echo
echo "[P12: quiet and at the terminal — a plain turn is judged from a small window]"
make_big "$BIG" 40 400000 "all done."          # ~16 MiB
set_pushmode quiet; reset_probes; rm -f "$WORK/jq-bytes"
HOOK_ENV=(PATH="$JQ_DIR:$PROBE_DIR:$STUB_DIR:$PATH")
run_hook "$BIG"
HOOK_ENV=()
assert "silent, as before"                      hwip_silent
assert "no jq call saw over 1 MiB of a 16 MiB file" jq_max_le 1048576

echo
echo "[P12: a high marker is still found on a huge transcript]"
make_big "$BIG" 40 400000 "shipped. <!-- hwip: high -->"
reset_probes; rm -f "$WORK/jq-bytes"
HOOK_ENV=(PATH="$JQ_DIR:$PROBE_DIR:$STUB_DIR:$PATH")
run_hook "$BIG"
HOOK_ENV=()
assert "high marker pushes"                     hwip_called
assert "at high priority"                       priority_high
assert "jq input bounded by the byte cap"       jq_max_le "$CAP"

echo
echo "[P12: the byte cap holds for the other dials]"
make_big "$BIG" 40 400000 "all done."
set_pushmode normal; reset_probes; rm -f "$WORK/jq-bytes"
HOOK_ENV=(PATH="$JQ_DIR:$PROBE_DIR:$STUB_DIR:$PATH")
run_hook "$BIG"
HOOK_ENV=()
assert "normal still counts the tools and pushes" hwip_called
assert "body is the final text"                 hwip_body_has "all done."
assert "jq input bounded by the byte cap"       jq_max_le "$CAP"
set_pushmode quiet; reset_probes; hid_idle 400; rm -f "$WORK/jq-bytes"
HOOK_ENV=(PATH="$JQ_DIR:$PROBE_DIR:$STUB_DIR:$PATH")
run_hook "$BIG"
HOOK_ENV=()
assert "quiet but away still pushes"            hwip_called
assert "jq input bounded by the byte cap"       jq_max_le "$CAP"

echo
echo "[P12: an exit marker is still acted on while quiet and present]"
make_big "$BIG" 40 400000 "all wrapped up. <!-- hwip: exit -->"
set_pushmode quiet; reset_probes
mkdir -p "$WORK/state/hwip"; date +%s > "$(remote_state_file)"
run_hook "$BIG"
assert "no push"                                hwip_silent
assert "REMOTE state cleared"                   [ ! -f "$(remote_state_file)" ]
rm -f "$(remote_state_file)" "$BIG"
reset_probes
set_pushmode normal

# ── project name fallback ────────────────────────────────────────────────────

echo
echo "[no CLAUDE_PROJECT_DIR — title falls back to the working directory]"
FALLBACK_DIR="$WORK/fallback-project"
mkdir -p "$FALLBACK_DIR"
rm -f "$WORK/last-call"
( cd "$FALLBACK_DIR" \
  && echo "{\"transcript_path\":\"$FIXTURES/main-marker-high.jsonl\"}" \
   | env -u CLAUDE_PROJECT_DIR -u TMUX -u TMUX_PANE -u SSH_CONNECTION -u HWIP_AWAY_SEC \
     PATH="$PROBE_DIR:$STUB_DIR:$PATH" XDG_STATE_HOME="$WORK/state" \
     bash "$HOOK_SCRIPT" 2>/dev/null )
assert "title names the working directory" hwip_body_has "Claude: fallback-project"

# ── python3 present but broken ───────────────────────────────────────────────

echo
echo "[python3 that fails to run — body keeps the summary]"
# macOS ships a /usr/bin/python3 stub that exits non-zero until the developer
# tools are installed.
BROKEN_PY="$WORK/broken-python"
mkdir -p "$BROKEN_PY"
printf '#!/bin/sh\nexit 1\n' > "$BROKEN_PY/python3"
chmod +x "$BROKEN_PY/python3"
HOOK_ENV=(PATH="$BROKEN_PY:$PROBE_DIR:$STUB_DIR:$PATH")
run_hook "$FIXTURES/main-2-tools.jsonl"
HOOK_ENV=()
assert "summary survives a failing python3" hwip_body_has "all good"

# ── summary ────────────────────────────────────────────────────────────────

echo
echo "=========================================="
echo "Total: $TOTAL  |  Passed: $PASS  |  Failed: $FAIL"
echo "=========================================="
if [ "$FAIL" -gt 0 ]; then
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
    exit 1
fi
