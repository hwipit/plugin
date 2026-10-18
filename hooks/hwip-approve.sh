#!/usr/bin/env bash
# PreToolUse(Bash) hook — hold a hard-to-undo command until the user approves
# it from their phone.
#
# ⚠️ A SPEED BUMP, NOT A SECURITY BOUNDARY. `hwip_approve_needed` (hooks/gate.sh)
# matches text in a command string; anything deliberately evading it will.
# What this catches is the accident — an agent reaching for `rm -rf` or a prod
# deploy while nobody is watching the terminal.
#
# OPT-IN, per project. Claude Code fails OPEN when a hook times out (measured
# 2026-08-11: the hook process is killed at its `timeout` and the tool call runs
# anyway, with nothing shown in the pane). A gate that can silently become no
# gate must not switch itself on, and a gate that blocks a terminal session for
# a minute must not surprise anyone. `/hwip-mode approve on` enables it — it
# creates ${XDG_STATE_HOME:-~/.local/state}/hwip/approve-<project-hash>, where
# <project-hash> is `cksum` of the project directory, the same key the mute and
# push-mode dials use — and `/hwip-mode approve off` removes it.
#
# AT THE TERMINAL, THE TERMINAL ASKS. When the user is provably at the machine
# (hwip_presence says `present`), the session is not in REMOTE, and Claude
# Code's permission mode is one that shows prompts, the hook answers `ask`:
# Claude Code's own permission prompt holds the command, with no phone round
# trip and no 75 s wait. Every other case — away, presence unreadable, REMOTE,
# a bypass-style mode, no mode in the input — keeps the phone approval. `ask`
# is never an allow: the command still waits for a person.
#
# Presence is the MACHINE's (keyboard idle time, any attached tmux client), so
# on its own it cannot tell which tmux session the user is looking at. Inside
# tmux the hook therefore also asks about THIS session's pane
# (hwip_pane_visible): a session with no client attached, in a window that is
# not showing, or under another pane's zoom keeps the phone. Accepted limit: a
# pane that is on screen in a terminal the user is not looking at still reads as
# watched, and a tmux that will not answer leaves the machine verdict alone;
# a headless `claude -p --permission-prompt-tool …` run leaves the `ask` to
# whatever tool the user configured to answer prompts.
#
# Because CC fails open, this hook never relies on CC's timeout: it gives
# `hwip ask` a deadline well inside its own, and answers `deny` itself when
# that passes. Silence is a refusal here, which is the opposite of the
# AskUserQuestion hook next door — there `allow` is the safe direction, here it
# is the dangerous one.

# Drain stdin before any exit: returning while Claude Code is still writing the
# hook input leaves the writer to take a SIGPIPE.
INPUT=$(cat)

command -v jq >/dev/null 2>&1 || exit 0

. "$(dirname "${BASH_SOURCE[0]}")/gate.sh"

# Two bounds, and the gap between them is the whole safety argument.
#
# plugin.json gives this hook 120s. A killed hook is a SILENT ALLOW, so the
# script must answer well before that — and "the ask waits 90s" is not enough on
# its own, because the wait is not the only thing that takes time: a cold
# `npx -y @hwip/cli` resolve happens first, and a poll request already in
# flight when the deadline passes adds up to another 10s (ask.ts checks the
# deadline at the top of its loop).
#
# So the inner deadline is what `hwip ask` waits for a human, and the outer cap
# bounds the whole CLI invocation including startup. If the outer cap fires the
# output is empty, which falls through to deny below — late is a refusal, never
# a pass.
HWIP_APPROVE_DEADLINE_SEC=75
HWIP_APPROVE_CLI_CAP_SEC=100

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
# `printf '%s'`, NOT a here-string: `<<<` appends a newline and cksum would
# hash a different byte sequence, giving this hook a key that no longer matches
# the one hwip-ask.sh and hwip-stop.sh compute for the same project.
PROJECT_HASH=$(printf '%s' "$PROJECT_DIR" | cksum)
PROJECT_HASH=${PROJECT_HASH%% *}

# Not enabled here → behave exactly as if this hook did not exist.
hwip_state_present approve "$PROJECT_HASH" >/dev/null || exit 0

# Muted means no push can reach the user, so there is no one to ask. Blocking
# would freeze the session with no way to answer it. The cost is real and worth
# stating plainly: muting a project also turns this gate off.
hwip_state_present muted "$PROJECT_HASH" >/dev/null && exit 0

COMMAND=$(jq -r '.tool_input.command // empty' <<< "$INPUT" 2>/dev/null)

hwip_approve_needed "$COMMAND" || exit 0

