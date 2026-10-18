#!/usr/bin/env bash
# UserPromptSubmit hook — remote-origin detection (ADR-0002) and the sticky
# REMOTE reminder that follows it.
#
# Two jobs, in this order:
#
#   1. Entry. The hwip listener records every phone→pane text injection as a
#      one-shot marker file (`remote-<hash>` under the hwip state dir) holding
#      the epoch second and sha256 of the injected text. When the submitted
#      prompt matches that record, the user is driving this session from their
#      phone, and the hook says so — which enters sticky REMOTE mode
#      (CORE_RULES Rule 9) so every response ends in an answerable hwip_ask.
#      Entry detection is exact: same project (cksum of the dir), fresh
#      (≤15 min), and byte-identical trimmed text. A terminal keystroke racing
#      a phone message can never false-match.
#
#   2. Leaving. The marker is one-shot, but REMOTE is not — it is recorded in
#      `remote-active-<hash>` (see gate.sh) so it outlives the entry turn and
#      survives context compaction, which is what Rule 13 promises. A prompt
#      that reaches this hook without a marker was typed at the terminal —
#      unless Claude Code wrote it itself (see system_turn below: a phone
#      answer to a hwip_ask can arrive that way). The user is back, so the
#      mode ends here — clear the state and say so once. Re-entry costs one
#      more phone message. The exceptions leave the mode exactly as it was: a
#      fresh marker left unmatched (a phone message is in flight — see
#      remote_origin_match's three-way verdict) and a system-written turn.
#
# The full Rule 9 text (~2.7 KB) goes to a session ONCE: a `remote-injected-<session_id>`
# mark records that this session has it (this hook writes it after shipping the
# text; SessionStart writes it when it ships the REMOTE contract and removes it on
# every start, since compaction drops the text). A later phone message in a
# marked session gets a short reminder instead. Per session, not per project:
# `remote-active-<hash>` is keyed by the directory, so a second session there
# sees a live REMOTE it was never told about. No session_id in the input (an
# older Claude Code) → never marked → always the full text, as before.
# Accepted limit (unverified): /rewind may restore the conversation without a
# SessionStart, leaving a mark for text that is no longer in context.
#
# No marker and no live state → silent no-op. This hook only ever adds context
# and must never block a prompt (always exit 0).

# Drain stdin before any exit, unconditionally: returning while the pipe is
# still full leaves the writer to take a SIGPIPE. Parsing it is a different
# question — see below.
INPUT=$(cat)

command -v jq >/dev/null 2>&1 || exit 0

# Shared hook library (hooks/gate.sh): state-file resolution.
. "$(dirname "${BASH_SOURCE[0]}")/gate.sh"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
HASH=$(printf '%s' "$PROJECT_DIR" | cksum | cut -d' ' -f1)

# Mute outranks everything (Rule 12) — stay silent and leave the marker
# unconsumed (the next inject overwrites it anyway). The REMOTE state is left
# alone too: mute suspends the pushing, it does not end the remote session.
hwip_state_present muted "$HASH" >/dev/null && exit 0

hash_stdin() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | cut -d' ' -f1
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    else
        return 1
    fi
}

