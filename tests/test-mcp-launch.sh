#!/usr/bin/env bash
# Tests for the MCP server launch command in .mcp.json.
#
# Guards this regression: the README and /hwip-config offer `npx @hwip/cli
# install` as a notifications-only setup, which leaves no `hwip` on PATH. A bare
# `"command": "hwip"` then fails to spawn and the plugin's MCP server never
# starts. The launch line must use `hwip` when it exists and fall back to
# `npx -y @hwip/cli` when it does not.
#
# Both binaries are stubs on a private PATH — no real CLI is ever run.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP_JSON="$SCRIPT_DIR/../.mcp.json"

[ -f "$MCP_JSON" ] || { echo ".mcp.json not found: $MCP_JSON" >&2; exit 1; }
command -v node >/dev/null || { echo "node required" >&2; exit 1; }

PASS=0; FAIL=0; TOTAL=0
FAILED_TESTS=()

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if [ "$expected" = "$actual" ]; then
        echo "  ✓ $desc"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $desc (expected '$expected', got '$actual')"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$desc")
    fi
}

# command + args as one NUL-separated argv, so the test runs exactly what
# Claude Code would spawn.
LAUNCH=()
while IFS= read -r -d '' part; do LAUNCH+=("$part"); done < <(node -e '
const s = require(process.argv[1]).mcpServers.hwip;
process.stdout.write([s.command, ...s.args].map((a) => a + "\0").join(""));
' "$MCP_JSON")

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/with" "$TMP/without"

stub() {
    printf '#!/bin/sh\necho "%s $*"\n' "$2" > "$1"
    chmod +x "$1"
}
stub "$TMP/with/hwip" hwip
stub "$TMP/with/npx" npx
stub "$TMP/without/npx" npx

# /usr/bin:/bin supply sh; a real hwip there would make the fallback case lie.
for d in /usr/bin /bin; do
    [ -e "$d/hwip" ] && { echo "skip: $d/hwip exists" >&2; exit 0; }
done

OUT=$(PATH="$TMP/with:/usr/bin:/bin" "${LAUNCH[@]}")
assert_eq "hwip on PATH → hwip mcp" "hwip mcp" "$OUT"

OUT=$(PATH="$TMP/without:/usr/bin:/bin" "${LAUNCH[@]}")
assert_eq "no hwip on PATH → npx -y @hwip/cli mcp" "npx -y @hwip/cli mcp" "$OUT"

echo
echo "MCP launch: $PASS/$TOTAL passed"
if [ "$FAIL" -gt 0 ]; then
    printf 'Failed: %s\n' "${FAILED_TESTS[@]}"
    exit 1
fi
