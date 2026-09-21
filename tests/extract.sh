#!/usr/bin/env bash
# Extract selected functions from crusty.sh (by name) and print them to
# stdout. Used by the unit-test runner to test pure functions WITHOUT
# executing crusty.sh's top-level side effects (main/traps/globals).
#
# End condition: the function body ends at the first line consisting of
# exactly "}" at column 0 (this project's style — compound commands use
# fi/done/esac, so a lone "}" at column 0 is always the function close).
# EXCEPTION: "}" lines INSIDE a heredoc body are content, not the close
# (e.g. maint_script_content embeds a whole script with its own col-0
# braces), so the extractor tracks heredoc openers/delimiters.
set -uo pipefail

SCRIPT="$(dirname "$0")/../crusty.sh"

started=0
in_heredoc=0
delim=""
while IFS= read -r line; do
    if [[ "$started" == 0 ]]; then
        if [[ "$line" == "$1()"* ]]; then
            started=1
            printf '%s\n' "$line"
        fi
        continue
    fi
    printf '%s\n' "$line"
    if [[ "$in_heredoc" == 1 ]]; then
        # the terminator is the delimiter alone on its line
        if [[ "$line" == "$delim" ]]; then
            in_heredoc=0
        fi
        continue
    fi
    # heredoc opener: << or <<- + optional whitespace/quote + word delim.
    # Herestrings (<<<) do not match: after "<<" comes "<", which is
    # neither "-", whitespace, a quote, nor a word character.
    if [[ "$line" == *'<'*'<'* ]]; then
        d=$(printf '%s' "$line" \
            | grep -oE '<<-?[[:space:]]*["'"'"']?[A-Za-z_][A-Za-z0-9_]*' \
            | head -n 1)
        if [[ -n "$d" ]]; then
            d="${d#<<}"
            d="${d#<-}"
            d="${d//[[:space:]]/}"
            d="${d//\"/}"
            d="${d//\'}"
            delim="$d"
            in_heredoc=1
            continue
        fi
    fi
    if [[ "$line" == "}" ]]; then
        exit 0
    fi
done < "$SCRIPT"
echo "WARN: function '$1' not found or unterminated" >&2
exit 1
