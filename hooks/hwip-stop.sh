#!/usr/bin/env bash
# Stop hook — push a completion notification once Claude finishes a response.
# A Push Signal marker in the response (`<!-- hwip: skip|push|high -->`) overrides
# the default; absent one, the turn pushes only if it did real work — ≥2 tool
# calls AND not all read-only (Read/Grep/Glob). Stays silent when:
#   - the project is muted
#   - jq is not installed
#   - the response already sent a hwip_ask (avoid duplicates)
#   - a `skip` marker, or the no-marker heuristic above, says so
#   - the dial is quiet (and this turn has no `high` marker, and the
#     user is at the terminal — see hwip_is_away)
# The user can also force a push every turn with /hwip-mode loud.

# `$SECONDS` is this run's clock: the deadlines below are readings of it.
SECONDS=0

# Drain stdin before any exit: returning while Claude Code is still writing the
# hook input leaves the writer to take a SIGPIPE.
INPUT=$(cat)

command -v jq >/dev/null 2>&1 || exit 0

# Shared hook library: the pure gate decision (parity-locked to the CLI via
# tests/fixtures/gate-vectors.json) plus state-file + CLI-bounding helpers.
. "$(dirname "${BASH_SOURCE[0]}")/gate.sh"

# ── Time budget ──────────────────────────────────────────────────────────────
# plugin.json gives this hook 10 s and Claude Code kills it at the cap, taking the
# push with it. Every wait below has its own bound, and they add up: a tmux that
# answers each probe just inside its 2 s bound cost 7.4 s per hwip_is_away and ~15 s
# through the hook's two calls (measured 2026-10-04, stub tmux sleeping 1.8 s per
# call). So the run keeps two deadlines, both readings of `$SECONDS` (whole
# wall-clock seconds, so a reading is off by up to one):
#   - presence probes (hwip_probe_cmd in gate.sh) start only while < 4 s have passed
#     and are cut to what is left; the last one may end just past 4 s, before 5.
#   - the push CLI gets what is left of 8 s (see below), so the hook ends before 9 s,
#     leaving a second for shell start and exit under the 10 s cap.
# A probe the deadline skips or cuts answers nothing, exactly like a tmux that never
# answers: presence unknown, which hwip_is_away reads as present — quiet then stays
# silent. That is the same rule as every other unreadable signal: no evidence the user
# left never adds a push. The cost is a completion push lost for an away user whose
# tmux is too slow to say so inside 4 s; an answer that came in time still counts.
# The probe is asked at most once per run (hook_is_away), so a verdict the first call
# reached is not re-asked against an already spent deadline.
HWIP_HOOK_BUDGET_SEC=8
HWIP_PROBE_DEADLINE=4

# Claude Code sets CLAUDE_PROJECT_DIR; a hook run without it falls back to the
# working directory for both the state key and the push title.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
MUTE_HASH=$(printf '%s' "$PROJECT_DIR" | cksum | cut -d' ' -f1)

hwip_state_present muted "$MUTE_HASH" >/dev/null && exit 0

# hwip_is_away, asked once per run: rc 0 away, rc 1 present or unreadable.
AWAY_CACHE=""
hook_is_away() {
    if [ -z "$AWAY_CACHE" ]; then
        if hwip_is_away; then AWAY_CACHE=1; else AWAY_CACHE=0; fi
    fi
    [ "$AWAY_CACHE" = 1 ]
}

# User push-mode dial (a level above the model's per-turn Push Signal marker):
#   quiet — suppress every auto-push except a `high` marker, or a user who is
#           away from the terminal (hwip_is_away in gate.sh)
#   loud  — push every turn, overriding skip / <2-tool / read-only
#   normal — the marker + heuristic gate decides
# No dial at all → quiet, the shipped default. Set via the
# /hwip-mode skill (scripts/hwip-mode.sh), which also sets mute. Resolution
# (including what a broken or unreadable dial means) lives in gate.sh alongside
# its TS twin's — see hwip_read_pushmode.
PUSHMODE=$(hwip_read_pushmode "$MUTE_HASH")

TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')

if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
    exit 0
fi

