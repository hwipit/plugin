#!/usr/bin/env bash
# /hwip-mode — read or change this project's Hwip notification state.
#
#   stdin line 1: project dir
#   line 2: [quiet|normal|loud|mute|unmute] [--global]  |  approve on|off
#
# Input comes on stdin, not argv: the skill writes both lines inside a quoted
# heredoc, so the substituted $ARGUMENTS and ${CLAUDE_PROJECT_DIR} are never
# parsed by the shell — `quiet; $(date)` stays one bad word for the case below.
#
# No word → status only. A word → write the state file, print status, then
# re-emit the SessionStart rules for the new state when they changed: that
# hook's rules are state-conditional and never re-run mid-session, so without
# the refresh a quiet→normal switch leaves the model on the quiet branch.
# `approve` is not in those rules and never re-emits them.
#
# State resolution is gate.sh's (hwip_state_present / hwip_read_pushmode) —
# the same functions the Stop and Ask hooks read, so status cannot disagree
# with what they do. The project dir is the skill's substituted
# ${CLAUDE_PROJECT_DIR} (that variable is not in the Bash tool's env); empty or
# left unsubstituted → $PWD.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../hooks/gate.sh
. "$ROOT/hooks/gate.sh"

USAGE='Usage: /hwip-mode [quiet|normal|loud|mute|unmute] [--global] | approve on|off'

usage_error() {
    printf 'hwip-mode: %s\n%s\n' "$1" "$USAGE" >&2
    exit 2
}

IFS= read -r DIR || true
read -r -a ARGS || true
case "$DIR" in
    ''|'${'*) DIR="$PWD" ;;
esac
HASH=$(printf '%s' "$DIR" | cksum | cut -d' ' -f1)

WORD=""; GLOBAL=0; APPROVE=""
for arg in ${ARGS[@]+"${ARGS[@]}"}; do
    if [ "$WORD" = approve ] && [ -z "$APPROVE" ]; then
        case "$arg" in
            on|off) APPROVE="$arg"; continue ;;
            *) usage_error "approve takes on or off" ;;
        esac
    fi
    case "$arg" in
        --global) GLOBAL=1 ;;
        quiet|normal|loud|mute|unmute|approve)
            [ -z "$WORD" ] || usage_error "one mode at a time"
            WORD="$arg" ;;
        *) usage_error "unknown argument '$arg'" ;;
    esac
done
[ "$WORD" != approve ] || [ -n "$APPROVE" ] || usage_error "approve takes on or off"

if [ "$GLOBAL" -eq 1 ]; then
    case "$WORD" in
        quiet|normal|loud) ;;
        "") usage_error "--global needs quiet, normal or loud" ;;
        *) usage_error "--global applies to push dials only; mute and approve are per-project" ;;
    esac
fi

# The rules for the state as it stood just before this change — compared after
# it, so a switch that leaves the SessionStart text identical (normal ↔ loud)
# prints one line instead of the whole 3–7 KB block again. That is the
# session's own rules unless something else moved the state since it started
# (another session in the same project, a --global dial set elsewhere — the
# project-keyed limit ADR-0002 accepts), which is why the one line names the
# dial: a model holding rules for a different one can tell.
session_rules() {
    CLAUDE_PROJECT_DIR="$DIR" node "$ROOT/hooks/hwip-setup.js" 2>/dev/null \
        | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null
}
RULES_BEFORE=""
case "$WORD" in quiet|normal|loud|mute|unmute) RULES_BEFORE=$(session_rules) ;; esac

mkdir -p "$HWIP_STATE_DIR"
case "$WORD" in
    quiet|normal|loud)
        if [ "$GLOBAL" -eq 1 ]; then
            printf '%s' "$WORD" > "$HWIP_STATE_DIR/pushmode-default"
        else
            printf '%s' "$WORD" > "$HWIP_STATE_DIR/pushmode-$HASH"
        fi ;;
    mute) touch "$HWIP_STATE_DIR/muted-$HASH" ;;
    unmute) rm -f "$HWIP_STATE_DIR/muted-$HASH" "/tmp/hwip-muted-$HASH" ;;
    approve)
        if [ "$APPROVE" = on ]; then
            touch "$HWIP_STATE_DIR/approve-$HASH"
        else
            rm -f "$HWIP_STATE_DIR/approve-$HASH" "/tmp/hwip-approve-$HASH"
        fi ;;
