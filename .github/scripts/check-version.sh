#!/usr/bin/env bash
# Checks a release tag or build version before it becomes part of file and
# artifact names or an argument of `gh`. The one copy of the rule, called by
# release-publish.yml (the tag, before the first `gh release` call) and by
# disk-image.yml (the version, whatever triggered it).
#
# Usage: check-version.sh <label> <value>
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 <label> <value>" >&2
  exit 2
fi
label=$1
value=$2

# The first character is a letter or digit: `gh` reads a value that starts
# with '-' as an option (`gh release view -Rx` parses as `--repo x`).
if [[ ! $value =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]]; then
  # Quoted with %q: a raw newline in the value would start a workflow command.
  printf "::error::%s %q must start with a letter or digit and may only contain letters, digits, '.', '_' and '-'\n" "$label" "$value"
  exit 1
fi