# Claude Code invokes the Stop hook for every Claude-CLI-driven session that
# terminates — not just the main interactive turn. That includes:
#   - Sub-agents spawned via the Task tool. Their transcripts live under
#     <project>/<session-uuid>/subagents/agent-<id>.jsonl. They typically
#     run many internal tool calls, so they always pass the >=2 gate and
#     fire a spurious push at the end of an interactive turn that used
#     Task at all.
#   - Background observer sessions (e.g. claude-mem) that record memory
#     by spinning up their own short Claude sessions. Their transcripts
#     have project-hash paths like `-Users-.--claude-mem-observer-sessions/`
#     and fire constantly, producing pushes when the user is doing nothing.
#     Only that directory is matched: a bare *observer* glob also silenced
#     every user project with "observer" anywhere in its path.
# Skip both — we only want the *main* interactive turn ending.
case "$TRANSCRIPT" in
    */subagents/*)                    exit 0 ;;
    *-claude-mem-observer-sessions/*) exit 0 ;;
esac

# Bound every jq pass to the transcript tail. `jq -s` parses the whole input, so
# on a long session each Stop turn paid O(session length) — and up to ~10
# passes on a slow-flush pushing turn. One turn's entries fit comfortably in
# the last 2000 lines; if the last real user message falls outside the window
# (a gigantic turn), since_last_user's null fallback treats the window as the
# turn, and the entries that drive every decision (tool tallies, last
# assistant text) live at the tail anyway.
#
# Lines alone do not bound it: a screenshot or a huge tool result is one line
# of megabytes, and 2000 of those fed jq tens of MB per Stop (the hook's own
# timeout is 10 s). The window is also capped in bytes. A byte cut can land
# mid-line, which jq -s would reject as a whole, so a cut window drops its first
# line. The cost is a turn made of a few huge results losing its earliest tool
# calls from the tally; 8 MiB keeps every ordinary turn whole.
TAIL_LINES=2000
TAIL_BYTES=$((8 * 1024 * 1024))
# tail_window LINES BYTES — the last LINES lines of the transcript, at most BYTES
# bytes, always starting on a line boundary.
tail_window() {
    local size
    size=$(wc -c < "$TRANSCRIPT" 2>/dev/null | tr -d ' ')
    if [ "${size:-0}" -gt "$2" ]; then
        tail -c "$2" "$TRANSCRIPT" 2>/dev/null | sed '1d' | tail -n "$1"
    else
        tail -n "$1" "$TRANSCRIPT" 2>/dev/null
    fi
}
read_tail() { tail_window "$TAIL_LINES" "$TAIL_BYTES"; }

# Scope all checks to "entries since the last *real* user message" — Claude
# Code logs tool_results as synthetic user messages, so a naive
# role=="user" filter would slice mid-turn.
#
# What counts as a *real* user turn:
#   - A message the user typed. Current Claude Code logs these with
#     `.message.content` as a plain STRING. Older transcripts used an
#     array carrying a {"type":"text"} block. Both forms count.
#   - A tool_result is also a user-role message, but its content is an
#     array of tool_result blocks with no text block — it does NOT count.
#
# Defensive note: system prompts and meta events also carry STRING
# content. `content_blocks` guards every array access with
# `type == "array"` so `map(.type)` never crashes on a string ("Cannot
# iterate over string", which would silently kill the Stop hook).
#
# History: 0.5.1 added that string guard to stop the crash, but routed
# is_real_user through `content_blocks` too. Once Claude Code switched
# typed user messages to string content, the guard turned every real
# turn into [] — is_real_user never matched, since_last_user silently
# fell back to the whole transcript, and per-turn scoping died (stale
# summaries, cumulative tool counts). is_real_user now treats non-empty
# string content as a real turn directly.
JQ_SINCE_USER='
def content_blocks:
    .message?.content as $c
    | if ($c | type) == "array" then $c else [] end;
def is_real_user:
    .message?.role == "user"
    and (
        ((.message?.content | type) == "string"
         and (.message?.content | length) > 0)
        or (content_blocks | map(.type) | index("text") != null)
    );
def since_last_user:
    . as $all
    | ($all | map(is_real_user) | reverse | index(true)) as $rev
    | if $rev == null then $all
      else $all[(length - $rev):]
      end;
'

# Reads the transcript tail from stdin (pipe read_tail or a captured copy) and
# prints the settled flag (1/0) on the first line, the text after it.
extract_turn_text() {
    jq -rs "$JQ_SINCE_USER"'
        since_last_user
        | ([.[] | select(.message?.role == "user" or .message?.role == "assistant")]
           | last) as $tail
        | ($tail != null
           and $tail.message.role == "assistant"
           and ($tail | content_blocks | any(.type == "text" and (.text // "") != ""))) as $settled
        | [.[]
           | select(.message?.role == "assistant")
           | content_blocks
           | map(select(.type == "text") | .text)
           | join(" ")
           | select(. != "")]
        | "\(if $settled then 1 else 0 end)\n\(last // "")"
    ' 2>/dev/null
}

# Splits extract_turn_text's output into SETTLED and TURN_TEXT.
read_turn() {
    local out
    out=$(extract_turn_text)
    SETTLED=${out%%$'\n'*}
    TURN_TEXT=""
    [ "$out" != "$SETTLED" ] && TURN_TEXT=${out#*$'\n'}
}

# Push Signal and exit marker patterns — defined this early because the quiet fast
# path below reads them too; what they mean is explained where the markers are used.
MARKER_RE='<!--[[:blank:]]*hwip:[[:blank:]]*(skip|push|high)[[:blank:]]*-->'
EXIT_RE='<!--[[:blank:]]*hwip:[[:blank:]]*exit[[:blank:]]*-->'

# ── Quiet fast path ─────────────────────────────────────────────────────────
# Quiet at the terminal is the common path and it ends silent: with no marker the
# gate says silent whatever the tallies are, so parsing the whole tail for them is
# wasted. The turn's final text sits at the very end of the transcript, so a small
# window answers the one question that matters — is there a marker in it? — and
# only a settled turn with none, for a user who is present, stops here. Anything
# else (a marker, a turn still unflushed after the wait, an away user, a window
# cut) falls through to the full path, so this only ever skips work and never
# changes a verdict. Presence is probed last, so a marker turn still pays no probe.
FAST_LINES=40
FAST_BYTES=$((256 * 1024))
FAST_TRIES=0
if [ "$PUSHMODE" = quiet ]; then
    read_turn < <(tail_window "$FAST_LINES" "$FAST_BYTES")
    while [ "$SETTLED" != 1 ] && [ "$FAST_TRIES" -lt 3 ]; do
        sleep 0.15
        read_turn < <(tail_window "$FAST_LINES" "$FAST_BYTES")
        FAST_TRIES=$((FAST_TRIES + 1))
    done
    if [ "$SETTLED" = 1 ] && ! [[ "$TURN_TEXT" =~ $MARKER_RE ]] && ! [[ "$TURN_TEXT" =~ $EXIT_RE ]] \
        && ! hook_is_away; then
        exit 0
    fi
fi

# ── Per-turn tool tallies (one jq pass) ──────────────────────────────────────
# Three counts drive the gate, all derived from the same tool_use list, so a
# single jq pass emits them as one "ask tools nonreadonly" tuple:
#   ALREADY_ASKED     — hwip_ask this turn (a push already went out). Matched
#                       by suffix: transcripts log the MCP-namespaced name
#                       (mcp__plugin_hwip_hwip__hwip_ask, or mcp__hwip__hwip_ask
#                       for a hand-registered server), never the bare one.
#   TOOL_COUNT        — total tool_use blocks
#   NONREADONLY_COUNT — tools that are NOT read-only (Read/Grep/Glob); a turn
#                       with zero is exploration noise the B1 floor drops.
# One tail read feeds both the tally and the first text extraction below —
# the retry loops re-read because they poll for late-flushed content.
TAIL_CONTENT=$(read_tail)
read ALREADY_ASKED TOOL_COUNT NONREADONLY_COUNT < <(printf '%s\n' "$TAIL_CONTENT" | jq -rs "$JQ_SINCE_USER"'
    since_last_user
    | [.[] | content_blocks[] | select(.type == "tool_use") | .name // ""] as $tools
    | "\($tools | map(select(test("(^|__)hwip_ask$"))) | length) \($tools | length) \($tools | map(select(. != "Read" and . != "Grep" and . != "Glob")) | length)"
' 2>/dev/null)
ALREADY_ASKED=${ALREADY_ASKED:-0}
TOOL_COUNT=${TOOL_COUNT:-0}
NONREADONLY_COUNT=${NONREADONLY_COUNT:-0}

# Dedup: if the assistant already sent a hwip_ask this turn, that
# already delivered a notification — never double-fire (checked before the marker
# gate so a Push Signal can never stack a second push on top of an ask-push).
[ "$ALREADY_ASKED" -gt 0 ] && exit 0

# Last assistant text THIS turn — needed both to read the Push Signal marker and
# (later) as the push body.
#
# Timing: Claude Code fires the Stop hook a beat before it flushes the turn's
# final assistant text. A single read often misses it — it lands an instant
# later. Waiting only while the text is EMPTY is not enough: a turn that wrote
# text between tool calls ("Let me check X") already has some, so the hook
# would read that mid-turn line, miss a marker in the final one and push the
# wrong body. The turn is settled once its last message entry is an assistant
# entry carrying text; until then the hook re-reads. Marker detection uses only
# a SHORT bounded wait: a fast-exit turn (skip / read-only / <2 tools) must
# never block on a body it will never send. The longer body wait runs only once
# a push is committed (further down). When either wait runs out unsettled, the
# latest text so far is used.
read_turn < <(printf '%s\n' "$TAIL_CONTENT")
marker_tries=$FAST_TRIES
while [ "$SETTLED" != 1 ] && [ "$marker_tries" -lt 3 ]; do
    sleep 0.15
    read_turn < <(read_tail)
    marker_tries=$((marker_tries + 1))
done
TEXT="$TURN_TEXT"

# Push Signal — the model steers this turn's push by emitting a marker. ONE
# pattern drives BOTH detect (bash `[[ =~ ]]`) and strip (`sed`), so a
# slightly-malformed marker can never be detected-but-not-stripped (which would
# leak the raw `<!-- hwip: ... -->` into the plaintext push body). The gaps use
# `[[:blank:]]` (space/tab only, NOT newline) on purpose: bash matches the whole
# multiline text in one buffer while sed works line-by-line, so a newline-spanning
# class would let bash detect a marker sed can't strip. With `[[:blank:]]` neither
# spans a newline, so detection and stripping stay symmetric. The rule emits a
# single-line lowercase marker, so no newline or case-insensitive matching needed.
MARKER=""
[[ "$TEXT" =~ $MARKER_RE ]] && MARKER="${BASH_REMATCH[1]}"

# Exit marker — the model's half of the sticky-REMOTE state machine. The server
# owns the exits it can see (a Done-like button, a Done-like timeout fallback,
# the phone's send-and-exit); the one it cannot is free text that means
# "we're finished", which is a meaning call. So the model emits
# `<!-- hwip: exit -->` on that response and this clears the state file.
#
# A SEPARATE pattern from MARKER_RE on purpose: that one is the push-gate
# vocabulary, parity-locked to cli/src/gate.ts's GateMarker union and to
# gate-vectors.json. Adding a fourth word there would drag the TS union, the
# `*)` fallback and every vector along for a marker the gate has no opinion
# about. Same one-pattern-drives-detect-and-strip discipline though — the strip
# below uses this very variable.
#
# Placed HERE, above the gate: `hwip_gate_decide` returns silent for a stock
# quiet install, so anything after it never runs on the common path. The three
# exits above this line are all before the response text is even read: mute and
# a missing transcript are covered by the state TTL instead, and the
# already-asked dedup is harmless — an exit response sends no hwip_ask, so it
# never trips.
[[ "$TEXT" =~ $EXIT_RE ]] && hwip_remote_clear "$MUTE_HASH"

# ── Gate ─────────────────────────────────────────────────────────────────────
# The decision lives in gate.sh (hwip_gate_decide) — a pure function shared,
# via gate-vectors.json, with the CLI's TS twin. ALREADY_ASKED already
# fast-exited above (before the marker wait, for latency); it is still passed
# through so the sourced function honors the full contract on its own.
#
# Presence is probed only where it can change the answer: quiet with no `high`
# marker is the one path that is otherwise silent. Every other turn skips the
# ~30 ms of tmux/ioreg calls (measured 2026-09-11, bash startup included —
# before the pane check, whose extra `tmux display-message` is unmeasured).
# A tmux that never answers cost the whole hook 4.2 s here (macOS, stub tmux that
# sleeps 30 s, 2026-10-04): two 2 s bounds, `list-clients` in the presence probe and
# `display-message` in the pane check. One that answered every call just inside its
# bound — 1.8 s × 4 calls, 7.4 s per hwip_is_away, ~15 s through the hook's two
# calls — ran past the 10 s plugin.json cap. The probes now share a 4 s deadline
# (see Time budget above), so both cases end inside it and read as present.
AWAY=0
[ "$PUSHMODE" = quiet ] && [ "$MARKER" != high ] && hook_is_away && AWAY=1
VERDICT=$(hwip_gate_decide "$TOOL_COUNT" "$NONREADONLY_COUNT" "$ALREADY_ASKED" "${MARKER:-none}" "$PUSHMODE" "$AWAY")
[ "$VERDICT" = silent ] && exit 0
PRIORITY=""
[ "$VERDICT" = "push high" ] && PRIORITY="high"

# A push is committed, so resolve PROJECT and BRANCH (with their own git call) now
# rather than at the top of the file: with quiet as the shipped default the silent
# path above is the common one, and it needs none of this.
PROJECT=${PROJECT_DIR%/}; PROJECT=${PROJECT##*/}
[ -n "$PROJECT" ] || PROJECT=unknown
BRANCH=$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "-")

