#!/usr/bin/env bash
# Generate a fixture with a long Korean assistant summary (>512 bytes).
# Run from the plugin/tests/ directory; output goes to fixtures/main-long-summary-ko.jsonl.
set -euo pipefail
OUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/main-long-summary-ko.jsonl"

LONG=$(python3 -c "print('가나다라마바사아자차카타파하 ' * 60)")
ESCAPED=$(printf '%s' "$LONG" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')

cat > "$OUT" <<EOF
{"type":"system","message":{"role":"system","content":"sys"}}
{"type":"user","message":{"role":"user","content":"긴 응답 부탁"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"a","name":"Read","input":{}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"a","content":"x"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"b","name":"Edit","input":{}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"b","content":"x"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":$ESCAPED}],"stop_reason":"end_turn"}}
EOF

echo "wrote $OUT ($(wc -l < "$OUT") lines, summary ~$(printf '%s' "$LONG" | wc -c) bytes)"
