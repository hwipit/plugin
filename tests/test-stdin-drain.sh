#!/usr/bin/env bash
# Every shell hook must read its whole stdin before it can exit.
#
# Guards this regression: a hook that exits early (no jq, muted, not enabled)
# while Claude Code is still writing the hook input leaves the writer to take a
# SIGPIPE. The cheapest early exit is the jq check, so each hook runs here on a
# PATH that holds only `cat` — no jq — and is fed more input than a pipe
# buffers. The writer must finish cleanly (exit 0, not 141).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$SCRIPT_DIR/../hooks"
BASH_BIN=$(command -v bash)

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
NOJQ="$WORK/nojq"
mkdir -p "$NOJQ"
ln -s "$(command -v cat)" "$NOJQ/cat"

PASS=0; FAIL=0; TOTAL=0
FAILED_TESTS=()

for hook in hwip-stop.sh hwip-ask.sh hwip-approve.sh hwip-remote.sh hwip-herdr.sh; do
    TOTAL=$((TOTAL + 1))
    # 1 MiB of input, well past the 64 KiB a pipe holds without a reader.
    head -c 1048576 /dev/zero \
      | env PATH="$NOJQ" "$BASH_BIN" "$HOOKS_DIR/$hook" >/dev/null 2>&1
    writer=${PIPESTATUS[0]}
    if [ "$writer" -eq 0 ]; then
        echo "  ✓ $hook drains stdin before exiting"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $hook drains stdin before exiting (writer exit $writer)"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$hook")
    fi
done

echo
echo "Stdin drain: $PASS/$TOTAL passed"
if [ "$FAIL" -gt 0 ]; then
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
    exit 1
fi