# A push is now committed. Extend the wait for the body text — the late flush
# this targets only matters here, for turns that actually push.
summary_tries=0
while [ "$SETTLED" != 1 ] && [ "$summary_tries" -lt 5 ]; do
    sleep 0.2
    read_turn < <(read_tail)
    summary_tries=$((summary_tries + 1))
done
SUMMARY="$TURN_TEXT"

# Text that settled only during the body wait was never read for markers. Read
# it now: an exit marker still clears REMOTE, and a changed Push Signal re-runs
# the gate — a late `skip` cancels the push, a late `high` raises its priority.
if [ "$SUMMARY" != "$TEXT" ]; then
    [[ "$SUMMARY" =~ $EXIT_RE ]] && hwip_remote_clear "$MUTE_HASH"
    LATE_MARKER=""
    [[ "$SUMMARY" =~ $MARKER_RE ]] && LATE_MARKER="${BASH_REMATCH[1]}"
    if [ "$LATE_MARKER" != "$MARKER" ]; then
        MARKER="$LATE_MARKER"
        AWAY=0
        [ "$PUSHMODE" = quiet ] && [ "$MARKER" != high ] && hook_is_away && AWAY=1
        VERDICT=$(hwip_gate_decide "$TOOL_COUNT" "$NONREADONLY_COUNT" "$ALREADY_ASKED" "${MARKER:-none}" "$PUSHMODE" "$AWAY")
        [ "$VERDICT" = silent ] && exit 0
        PRIORITY=""
        [ "$VERDICT" = "push high" ] && PRIORITY="high"
    fi
