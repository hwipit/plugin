#!/usr/bin/env bash
# Runs every test-*.sh file under tests/ in alphabetical order. Returns
# non-zero if any sub-suite fails.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITES=("$SCRIPT_DIR"/test-*.sh)

OVERALL=0
TOTAL_FILES=0
PASSED_FILES=0

for suite in "${SUITES[@]}"; do
    [ -f "$suite" ] || continue
    TOTAL_FILES=$((TOTAL_FILES + 1))
    echo
    echo "── $(basename "$suite") ──────────────────────────────────────"
    if bash "$suite"; then
        PASSED_FILES=$((PASSED_FILES + 1))
    else
        OVERALL=1
    fi
done

echo
echo "============================================================"
echo "Suites: $PASSED_FILES/$TOTAL_FILES passed"
echo "============================================================"
exit "$OVERALL"
