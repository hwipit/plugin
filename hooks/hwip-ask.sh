#!/usr/bin/env bash
# PreToolUse(AskUserQuestion) hook — push the asked question to the user's
# device so they can see it without being at the terminal.

# Drain stdin before any exit: returning while Claude Code is still writing the
# hook input leaves the writer to take a SIGPIPE.
INPUT=$(cat)

command -v jq >/dev/null 2>&1 || exit 0

# Shared hook library (hooks/gate.sh): state-file resolution + CLI bounding.
# Bounding matters doubly here — this hook runs BEFORE the AskUserQuestion
# picker appears, so a cold `npx -y` resolve delays the question itself.
. "$(dirname "${BASH_SOURCE[0]}")/gate.sh"

hwip_cli_command

# Claude Code sets CLAUDE_PROJECT_DIR; a hook run without it falls back to the
# working directory for both the state key and the push title.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
MUTE_HASH=$(printf '%s' "$PROJECT_DIR" | cksum | cut -d' ' -f1)

hwip_state_present muted "$MUTE_HASH" >/dev/null && exit 0

QUESTION=$(printf '%s' "$INPUT" | jq -r '.tool_input.question // .tool_input.questions[0].question // "Question pending"' 2>/dev/null)

# AskUserQuestion carries its choices in .questions[].options[].label. The
# default extractor dropped them, so the phone saw only the question stem with
# no idea what the options were. Surface the labels so the user knows the
# choices — this push is one-way, but the answer itself need not be: when the
# session runs in tmux under `hwip listener`, the phone's terminal mirror can
# drive the picker directly (see mirror_available below).
OPTIONS=$(printf '%s' "$INPUT" | jq -r '[.tool_input.questions[0].options[]?.label // empty] | join(" · ")' 2>/dev/null)

# ── Route the question, or let the picker open ───────────────────────────────
#
# CORE_RULES rules 10/11 already say a button-friendly question belongs in
# `hwip_ask`. Enforcing that here closes the path where ignoring the rule
# succeeds quietly and strands whoever is holding a phone. `hwip_ask_decide`
# (hooks/gate.sh) owns the judgment; this block only measures the inputs.
#
# Honest about how far this goes: the BLOCK is deterministic, the RECOVERY is
# not. Nothing here can make the model call `hwip_ask` — it can only make the
# wrong path fail loudly instead of silently, and hand over the text needed to
# do the right thing.

# Falls back to a NON-NUMERIC sentinel, not 0. A jq failure means the input
# could not be measured, and hwip_ask_decide reads anything non-numeric as
# "don't guess, allow". Falling back to 0 would instead look like a genuinely
# short question and route it — turning unparseable input into a deny.
ask_measure() { printf '%s' "$INPUT" | jq -r "$1" 2>/dev/null || echo unmeasurable; }

HAS_PREVIEW=$(ask_measure '[.tool_input.questions[]?.options[]?.preview // empty] | if length > 0 then 1 else 0 end')
QUESTION_CHARS=$(ask_measure '(.tool_input.question // .tool_input.questions[0].question // "") | length')
# Longest label+description across every option: `description` is where long
# content actually lands, so measuring labels alone would miss the carve-out.
OPTION_CHARS=$(ask_measure '[.tool_input.questions[]?.options[]? | ((.label // "") + (.description // "")) | length] | max // 0')

# Keyed on the whole tool_input, not the question stem: "Proceed?" recurs
# constantly in one session and would collide with unrelated questions.
ASK_HASH=$(printf '%s' "$INPUT" | jq -cS '.tool_input' 2>/dev/null | cksum | tr -d ' ')
[ -n "$ASK_HASH" ] || ASK_HASH=none
# Project-scoped, like every other state file (`muted-<project>`): the same
# question in two projects within the window is ordinary, and one project's
# deny must not let the other's picker through.
ASK_KEY="${MUTE_HASH}-${ASK_HASH}"

REPLAY=0
hwip_ask_replay_seen "$ASK_KEY" && REPLAY=1
# Sticky REMOTE is what makes the picker unreachable, so it is what makes the
# block worth its cost. In NORMAL the user is at the keyboard as far as anything
# here can tell, and the picker opens exactly as it always did.
REMOTE=0
hwip_remote_active "$MUTE_HASH" && REMOTE=1
# A deny needs REMOTE as well, so the hook id (gate.sh hwip_hook_id — a jq
# fork on the config path) is only looked up once REMOTE is known to be live.
HOOKID_PRESENT=0
[ "$REMOTE" = 1 ] && [ -n "$(hwip_hook_id)" ] && HOOKID_PRESENT=1

# muted is passed as 0 because a muted project already left this script at the
# `hwip_state_present muted` check above. The parameter stays in the function's
# signature so the decision reads completely on its own in the vectors.
if [ "$(hwip_ask_decide "$HOOKID_PRESENT" 0 "$HAS_PREVIEW" "$QUESTION_CHARS" "$OPTION_CHARS" "$REPLAY" "$REMOTE")" = deny ]; then
    hwip_ask_replay_mark "$ASK_KEY"
    # Deliberately NOT trimmed: trim_chars below exists for the device feed
    # preview, and the model has to re-ask this question verbatim.
    #
    # No `${HWIP_CLI[@]}` on this path, and no other network call. Claude Code fails
    # OPEN when it kills a hook at its timeout (measured 2026-08-11), so a hook
    # that hung here would let the picker through while the user believed the
    # question had been routed. Here that is the safe direction anyway — but it
    # only stays safe because nothing on this path can block.
    #
    # Known gap: the user gets no push from THIS hook on a deny. Normally that
    # is right — the model's `hwip_ask` sends its own, and a second push would
    # duplicate the question. If the model ignores the reason and simply stops,
    # the end-of-turn Stop hook is the remaining signal, which is quieter than
    # the one-way notify this path used to send.
    OPTION_LINE=""
    [ -n "$OPTIONS" ] && OPTION_LINE=" Options: $OPTIONS."
    hwip_hook_decision deny "Do not use AskUserQuestion here. Ask this exact question again with the hwip_ask tool so the user can answer it from their phone: \"$QUESTION\".$OPTION_LINE Map each option to a hwip_ask action and use the response in place of the picker."
    exit 0
