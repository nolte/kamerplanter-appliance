#!/usr/bin/env bash
# Checks that automerge re-evaluates a pull request whenever one of its
# required checks can have turned green (#70): every workflow that sets a
# required check of develop (.github/settings.yml), as a job of that name or
# as a commit status it posts with `context=`, is listed in the
# `workflow_run` trigger of .github/workflows/automerge.yaml, and every name
# listed there is a workflow that exists. The checks are set with
# GITHUB_TOKEN, whose `status` and `check_suite` events start no workflow, so
# a producer missing from the list leaves a pull request open with every
# check green. Reads the YAML files only; needs PyYAML.
#
# Usage: tests/unit/workflows.sh
set -uo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)

# One line per finding: "ok <text>" or "FAIL <text>".
output=$(python3 - "$root" <<'EOF'
import pathlib
import re
import sys

import yaml

root = pathlib.Path(sys.argv[1])
workflows = root / ".github" / "workflows"


def load(path):
    return yaml.safe_load(path.read_text())


def triggers(doc):
    # YAML 1.1 reads the bare key `on` as true.
    return doc.get("on", doc.get(True)) or {}


settings = load(root / ".github" / "settings.yml")
develop = next(b for b in settings["branches"] if b["name"] == "develop")
contexts = develop["protection"]["required_status_checks"]["contexts"]

automerge = triggers(load(workflows / "automerge.yaml"))
listened = (automerge.get("workflow_run") or {}).get("workflows") or []

names = set()
produced = set()
for path in sorted(workflows.glob("*.y*ml")):
    if path.name == "automerge.yaml":
        continue
    text = path.read_text()
    doc = yaml.safe_load(text)
    name = doc.get("name", path.name)
    names.add(name)
    jobs = doc.get("jobs") or {}
    sets = [c for c in contexts
            if any((job or {}).get("name", job_id) == c for job_id, job in jobs.items())
            or re.search(r"context=" + re.escape(c) + r"\b", text)]
    for c in sets:
        produced.add(c)
        if name in listened:
            print(f"ok {path.name} ({name}) sets {c} and automerge listens for it")
        else:
            print(f"FAIL {path.name} ({name}) sets the required check {c}, "
                  "but automerge.yaml does not list it under workflow_run")

for c in contexts:
    if c not in produced:
        print(f"FAIL no workflow sets the required check {c}")
for name in listened:
    if name in names:
        print(f"ok automerge listens for the workflow {name}, which exists")
    else:
        print(f"FAIL automerge listens for the workflow {name}, which does not exist")
EOF
) || { echo "FAIL the workflow files could not be read"; exit 1; }

printf '%s\n' "$output" | sed -e 's/^ok /ok    /' -e 's/^FAIL /FAIL  /'
failures=$(grep -c '^FAIL ' <<<"$output" || true)
if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
