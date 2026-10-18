#!/usr/bin/env bash
# Fixture-based tests for hooks/hwip-herdr.sh.
#
# `tmux` and `herdr` are stubs: tmux answers the session's herdr options from
# $OPTS, herdr appends its argv to a log. The rows that matter most are the
# no-op ones — outside tmux, outside herdr, a tool call that changes nothing —
# because the hook runs on every tool call of every session.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/../hooks/hwip-herdr.sh"
[ -f "$HOOK_SCRIPT" ] || { echo "hook script not found: $HOOK_SCRIPT" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STUB_DIR="$WORK/stub"
LOG="$WORK/herdr.log"
mkdir -p "$STUB_DIR"

# Like tmux 3.5a `display-message -p`: a control character other than tab or
# newline comes out as a literal octal escape (`\x1f` -> `\037`).
cat > "$STUB_DIR/tmux" <<'EOF'
#!/bin/bash
printf '%b\n' "$OPTS" | perl -pe 's/([\x00-\x08\x0b-\x1f\x7f])/sprintf("\\%03o", ord $1)/ge'
EOF
cat > "$STUB_DIR/herdr" <<EOF
#!/bin/bash
echo "\$HERDR_SOCKET_PATH \$*" >> "$LOG"
EOF
chmod +x "$STUB_DIR/tmux" "$STUB_DIR/herdr"

PASS=0; FAIL=0; TOTAL=0
FAILED_TESTS=()
check() {
    local desc="$1" expected="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if [ "$expected" = "$actual" ]; then echo "  ✓ $desc"; PASS=$((PASS + 1));
    else echo "  ✗ $desc"; echo "      expected: $expected"; echo "      actual:   $actual"; FAIL=$((FAIL + 1)); FAILED_TESTS+=("$desc"); fi
}

IN_HERDR="wF:p1\n/sock\n$STUB_DIR/herdr"

# Run the hook, then wait for the detached herdr call (or give up quietly).
run() {
    local before after i input="${INPUT:-}"
    [ -n "$input" ] || input='{}'
    before=$(wc -l < "$LOG")
    printf '%s' "$input" | env PATH="$STUB_DIR:/usr/bin:/bin" CLAUDE_CODE_ENTRYPOINT="${CLAUDE_CODE_ENTRYPOINT:-cli}" XDG_STATE_HOME="$WORK/tmp" TMUX="${T-/tmp/tmux,1,0}" TMUX_PANE="${P:-%1}" OPTS="$OPTS" \
        bash "$HOOK_SCRIPT" "$1"
    for i in $(seq 1 20); do
        after=$(wc -l < "$LOG")
        [ "$after" -gt "$before" ] && break
        sleep 0.05
    done
}
last() { tail -1 "$LOG" | sed -E 's/--seq [0-9]+/--seq N/'; }
calls() { wc -l < "$LOG" | tr -d ' '; }
reset() { rm -rf "$WORK/tmp"; mkdir -p "$WORK/tmp"; : > "$LOG"; }

echo "no-ops"
reset
OPTS="$IN_HERDR" T='' run working
check "outside tmux: nothing sent" 0 "$(calls)"
OPTS="\n\n" run working
check "tmux session without herdr options: nothing sent" 0 "$(calls)"
OPTS="$IN_HERDR" run tool
check "tool call with nothing blocked: nothing sent" 0 "$(calls)"
CLAUDE_CODE_ENTRYPOINT=sdk-cli OPTS="$IN_HERDR" run start
check "headless claude -p in the pane: nothing sent" 0 "$(calls)"

echo "lifecycle"
reset
OPTS="$IN_HERDR" run start
check "start claims the pane as idle" "/sock pane report-agent wF:p1 --source hwip --agent hwip cc --state idle --seq N" "$(last)"
OPTS="$IN_HERDR" run working
check "prompt -> working" "/sock pane report-agent wF:p1 --source hwip --agent hwip cc --state working --seq N" "$(last)"
OPTS="$IN_HERDR" run working
check "same state again: not resent" 2 "$(calls)"
OPTS="$IN_HERDR" run tool
check "tool call while working: not resent" 2 "$(calls)"
OPTS="$IN_HERDR" run blocked
check "permission prompt -> blocked" "/sock pane report-agent wF:p1 --source hwip --agent hwip cc --state blocked --seq N" "$(last)"
OPTS="$IN_HERDR" run tool
check "tool runs after the prompt -> working" "/sock pane report-agent wF:p1 --source hwip --agent hwip cc --state working --seq N" "$(last)"
OPTS="$IN_HERDR" run idle
check "stop -> idle" "/sock pane report-agent wF:p1 --source hwip --agent hwip cc --state idle --seq N" "$(last)"
OPTS="$IN_HERDR" run end
check "session end releases the pane" "/sock pane release-agent wF:p1 --source hwip --agent hwip cc --seq N" "$(last)"

echo "seq"
seqs=$(grep -oE -- '--seq [0-9]+' "$LOG" | awk '{print $2}')
check "seq strictly increases" "$(printf '%s\n' "$seqs" | sort -n | uniq)" "$seqs"

echo "state file"
# The file is read back into arithmetic, so what is in it is data: a seq that is not a number must
# not run (`a[$(cmd)]` is evaluated by `$((...))`). It lives under the per-user state dir (gate.sh
# HWIP_STATE_DIR), not world-writable /tmp, where another local user could plant it first; the old
# $TMPDIR location is poisoned too, to show it is no longer read.
reset
printf '#!/bin/sh\ntouch "%s"\n' "$WORK/PWNED" > "$WORK/pwn"; chmod +x "$WORK/pwn"
for f in "$WORK/tmp/hwip-herdr/_1" "$WORK/tmp/hwip/herdr-_1"; do
    mkdir -p "$(dirname "$f")"
    printf '%s\n' "a[\$($WORK/pwn)] blocked wF:p1" > "$f"
done
OPTS="$IN_HERDR" run tool
check "non-numeric seq in the state file: not executed" 0 "$([ -e "$WORK/PWNED" ] && echo 1 || echo 0)"
check "non-numeric seq in the state file: still reported" "/sock pane report-agent wF:p1 --source hwip --agent hwip cc --state working --seq N" "$(last)"
check "state file rewritten with a number" 1 "$(awk '{print ($1 ~ /^[0-9]+$/) ? 1 : 0}' "$WORK/tmp/hwip/herdr-_1")"

echo "herdr restart"
# herdr drops every report when it restarts and recreates its socket when it starts. A state equal
# to the last one reported is resent once the socket is newer than that report.
reset
SOCK="$WORK/herdr.sock"; : > "$SOCK"
OPTS="wF:p1\n$SOCK\n$STUB_DIR/herdr" run idle
OPTS="wF:p1\n$SOCK\n$STUB_DIR/herdr" run idle
check "same state, same herdr: not resent" 1 "$(calls)"
touch -t 200001010000 "$WORK/tmp/hwip/herdr-_1"; touch -t 200101010000 "$SOCK"
OPTS="wF:p1\n$SOCK\n$STUB_DIR/herdr" run idle
check "same state after a herdr restart: resent" 2 "$(calls)"
reset
: > "$SOCK"
OPTS="wF:p1\n$SOCK\n$STUB_DIR/herdr" run working
touch -t 200001010000 "$WORK/tmp/hwip/herdr-_1"; touch -t 200101010000 "$SOCK"
OPTS="wF:p1\n$SOCK\n$STUB_DIR/herdr" run tool
check "tool call after a herdr restart: working resent" "2 $SOCK pane report-agent wF:p1 --source hwip --agent hwip cc --state working --seq N" "$(calls) $(last)"
OPTS="wF:p1\n$SOCK\n$STUB_DIR/herdr" run tool
check "next tool call: not resent" 2 "$(calls)"

echo "reattach"
reset
OPTS="$IN_HERDR" run working
OPTS="wF:p9\n/sock\n$STUB_DIR/herdr" run working
check "same state, new herdr pane: reported there" "/sock pane report-agent wF:p9 --source hwip --agent hwip cc --state working --seq N" "$(last)"

echo "bounds"
# herdr installed under a path with a space: the hook runs it as an array.
reset
SP="$WORK/with space"; mkdir -p "$SP"; cp "$STUB_DIR/herdr" "$SP/herdr"
OPTS="wF:p1\n/sock\n$SP/herdr" run working
check "herdr path with a space: reported" "/sock pane report-agent wF:p1 --source hwip --agent hwip cc --state working --seq N" "$(last)"

# A tmux that never answers is cut at 2 s, by whichever bound the machine has:
# `timeout`/`gtimeout` (when on PATH) or perl (stock macOS, which has no timeout).
hung() { # <label> <PATH>
    reset
    local start=$SECONDS elapsed
    echo '{}' | env PATH="$2" CLAUDE_CODE_ENTRYPOINT=cli XDG_STATE_HOME="$WORK/tmp" TMUX=/tmp/tmux,1,0 TMUX_PANE=%1 bash "$HOOK_SCRIPT" working
    elapsed=$((SECONDS - start))
    check "$1: hook gives up within 4 s" 1 "$([ "$elapsed" -le 4 ] && echo 1 || echo "0 (took ${elapsed}s)")"
    check "$1: nothing sent" 0 "$(calls)"
}
mkdir -p "$WORK/hung"
printf '#!/bin/bash\nsleep 30\n' > "$WORK/hung/tmux"
chmod +x "$WORK/hung/tmux"
TO=$(command -v timeout || command -v gtimeout || true)
if [ -n "$TO" ]; then
    hung "hung tmux, timeout on PATH" "$WORK/hung:$(dirname "$TO"):/usr/bin:/bin"
else
    echo "  - skipped the timeout row (no timeout/gtimeout)"
fi
if ! PATH=/usr/bin:/bin command -v timeout gtimeout >/dev/null 2>&1 && PATH=/usr/bin:/bin command -v perl >/dev/null 2>&1; then
    hung "hung tmux, only perl to bound it" "$WORK/hung:/usr/bin:/bin"
else
    echo "  - skipped the perl-only row (timeout in /usr/bin:/bin, or no perl)"
fi

echo "options"
# An empty or non-executable bin option: herdr from PATH (the stub dir is on PATH).
reset
OPTS="wF:p1\n/sock\n" run working
check "no bin option: herdr from PATH" "/sock pane report-agent wF:p1 --source hwip --agent hwip cc --state working --seq N" "$(last)"
OPTS="wF:p1\n/sock\n$WORK/not-there" run idle
check "bin option not executable: herdr from PATH" "/sock pane report-agent wF:p1 --source hwip --agent hwip cc --state idle --seq N" "$(last)"
# start re-claims the pane even when the state did not change (a restarted session).
reset
OPTS="$IN_HERDR" run start
OPTS="$IN_HERDR" run start
check "start twice: sent twice" 2 "$(calls)"

echo "session start"
# SessionStart fires on a compaction too, often mid-turn: reporting `idle` then would stick.
reset
OPTS="$IN_HERDR" run working
INPUT='{"hook_event_name":"SessionStart","source":"compact"}' OPTS="$IN_HERDR" run start
check "start from a compaction: nothing sent" 1 "$(calls)"
INPUT='{"source": "compact"}' OPTS="$IN_HERDR" run start
check "same, with a space after the colon: nothing sent" 1 "$(calls)"
INPUT='{"hook_event_name":"SessionStart","source":"startup"}' OPTS="$IN_HERDR" run start
check "start from a fresh session: claims the pane" "/sock pane report-agent wF:p1 --source hwip --agent hwip cc --state idle --seq N" "$(last)"

echo "empty fields"
reset
OPTS="\n/sock\n$STUB_DIR/herdr" run working
check "empty pane with a socket: not read as pane=socket" 0 "$(calls)"

echo
echo "$PASS/$TOTAL passed"
[ "$FAIL" -eq 0 ] || { printf '  failed: %s\n' "${FAILED_TESTS[@]}"; exit 1; }