fi

# UTF-8 safe trim to ~200 chars so multibyte characters (e.g. Korean) don't
# get sliced in the middle and turned into mojibake. Falls back to bash's own
# substring when python3 is missing OR fails to run — macOS ships a
# /usr/bin/python3 stub that exits non-zero until the developer tools are
# installed, and an empty result here would leave the push body blank. The
# fallback counts characters under a UTF-8 locale and bytes otherwise.
# NOTE: hwip-stop.sh has a near-twin with a DIFFERENT fallback — a substring
# cap here (a hard cap is required) vs the untrimmed text there (the CLI
# uploads a long body as a file). Intentionally not merged.
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
        printf '%s' "${in:0:$n}"
    fi
}
QUESTION=$(printf '%s' "$QUESTION" | trim_chars 160)
OPTIONS=$(printf '%s' "$OPTIONS" | trim_chars 120)

PROJECT=${PROJECT_DIR%/}; PROJECT=${PROJECT##*/}
[ -n "$PROJECT" ] || PROJECT=unknown

# Session id — the key the server uses to recognize that this question already
# notified. Without it the listener's `blocked` agent.state push fires a second
# notification for the same question seconds later. Extraction mirrors
# hwip-stop.sh: UUID out of the transcript path, MCP session cache as the
# fallback, and the same argv-injection guard on the cache value (it expands
# unquoted below, and the legacy /tmp copy has a world-writable parent).
TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
SESSION_ID=$(printf '%s' "$TRANSCRIPT" | grep -o '[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}' | tail -n1)
if [ -z "$SESSION_ID" ]; then
    HWIP_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/hwip"
    SESSION_ID=$(cat "$HWIP_CACHE_DIR/session-${MUTE_HASH}" 2>/dev/null \
              || cat "/tmp/hwip-session-${MUTE_HASH}" 2>/dev/null)
    case "$SESSION_ID" in
        *[!A-Za-z0-9_-]*) SESSION_ID="" ;;
    esac
fi
SESSION_FLAG=""
[ -n "$SESSION_ID" ] && SESSION_FLAG="--session=$SESSION_ID"

# High priority because this push now stands alone. The server suppresses its
# `blocked` agent.state twin once this one is on file, and that twin was high —
# sending this at the default `normal` would quietly demote every question the
# user gets on their phone.

# Can the phone drive this pane? Two signals, and it takes both:
#   1. this session sits in a tmux pane ($TMUX), and
#   2. the listener daemon is alive (~/.hwip/listener.pid + a liveness check —
#      the bash twin of listener-process.ts readListenerPid, which does the
#      same `process.kill(pid, 0)`).
# With both, the picker is reachable: it renders in `tmux capture-pane` and the
# phone's arrow/Enter buttons reach it through the listener's key injection
# (listener.ts ALLOWED_KEYS → `tmux send-keys`). With either missing there is no
# mirror, and the terminal is the only way in.
#
# `kill -0` is a builtin and the pid file is a local read, so this costs no
# subprocess and no network — it stays well inside the hook's 10s budget.
mirror_available() {
    [ -n "${TMUX:-}" ] || return 1
    local pid
    pid=$(cat "$HOME/.hwip/listener.pid" 2>/dev/null) || return 1
    # Numeric-only: `kill -0` would otherwise take a job spec or a negative
    # process group from a corrupted file.
    case "$pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    kill -0 "$pid" 2>/dev/null
}

# Build the body: question, the choices (when present), and where the answer can
# actually be given. The title says "asks", so the last line has to be true for
# THIS session — claiming a mirror that isn't there strands the user on the
# phone, and denying one that is there sends them to a desk they didn't need.
BODY="$QUESTION"
[ -n "$OPTIONS" ] && BODY="$BODY
▸ $OPTIONS"
if mirror_available; then
    BODY="$BODY
↳ answer at the terminal, or from the phone's terminal mirror (↑/↓ then Enter)"
else
    BODY="$BODY
↳ answer at the terminal"
fi

# Default: silent on failure. Opt-in HWIP_HOOK_DEBUG=1 logs stderr +
# failures (the silent `2>/dev/null` otherwise hides every hook error).
# shellcheck disable=SC2086
if [ -n "$HWIP_HOOK_DEBUG" ]; then
    HWIP_LOG="${HWIP_HOOK_LOG:-/tmp/hwip-hook.log}"
    "${HWIP_CLI[@]}" notify --title="Claude asks: $PROJECT" --body="$BODY" --priority=high $SESSION_FLAG \
        >>"$HWIP_LOG" 2>&1 || echo "[hwip-ask] notify failed at $(date '+%Y-%m-%d %H:%M:%S')" >>"$HWIP_LOG"
else
    "${HWIP_CLI[@]}" notify --title="Claude asks: $PROJECT" --body="$BODY" --priority=high $SESSION_FLAG 2>/dev/null || true
fi
