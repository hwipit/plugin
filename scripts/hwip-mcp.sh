#!/bin/sh
# Starts the plugin's MCP server (.mcp.json runs this file).
#
# A global `hwip` keeps the in-process `hwip mcp` server, on the version the
# user installed. Without one (an `npx @hwip/cli install` user) it falls back
# to npx, pinned to an exact version: the plugin directory blocks an unpinned
# launcher. Keep HWIP_CLI_VERSION equal to the pin in hooks/gate.sh
# (tests/test-mcp-launch.sh checks it) and raise both with each @hwip/cli release.
#
# The API key is not passed here. The CLI reads HWIP_API_KEY from the
# environment Claude Code passes down, else apiKey in ~/.hwip/config.json.
HWIP_CLI_VERSION=0.1.19
command -v hwip >/dev/null 2>&1 && exec hwip mcp
exec npx -y "@hwip/cli@$HWIP_CLI_VERSION" mcp