# The terminal prompt only where Claude Code is known to show one. In a
# bypass-style mode an `ask` might be resolved without anyone looking — that
# would be the gate failing open — so those keep the phone.
PERMISSION_MODE=$(jq -r '.permission_mode // empty' <<< "$INPUT" 2>/dev/null)
case "$PERMISSION_MODE" in
    default|acceptEdits|plan)
        if ! hwip_remote_active "$PROJECT_HASH" && [ "$(hwip_presence)" = present ] \
            && [ "$(hwip_pane_visible)" != hidden ]; then
            hwip_hook_decision ask "Hard-to-undo command. You are at the terminal, so Claude Code asks here instead of your phone."
            exit 0
        fi ;;
esac

# What the user is shown. A shell variable cannot hold a NUL: `$(...)` above drops
# the byte without a word (the match above is on that text), and the approval
# window would show a string the command never was. jq names the byte U+2400
# here so the body says where it was.
BODY=$(jq -r '.tool_input.command // empty | if type == "string" then split("\u0000") | join("\u2400") else . end' <<< "$INPUT" 2>/dev/null)

PROJECT=${PROJECT_DIR##*/}
[ -n "$PROJECT" ] || PROJECT=unknown

# Resolved here rather than at the top: this hook runs on EVERY Bash tool call
# and is off by default, so `command -v hwip` at load time would be a fork spent
# on every command for every user who never opted in.
hwip_cli_command "$HWIP_APPROVE_CLI_CAP_SEC"
# The answer, or the absence of one. `hwip ask` returns a single JSON shape for
# every outcome it gets to report, including its own failures; CLI_RC is for the
# ones it never got to (the CLI could not be started, or the outer cap killed it).
# Every flag takes its value in the `--flag=value` form: the command text is
# untrusted, and as a separate word one that starts with `--base-url=…` would be
# read as a flag of the CLI itself, not as the body.
ANSWER=$("${HWIP_CLI[@]}" ask \
    --title="Approve in $PROJECT?" \
    --body="$BODY" \
    --actions="approve:Approve,deny:Deny" \
    --timeout="$HWIP_APPROVE_DEADLINE_SEC" 2>/dev/null)
CLI_RC=$?

ACTION=$(jq -r '.actionId // empty' <<< "$ANSWER" 2>/dev/null)
# `hwip ask` says why there was no answer (cli ask.ts): cancelled on the
# phone, timeout, or error with the last error. An older CLI without `reason`
# falls through to the error-or-timeout guess below.
UNANSWERED=$(jq -r '.reason // empty' <<< "$ANSWER" 2>/dev/null)

if [ "$ACTION" = approve ]; then
    hwip_hook_decision allow "Approved from the user's phone."
    exit 0
fi

# Everything else is a refusal: an explicit Deny, a timeout, an unreachable
# server, free text instead of a button. The reason says which, so the model
# reports something truthful rather than guessing why it was stopped.
REASON="The user declined this command from their phone."
case "$ACTION" in
    deny) : ;;
    *)
        ERR=$(jq -r '.error // empty' <<< "$ANSWER" 2>/dev/null)
        case "$UNANSWERED" in
            cancelled)
                REASON="The user cancelled this approval request from their phone. Do not retry it — ask the user what they want instead." ;;
            timeout)
                REASON="No approval came back within ${HWIP_APPROVE_DEADLINE_SEC}s. Blocked because this command is hard to undo — ask the user directly before retrying." ;;
            error)
                REASON="Could not reach the user for approval (${ERR:-unknown error}). Blocked because this command is hard to undo — ask the user directly before retrying." ;;
            *)
                # No `reason` from the CLI. What the shell saw of it says what happened:
                # 126/127 = never started (not on PATH, not executable, or a command
                # too long to pass), 124 = the outer cap killed it. Only a CLI that
                # ran to the end and said nothing gets the deadline message.
                if [ -n "$ERR" ]; then
                    REASON="Could not reach the user for approval ($ERR). Blocked because this command is hard to undo — ask the user directly before retrying."
                elif [ "$CLI_RC" -eq 126 ] || [ "$CLI_RC" -eq 127 ]; then
                    REASON="Could not start the hwip CLI (exit $CLI_RC): check that hwip, or npx, is installed and on PATH. Blocked because this command is hard to undo — ask the user directly before retrying."
                elif [ "$CLI_RC" -eq 124 ]; then
                    REASON="The hwip CLI did not finish within ${HWIP_APPROVE_CLI_CAP_SEC}s. Blocked because this command is hard to undo — ask the user directly before retrying."
                elif [ "$CLI_RC" -ne 0 ]; then
                    REASON="The hwip CLI exited with code $CLI_RC and no answer. Blocked because this command is hard to undo — ask the user directly before retrying."
                else
                    REASON="No approval came back within ${HWIP_APPROVE_DEADLINE_SEC}s. Blocked because this command is hard to undo — ask the user directly before retrying."
                fi ;;
        esac
        ;;
esac

hwip_hook_decision deny "$REASON"
exit 0
