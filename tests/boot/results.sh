#!/usr/bin/env bash
# Reads the results files the VM tests write (name, PASS/FAIL/SKIP, time,
# description; tab-separated). Used by .github/workflows/vm-tests.yml.
#
#   tests/boot/results.sh FILE
#       fails when FILE is missing or empty, or when a row is FAIL; a SKIP
#       does not fail. Each FAIL becomes an error annotation on GitHub.
#   tests/boot/results.sh --summary DIR
#       prints one Markdown table of every *.tsv below DIR, the first
#       directory level naming the job (an artifact per job).
set -euo pipefail

check() {
    local file=$1
    if [ ! -s "$file" ]; then
        echo "::error::no results in $file: the tests did not run to their end"
        return 1
    fi
    column -t -s $'\t' "$file"
    local failed
    failed=$(awk -F'\t' '$2 == "FAIL"' "$file")
    [ -z "$failed" ] && return 0
    while IFS=$'\t' read -r name _ _ text; do
        echo "::error title=$name::$text"
    done <<<"$failed"
    return 1
}

summary() {
    local dir=$1 job file
    local -A count=()
    echo "### VM tests"
    echo
    echo "| job | test | result | time | description |"
    echo "| --- | --- | --- | --- | --- |"
    while IFS= read -r file; do
        job=${file#"$dir"/}
        job=${job%%/*}
        while IFS=$'\t' read -r name result secs text; do
            count[$result]=$((${count[$result]:-0} + 1))
            text=${text//|/\\|}
            echo "| ${job#vm-results-} | $name | $result | $secs | $text |"
        done <"$file"
    done < <(find "$dir" -name '*.tsv' | sort)
    echo
    echo "PASS ${count[PASS]:-0}, FAIL ${count[FAIL]:-0}, SKIP ${count[SKIP]:-0}"
    for job in "$dir"/*/; do
        [ -d "$job" ] || continue
        [ -n "$(find "$job" -name '*.tsv' -size +0)" ] ||
            echo "No results from $(basename "$job" | sed "s/^vm-results-//")."
    done
}

case ${1-} in
    --summary) summary "${2:?usage: $0 --summary DIR}" ;;
    "") echo "usage: $0 FILE | --summary DIR" >&2; exit 2 ;;
    *) check "$1" ;;
esac
