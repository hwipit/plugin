#!/usr/bin/env bash
# The suites must not share state with another run of themselves, or with another session running
# them at the same time. The hooks key their legacy files on a hash of the project directory
# (/tmp/hwip-muted-<hash>, /tmp/hwip-pushmode-<hash>), so a project directory at a fixed path is the
# same project for every run: two runs of test-hwip-stop.sh set each other's push mode (12 of 12
# parallel runs failed), and a /tmp/hwip-muted-<hash> left for /tmp/test-project silenced 35 cases of
# test-hwip-ask.sh. And bash 3.2 gives the same $RANDOM in every `$(...)`, so a "unique" name built
# from it was one name for every call of a run.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$(basename "${BASH_SOURCE[0]}")"

PASS=0; FAIL=0; TOTAL=0
FAILED_TESTS=()
assert_none() { # <description> <pattern>
    TOTAL=$((TOTAL + 1))
    local hits
    hits=$(grep -nE -- "$2" "$SCRIPT_DIR"/test-*.sh 2>/dev/null | grep -v "^$SCRIPT_DIR/$SELF:" || true)
    if [ -z "$hits" ]; then echo "  ✓ $1"; PASS=$((PASS + 1));
    else echo "  ✗ $1"; echo "$hits" | sed 's/^/      /'; FAIL=$((FAIL + 1)); FAILED_TESTS+=("$1"); fi
}

echo "[no test names a project, or a state dir, that another run shares]"
assert_none "no project directory at the fixed path /tmp/test-project"       '/tmp/test-project'
assert_none "no CLAUDE_PROJECT_DIR=/tmp (the hash of /tmp is the same for every run)" 'CLAUDE_PROJECT_DIR=/tmp([[:space:]]|$)'
assert_none "no default project directory of /tmp"                            ':-/tmp[}"]'
assert_none "no state dir named by \$RANDOM (the same in every \$(...) on bash 3.2)" '\$RANDOM'

echo
echo "=========================================="
echo "Total: $TOTAL  |  Passed: $PASS  |  Failed: $FAIL"
echo "=========================================="
if [ "$FAIL" -gt 0 ]; then
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
    exit 1
fi