# Three-way verdict, because "not a phone message" and "typed at the terminal"
# are not the same claim and the exit branch may only act on the second:
#
#   0 PHONE      verified injection; marker consumed
#   1 KEYBOARD   no marker this prompt could ever have matched — the user typed
#   2 UNCLEAR    a fresh marker is sitting here unmatched, so a phone message is
#                in flight (queued behind a long turn, or a digest the two sides
#                compute differently). Ambiguous evidence must not be read as
#                "the user is back": that would drop them out of REMOTE while
#                they are still holding the phone, with no answerable push left.
#                Also an unreadable prompt while such a marker is pending. With
#                no marker in play an empty prompt still reads as KEYBOARD: the
#                listener never injects empty text, so there is nothing in
#                flight to be ambiguous about — and testing emptiness before
#                the marker would put a jq spawn on every prompt in every
#                project, which is what the file test above exists to avoid.
remote_origin_match() {
    local marker ts age recorded ws prompt digest

    # Marker existence first, and it is a plain file test. Every prompt in every
    # project reaches this line, and the overwhelmingly common answer is "no
    # marker" — so nothing below may run before it, least of all the `jq` spawn
    # that parses the prompt out of the payload.
    marker=$(hwip_state_present remote "$HASH") || return 1

    prompt=$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)
    [ -n "$prompt" ] || return 2

    # Marker format: "<epochSec> <sha256hex>\n" (written by cli listener.ts).
    # Junk here can never match anything, so it says nothing about who typed —
    # same verdict as no marker at all, and the same housekeeping a stale
    # marker gets: delete it rather than leave a file that can only ever be
    # re-read and re-rejected.
    read -r ts recorded < "$marker" 2>/dev/null || { rm -f "$marker"; return 1; }
    age=$(hwip_age_sec "$ts") || { rm -f "$marker"; return 1; }
    [ -n "$recorded" ] || { rm -f "$marker"; return 1; }

    # Freshness: 15 minutes. The window is deliberately generous — false
    # positives are already impossible without an exact hash match; its only
    # job is to stop the SAME text typed at the terminal much later from
    # re-flagging. It must survive the real gap between injection and prompt
    # submit: a message sent while the agent is mid-turn queues until the
    # turn ends, which can easily exceed a minute. Stale markers are dead
    # weight (can never flag) — delete instead of leaving them behind.
    if [ "$age" -gt 900 ]; then
        rm -f "$marker"
        return 1
    fi

    # Trim both ends — the terminal may normalize trailing whitespace between
    # send-keys and the prompt. Explicit ASCII whitespace set, NOT [[:space:]]:
    # the POSIX class is locale-dependent (a UTF-8 locale may include U+00A0
    # etc.) and the listener hashes with the same explicit ASCII-only trim —
    # both sides must strip the exact same bytes or the digests diverge.
    ws=$' \t\r\n\f\v'
    prompt="${prompt#"${prompt%%[!${ws}]*}"}"
    prompt="${prompt%"${prompt##*[!${ws}]}"}"

    digest=$(printf '%s' "$prompt" | hash_stdin) || return 2
    [ "$digest" = "$recorded" ] || return 2

    # Matched — consume the marker so an identical later prompt (e.g. typed at
    # the terminal) can't re-flag. The explicit `return 0` matters: `rm` fails
    # on a read-only state dir, and letting its status be this function's would
    # turn a verified phone message into a no-match. The match is valid whether
    # or not the housekeeping lands — same rule the TS twin states at
    # cli/src/remote-hook.ts ("emit anyway").
    rm -f "$marker"
    return 0
}

# system_turn — rc 0 when Claude Code wrote this prompt itself. Such turns reach
# UserPromptSubmit like typed ones, and the hook input carries no origin field
# (Claude Code 2.1.282 sends the common fields plus `prompt` and
# `session_title`), so the text is the only tell. None of them is the user at
# the keyboard, and one of them is the user on the phone: a hwip_ask that
# outlives Claude Code's MCP auto-background window (120 s by default,
# CLAUDE_CODE_MCP_AUTO_BACKGROUND_MS), or that is waiting when another message
# lands, moves to the background, and the phone answer then arrives as a
# <task-notification> turn instead of a tool_result. Read as KEYBOARD, every
# slow phone answer ended REMOTE.
#   <task-notification>                      a background task or MCP call finished
#   Another Claude session sent a message    a subagent or peer reported (": " between
#                                            turns, " while you were working:" mid-turn)
#   A peer session sent a message            the same, mid-turn wording
#   <cross-session-message                   the raw cross-session wrapper
#   The <name> plugin sent a message         a prompt a plugin submitted
# Prefixes read from the Claude Code 2.1.282 binary; the first two also seen in
# real transcripts (2026-09-25). If Claude Code changes them, this fails toward
# the old behaviour (REMOTE ends), never toward a REMOTE that cannot be left —
# the next prompt that really is typed still ends it. Only the exit branch
# asks, so the jq spawn is paid only while REMOTE is live.
system_turn() {
    local prompt
    prompt=$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)
    case "$prompt" in
        '<task-notification>'* | '<cross-session-message'* | \
        'Another Claude session sent a message'* | 'A peer session sent a message'* | \
        'The '*' plugin sent a message'*) return 0 ;;
    esac
    return 1
}

# Exactly one additionalContext per invocation, and the verdict decides which:
# PHONE enters, KEYBOARD leaves, UNCLEAR says nothing and leaves the mode as it
# was — the pending marker will speak for itself on the turn it matches.
remote_origin_match
ORIGIN=$?

