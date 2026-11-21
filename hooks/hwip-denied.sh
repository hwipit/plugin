#!/usr/bin/env bash
# PermissionDenied(Bash) hook — when auto mode blocks a command while the user
# is away or driving the session from their phone, ask the phone whether to run
# it anyway.
#
# WHY. Auto mode's classifier takes only what the user typed as consent. It
# strips tool results from what it reads (code.claude.com/docs/en/permission-
# modes), so a "merge it" tapped on a `hwip_ask` never reaches it: the merge the
# user asked for on the phone is judged as the agent's own idea and blocked. A
# hook's `classifierContext` does not help either — the docs say a note from a
# settings or plugin hook "never establishes user intent".
#
# HOW. A PermissionDenied hook cannot reverse a denial; `retry: true` only tells
# the model it may try again. So on Approve this hook records the sha256 of the
# exact command for one use (gate.sh `hwip_approve_once_put`, 10 minutes) and
# answers `retry`. The retry runs hwip-approve.sh first, which takes that record
# and answers `allow` — and a PreToolUse allow decides the call before the
# classifier sees it (measured 2026-11-21, Claude Code 2.1.330). A retry that
# changes the command text by one byte matches nothing and is judged afresh.
#
# WHEN. Not at the terminal: a user there re-authorizes by typing, and a phone
# round trip would stall the session for no one. Anything but Run it → the
# denial stands.

# Drain stdin before any exit: returning while Claude Code is still writing the
# hook input leaves the writer to take a SIGPIPE.
INPUT=$(cat)

command -v jq >/dev/null 2>&1 || exit 0

. "$(dirname "${BASH_SOURCE[0]}")/gate.sh"

# What `hwip ask` waits for a human, and the cap on the whole CLI run inside
# plugin.json's 120s — the same bounds, and reasoning, as hwip-approve.sh.
HWIP_DENIED_DEADLINE_SEC=75
HWIP_DENIED_CLI_CAP_SEC=100

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
# `printf '%s'`, NOT a here-string: the key must match the other hooks' cksum.
PROJECT_HASH=$(printf '%s' "$PROJECT_DIR" | cksum)
PROJECT_HASH=${PROJECT_HASH%% *}

hwip_state_present muted "$PROJECT_HASH" >/dev/null && exit 0

hwip_user_at_terminal "$PROJECT_HASH" && exit 0

SESSION_ID=$(hwip_session_id "$INPUT")
[ -n "$SESSION_ID" ] || exit 0
BODY=$(hwip_command_body "$INPUT")
[ -n "$BODY" ] || exit 0
CMD_HASH=$(hwip_command_hash "$BODY") || exit 0
ONCE_FILE="$HWIP_STATE_DIR/approveonce-$PROJECT_HASH-$SESSION_ID"

REASON=$(jq -r '.reason // empty' <<< "$INPUT" 2>/dev/null)
PROJECT=${PROJECT_DIR##*/}
[ -n "$PROJECT" ] || PROJECT=unknown
TEXT="$BODY"
[ -n "$REASON" ] && TEXT="Auto mode: $REASON"$'\n\n'"$BODY"

hwip_cli_command "$HWIP_DENIED_CLI_CAP_SEC"
# `--flag=value` for every flag: the command text is untrusted, and as a word
# of its own one that starts with `--base-url=…` would be a flag of the CLI.
ANSWER=$("${HWIP_CLI[@]}" ask \
    --title="Auto mode blocked a command in $PROJECT. Run it?" \
    --body="$TEXT" \
    --actions="run:Run it,keep:Keep blocked" \
    --timeout="$HWIP_DENIED_DEADLINE_SEC" 2>/dev/null)

[ "$(jq -r '.actionId // empty' <<< "$ANSWER" 2>/dev/null)" = run ] || exit 0

hwip_approve_once_put "$ONCE_FILE" "$CMD_HASH" || {
    printf '[hwip-denied] could not record the approval in %s — the denial stands\n' "$HWIP_STATE_DIR" >&2
    exit 0
}

jq -n '{hookSpecificOutput: {hookEventName: "PermissionDenied", retry: true}}'