fi

# Strip the markers from the body with the SAME patterns used to detect them.
[ -n "$SUMMARY" ] && SUMMARY=$(printf '%s' "$SUMMARY" | sed -E "s/$MARKER_RE//g; s/$EXIT_RE//g")

# Match the original 0.4.0 behavior of passing the full assistant summary
# through to `hwip notify`. The CLI itself decides what to do with long
# bodies — anything over 512 bytes is auto-uploaded as a file attachment
# and the push gets a 200-char preview plus a file link.
#
# Previous 0.5.0–0.5.2 trimmed to 280 chars here, which collapsed
# English-mostly summaries under the 512-byte threshold and suppressed the
# file-upload path — the push arrived truncated with no way to read the
# rest. This restores the 5000-codepoint cap from 0.4.0 (UTF-8 safe via
# python3, falling through to the untrimmed text when python3 is missing or
# fails to run — macOS ships a /usr/bin/python3 stub that exits non-zero until
# the developer tools are installed).
# NOTE: hwip-ask.sh has a near-twin with a DIFFERENT fallback — the untrimmed
# text here vs a substring cap there (a hard cap is required). Intentionally
# not merged.
trim_chars() {
    local n="$1" in out
    in=$(cat)
    if command -v python3 >/dev/null 2>&1 \
        && out=$(printf '%s' "$in" | python3 -c '
import sys
n = int(sys.argv[1])
sys.stdout.write(sys.stdin.read()[:n])
' "$n" 2>/dev/null); then
        printf '%s' "$out"
    else
        printf '%s' "$in"
    fi
}

BODY="${BRANCH} — ${TOOL_COUNT} tools"
if [ -n "$SUMMARY" ] && [ "$SUMMARY" != "null" ]; then
    # Match the original 0.4.0 behavior (jq's `.[0:5000]`) — 5000 codepoints
    # is enough to trigger hwip-cli's >512-byte file-upload path for any
    # multi-paragraph summary, while still capping runaway content. The
    # `[ -n "$TRIMMED" ]` guard preserves the default BODY if trim_chars
    # somehow returns empty (defense in depth — same as 0.4.0 had).
    TRIMMED=$(printf '%s' "$SUMMARY" | trim_chars 5000)
    [ -n "$TRIMMED" ] && BODY="$TRIMMED"
fi

# Extract session UUID from transcript path (more reliable than cache file).
# Fallback to the MCP server's per-user session cache for older Claude Code
# versions that didn't expose a UUID-bearing transcript_path. The cache file
# moved from /tmp (symlink-race prone, world-writable parent) to ~/.cache —
# read both during the migration window.
SESSION_ID=$(printf '%s' "$TRANSCRIPT" | grep -o '[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}' | tail -n1)
if [ -z "$SESSION_ID" ]; then
    HWIP_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/hwip"
    SESSION_ID=$(cat "$HWIP_CACHE_DIR/session-${MUTE_HASH}" 2>/dev/null \
              || cat "/tmp/hwip-session-${MUTE_HASH}" 2>/dev/null)
    # The fallback value expands unquoted into the CLI argv below — validate
    # it so a tampered cache file (the /tmp one is world-writable-parent
    # legacy) can never inject extra arguments. Session ids are sess_* tokens
    # or UUIDs; allow only those shapes.
    case "$SESSION_ID" in
        *[!A-Za-z0-9_-]*) SESSION_ID="" ;;
    esac