esac

# ── status ──────────────────────────────────────────────────────────────────

if hwip_state_present muted "$HASH" >/dev/null; then
    echo "NOTIFICATIONS: muted"
else
    echo "NOTIFICATIONS: active"
fi

if DIAL_FILE=$(hwip_state_present pushmode "$HASH"); then
    case "$DIAL_FILE" in
        */pushmode-default) SOURCE="global default" ;;
        *) SOURCE="this project" ;;
    esac
else
    SOURCE="built-in default — no dial set"
fi
echo "PUSH MODE: $(hwip_read_pushmode "$HASH") ($SOURCE)"

# hooks/hwip-approve.sh: opt-in hold on hard-to-undo Bash commands.
if hwip_state_present approve "$HASH" >/dev/null; then
    if hwip_state_present muted "$HASH" >/dev/null; then
        echo "APPROVAL GATE: on, but inactive while muted"
    else
        echo "APPROVAL GATE: on"
    fi
else
    echo "APPROVAL GATE: off"
fi

if AUTO_FILE=$(hwip_state_present auto "$HASH"); then
    read -r DEADLINE MINUTES < "$AUTO_FILE" || true
    # Digits only before $(( )): bash arithmetic evaluates a variable's text, so
    # a crafted auto file could otherwise run a command.
    # A deadline in the past is a session that ended without removing its file
    # (a crash, a closed terminal): clear it rather than report negative time.
    case "${DEADLINE:-}${MINUTES:-}" in
        ''|*[!0-9]*) echo "AUTO MODE: unreadable state file $AUTO_FILE" ;;
        *)
            if [ "$DEADLINE" -le "$(date +%s)" ]; then
                rm -f "$AUTO_FILE"
                echo "AUTO MODE: off (an expired ${MINUTES}m session left its state behind — cleared)"
            else
                echo "AUTO MODE: $(( (DEADLINE - $(date +%s)) / 60 ))m remaining of ${MINUTES}m"
            fi ;;
    esac
fi
# State files are keyed by the project directory, not the session (ADR-0002,
# decided A): a second session in this directory reads and changes the same ones.
echo "SCOPE: mute, push dial, approval gate and auto mode are shared with every other session in this directory"
# The CLI's record of its last failed push (hooks/notify-failure.js reads it;
# `hwip notify` is the only writer). The hooks discard notify's stderr, so this
# line is what tells "quiet, nothing to send" apart from "every push fails".
# Without node the record cannot be read — say so rather than "no failure",
# which is the very signal this line exists to make trustworthy.
if ! command -v node >/dev/null 2>&1; then
    echo "LAST PUSH: unknown (node not found)"
elif LAST_FAILURE=$(node "$ROOT/hooks/notify-failure.js" 2>/dev/null); then
    echo "LAST PUSH: ${LAST_FAILURE:-no failure recorded}"
else
    echo "LAST PUSH: unknown (could not read the record)"
fi
# Devices whose encryption key changed, kept by whoever replaced the pin until a
# person sees them: shown once here, and the record deleted.
if command -v node >/dev/null 2>&1; then
    node "$ROOT/hooks/notify-failure.js" key-changes 2>/dev/null || true
fi
echo "$USAGE"

[ -n "$WORD" ] || exit 0
# The approval gate is not in the session rules.
[ "$WORD" != approve ] || exit 0

# ── rules refresh ───────────────────────────────────────────────────────────

RULES=$(session_rules)

if [ -z "$RULES" ]; then
    echo "hwip-mode: could not refresh the session rules (node, jq or hooks/hwip-setup.js failed); the change above still applies — a new session picks up its rules."
    exit 0
fi

if [ "$RULES" = "$RULES_BEFORE" ]; then
    echo "Session rules unchanged — the Hwip rules you have still apply if they are for push dial $(hwip_read_pushmode "$HASH")$(hwip_state_present muted "$HASH" >/dev/null && echo ', muted'). If yours are for another dial, a new session loads the right ones."
    exit 0
fi

printf '\n=== Hwip rules — replace the Hwip rules from session start ===\n\n%s\n' "$RULES"
