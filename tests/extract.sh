#!/usr/bin/env bash
# Extract selected functions from crusty.sh (by name) and print them to
# stdout. Used by the unit-test runner to test pure functions WITHOUT
# executing crusty.sh's top-level side effects (main/traps/globals).
#
# End condition: the function body ends at the first line consisting of
# exactly "}" at column 0 (this project's style — compound commands use
# fi/done/esac, so a lone "}" at column 0 is always the function close).
set -uo pipefail

SCRIPT="$(dirname "$0")/../crusty.sh"

started=0
while IFS= read -r line; do
    if [[ "$started" == 0 ]]; then
        if [[ "$line" == "$1()"* ]]; then
            started=1
            printf '%s\n' "$line"
        fi
        continue
    fi
    printf '%s\n' "$line"
    if [[ "$line" == "}" ]]; then
        exit 0
    fi
done < "$SCRIPT"
echo "WARN: function '$1' not found or unterminated" >&2
exit 1