fi
SESSION_FLAG=""
[ -n "$SESSION_ID" ] && SESSION_FLAG="--session=$SESSION_ID"

# A `high` Push Signal escalates the push priority; skip/push/none leave the CLI
# default (normal).
PRIORITY_FLAG=""
[ -n "$PRIORITY" ] && PRIORITY_FLAG="--priority=$PRIORITY"

# Resolve the CLI last — `command -v` twice over plus the timeout probe — so its bound
# is what is left of the hook budget: a flat 8 s on top of probes and waits that
# already spent seconds is what took the hook past its cap. At least 1 s: a push
# still gets a try when the clock reads late.
CLI_BOUND=$((HWIP_HOOK_BUDGET_SEC - SECONDS))
[ "$CLI_BOUND" -ge 1 ] || CLI_BOUND=1
hwip_cli_command "$CLI_BOUND"

# Default: stay silent on failure (a hook must never disrupt the session).
# Opt-in: set HWIP_HOOK_DEBUG=1 to capture stderr + failures to a log for
# support, since the silent `2>/dev/null` otherwise hides every hook error.
# shellcheck disable=SC2086
if [ -n "$HWIP_HOOK_DEBUG" ]; then
    HWIP_LOG="${HWIP_HOOK_LOG:-/tmp/hwip-hook.log}"
    "${HWIP_CLI[@]}" notify --title="Claude: $PROJECT" --body="$BODY" --type=hook $SESSION_FLAG $PRIORITY_FLAG \
        >>"$HWIP_LOG" 2>&1 || echo "[hwip-stop] notify failed at $(date '+%Y-%m-%d %H:%M:%S')" >>"$HWIP_LOG"
else
    "${HWIP_CLI[@]}" notify --title="Claude: $PROJECT" --body="$BODY" --type=hook $SESSION_FLAG $PRIORITY_FLAG 2>/dev/null || true
fi
