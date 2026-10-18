#!/usr/bin/env bash
# Report Claude Code's state to herdr (https://herdr.dev) for a `hwip cc` session.
#
# herdr finds agents by a pane's foreground process. In a `hwip cc` pane that is
# the tmux client — Claude Code runs under the tmux server — so the agent never
# shows in herdr's sidebar. herdr's answer for agents it cannot see is the
# report API (`herdr pane report-agent`), which this hook drives from Claude
# Code's own events.
#
# Which herdr pane: the CLI wrapper records it on every attach as tmux session
# options (`@hwip_herdr_pane` · `@hwip_herdr_socket` · `@hwip_herdr_bin`) and
# clears them on an attach from outside herdr. Read from tmux, not this process's env, because the agent
# outlives the pane it was started in. No options -> not in herdr -> no-op, and
# that includes plain `claude` in a herdr pane, which herdr detects itself.
#
# Usage: hwip-herdr.sh <start|working|idle|blocked|tool|end>
#   tool — PostToolUse: back to `working` only if the last report was `blocked`
#          (a permission prompt or a question was answered).
#
# Never slows Claude Code down: herdr runs in the background, failures are
# ignored, and a state equal to the last one reported is not sent again — unless
# herdr restarted since, which drops every report it held.

# Hook input: only SessionStart's `source` is read, so only `start` keeps it. Every
# other event drains it — with `cat`, not a builtin `read`: PostToolUse input carries
# the tool's response, and a builtin read of 1 MiB takes ~7x as long as `cat` does.
input=''
if [ "${1:-}" = start ]; then input="$(cat)"; else cat >/dev/null; fi

[ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] || exit 0
# Interactive only. A `claude -p` run from a shell in this pane inherits
# TMUX_PANE, and its SessionEnd would release the pane's real agent. Claude Code
# sets `cli` for the TUI and `sdk-cli` for -p (measured 2026-10-02); unset is an
# older build, which is interactive more often than not.
[ "${CLAUDE_CODE_ENTRYPOINT:-cli}" = cli ] || exit 0

event="${1:-}"
# SessionStart also fires on a compaction. That is mid-turn when auto-compact runs, and
# nothing after it would report `working` again (the hot path below skips unchanged
# state), so a compaction reports nothing.
[ "$event" = start ] && [[ "$input" =~ \"source\"[[:space:]]*:[[:space:]]*\"compact\" ]] && exit 0
# Per-user, the value gate.sh gives HWIP_STATE_DIR (spelled out: this runs before gate.sh is
# sourced). Not $TMPDIR or /tmp — world-writable on Linux, where another local user could plant
# the file first, and its contents go into arithmetic below.
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/hwip"
state_file="$state_dir/herdr-${TMUX_PANE//[^A-Za-z0-9]/_}"

last_seq=0 last_state='' last_pane='' last_sock=''
# The socket is last: `read` gives the final name the rest of the line, so a path with spaces survives.
[ -f "$state_file" ] && read -r last_seq last_state last_pane last_sock <"$state_file"
# A seq that is not a number is no seq: `$((last_seq + 1))` would run `a[$(cmd)]`. The other
# fields are only compared as strings or tested as a path.
case "$last_seq" in '' | *[!0-9]*) last_seq=0 ;; esac
# herdr forgets every report when it restarts, and it recreates its socket when it starts, so a
# socket newer than the last report means that report is gone: send the state again. A `test`
# builtin — no fork on the hot path below.
restarted=''
[ -n "$last_sock" ] && [ "$last_sock" -nt "$state_file" ] && restarted=1 last_state=''

# The hot path: every tool call lands here. Skip the tmux round trip unless it
# can change something.
[ "$event" = tool ] && [ -z "$restarted" ] && [ "$last_state" != blocked ] && exit 0

command -v tmux >/dev/null 2>&1 || exit 0
# A tmux that never answers must not eat the hook's 5 s cap (plugin.json): bound
# it the way the other hooks bound their calls — gate.sh `hwip_bound_prefix`
# (timeout, gtimeout, else perl: stock macOS has only perl), an array, so nothing
# is word-split. Sourced here, past the hot path above, so a tool call that changes
# nothing never loads it.
. "$(dirname "${BASH_SOURCE[0]}")/gate.sh"
hwip_bound_prefix 2
# One option per line. Not tab: tab is IFS whitespace, so an empty field would collapse into its
# neighbour. Not another control character: `display-message -p` prints one as a literal octal
# escape (`\x1f` -> `\037`, tmux 3.5a), so the three values arrived as one.
{ IFS= read -r pane; IFS= read -r sock; IFS= read -r bin; } < <(
    "${HWIP_BOUND[@]}" tmux display-message -p -t "$TMUX_PANE" $'#{@hwip_herdr_pane}\n#{@hwip_herdr_socket}\n#{@hwip_herdr_bin}' 2>/dev/null
)
[ -n "${pane:-}" ] && [ -n "${sock:-}" ] || exit 0
[ -n "${bin:-}" ] && [ -x "$bin" ] || bin="$(command -v herdr)" || exit 0

case "$event" in
    start | idle) state=idle ;;
    working | tool) state=working ;;
    blocked) state=blocked ;;
    end) state=released ;;
    *) exit 0 ;;
esac

# Reattached from another herdr pane: the last report went somewhere else.
[ "$pane" != "$last_pane" ] && last_state=''
[ "$event" != start ] && [ "$state" = "$last_state" ] && exit 0

# herdr drops a report whose seq is not above the last one it accepted from
# this source, so seq must grow across sessions and restarts: microseconds since
# the epoch (perl ships with macOS; `date +%N` does not), bumped past the last.
seq="$(perl -MTime::HiRes=time -e 'printf "%.0f", time * 1e6' 2>/dev/null)"
[ -n "$seq" ] || seq="$(date +%s)000000"
[ "$seq" -gt "$last_seq" ] 2>/dev/null || seq=$((last_seq + 1))

mkdir -p "$state_dir" 2>/dev/null
if [ "$state" = released ]; then
    rm -f "$state_file"
    set -- pane release-agent "$pane" --source hwip --agent 'hwip cc' --seq "$seq"
else
    printf '%s %s %s %s\n' "$seq" "$state" "$pane" "$sock" >"$state_file"
    set -- pane report-agent "$pane" --source hwip --agent 'hwip cc' --state "$state" --seq "$seq"
fi

# Detached: the hook returns at once. Out-of-order arrivals are harmless — the
# seq above makes herdr keep the newest.
HERDR_SOCKET_PATH="$sock" nohup "$bin" "$@" >/dev/null 2>&1 &
exit 0