if [ "$ORIGIN" -eq 0 ]; then
    # Two-way hook id (gate.sh hwip_hook_id) — resolved here and in the exit
    # branch only; the common no-marker path never pays for it.
    if [ -n "$(hwip_hook_id)" ]; then
        # Only a two-way session has a mode to stay in — without hwip_ask there
        # is nothing for a later turn to be reminded of, so no state is written.
        hwip_remote_touch "$HASH"
        # A session that was already given the full contract gets a reminder
        # (see the header); only the first phone message pays for the text.
        SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
        case "$SESSION_ID" in '' | *[!A-Za-z0-9_-]*) SESSION_ID="" ;; esac
        INJECTED_MARK=""
        [ -n "$SESSION_ID" ] && INJECTED_MARK="$HWIP_STATE_DIR/remote-injected-$SESSION_ID"
        if [ -n "$INJECTED_MARK" ] && [ -f "$INJECTED_MARK" ]; then
            CTX='# System note (Hwip remote-origin detect)

This user message arrived from the user'"'"'s phone via Hwip agent chat (verified by the listener). Sticky REMOTE (CORE_RULES Rule 9, already given to this session): end EVERY response with `hwip_ask` — 2–4 `actions` plus a Done-like `fallback`, `timeout` 300–600 s, alongside free-text. REMOTE ends on a Done-like button (or a timeout onto one), the phone'"'"'s "send and exit", your own read of a free-text wrap-up (emit `<!-- hwip: exit -->`), or a prompt typed at the terminal.'
        else
            # This turn is the transition, so it is where the contract has to
            # arrive in full. The SessionStart hook only ships a two-line stub of
            # Rule 9 to a NORMAL session — it cannot know a phone message is
            # coming — so entry is the one moment the whole section is worth its
            # bytes. Read from CORE_RULES.md rather than restated here: a copy
            # would be a fourth place for the rule to drift. If the file is
            # unreadable the summary below still enters REMOTE correctly.
            CTX='# System note (Hwip remote-origin detect)

This user message arrived from the user'"'"'s phone via Hwip agent chat (verified by the listener — exact text match). The user is driving this session remotely and is NOT at the terminal. Enter sticky REMOTE mode now (CORE_RULES Rule 9): end EVERY response with `hwip_ask` — with `actions`: 2–4 buttons carrying the next-step candidates plus a Done-like fallback, alongside free-text (a text-only ask leaves the phone with nothing to tap) — until the user exits — an exit signal (done/stop/exit), or a prompt they type at the terminal, which this hook will tell you about. Plain-text questions are invisible to them.'
            RULE9=$(hwip_core_section '### Sticky REMOTE mode (Rule 9)') \
                && CTX="$CTX

$RULE9"
            # Marked only once the full text really went out: an unreadable
            # CORE_RULES.md ships the summary alone, which is not "given".
            if [ -n "$INJECTED_MARK" ] && [ -n "$RULE9" ]; then
                mkdir -p "$HWIP_STATE_DIR" 2>/dev/null && : > "$INJECTED_MARK" 2>/dev/null
            fi
        fi
    else
        CTX='# System note (Hwip remote-origin detect)

This user message arrived from the user'"'"'s phone via Hwip agent chat (verified by the listener — exact text match), but no hook id is configured (neither `HWIP_HOOK_ID` nor `hookId` in ~/.hwip/config.json), so the two-way tool (hwip_ask) is unavailable. Make your final message self-contained — the Stop-hook push is the user'"'"'s only feedback channel. If you have not already mentioned it this session, tell the user once that running `npx @hwip/cli setup` upgrades this into a two-way remote session (buttons + text replies from the phone).'
    fi
elif [ "$ORIGIN" -eq 1 ] && hwip_remote_active "$HASH" && ! system_turn && [ -n "$(hwip_hook_id)" ]; then
    # KEYBOARD on a live REMOTE session: the user typed this at the terminal,
    # so they are back and REMOTE ends. Emitted once — the state is gone, so
    # every later terminal turn is a silent no-op and costs nothing per turn.
    # A turn Claude Code wrote itself says nothing about who holds the device
    # and falls through to the silent no-op below.
    hwip_remote_clear "$HASH"
    CTX='# System note (Hwip)

The user typed this prompt at the terminal, so this session has LEFT sticky REMOTE mode — you owe no `hwip_ask` from here on. Do not end this response with one just to keep the loop alive; if you need to ask something, use `AskUserQuestion` or plain prose (the Ask hook still pushes the question to their device). Re-entry is automatic the moment they send another message from their phone.'
else
    exit 0
fi

jq -n --arg ctx "$CTX" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'
exit 0
