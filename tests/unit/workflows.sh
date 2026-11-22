#!/usr/bin/env bash
# Checks that automerge re-evaluates a pull request whenever one of its
# required checks can have turned green (#70): every workflow that sets a
# required check of develop (.github/settings.yml), as a job of that name or
# as a commit status it posts with `context=`, is listed in the
# `workflow_run` trigger of .github/workflows/automerge.yaml, and every name
# listed there is a workflow that exists. The checks are set with
# GITHUB_TOKEN, whose `status` and `check_suite` events start no workflow, so
# a producer missing from the list leaves a pull request open with every
# check green. Also checks that every file a failure of the VM tests names is
# uploaded by the job of vm-tests.yml that runs the script (#110). Reads the
# YAML files and the scripts only; needs PyYAML.
#
# Usage: tests/unit/workflows.sh
set -uo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)

# One line per finding: "ok <text>" or "FAIL <text>".
output=$(python3 - "$root" <<'EOF'
import fnmatch
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

automerge_doc = load(workflows / "automerge.yaml")
run_trigger = triggers(automerge_doc).get("workflow_run") or {}
listened = run_trigger.get("workflows") or []
if isinstance(listened, str):
    listened = [listened]
types = run_trigger.get("types") or []
if "completed" in types:
    print("ok automerge runs when a listed workflow has completed")
else:
    print("FAIL automerge's workflow_run trigger lacks the type completed")
# The job's condition must let through the runs of a pull request: ci and
# vm-tests run on pull_request, vm-gate on pull_request_target.
condition = str((automerge_doc["jobs"]["automerge"]).get("if", ""))
for event in ("pull_request", "pull_request_target"):
    if not condition or f"== '{event}'" in condition:
        print(f"ok automerge takes a workflow_run of a {event} event")
    else:
        print(f"FAIL automerge's condition drops a workflow_run of a {event} event")

names = set()
produced = set()
for path in sorted(workflows.glob("*.y*ml")):
    if path.name == "automerge.yaml":
        continue
    text = path.read_text()
    doc = yaml.safe_load(text) or {}
    # Without a name, workflow_run knows a workflow by its path.
    name = doc.get("name", f".github/workflows/{path.name}")
    names.add(name)
    jobs = doc.get("jobs") or {}
    sets = [c for c in contexts
            if any((job or {}).get("name", job_id) == c for job_id, job in jobs.items())
            or re.search(r"context=[\"']?" + re.escape(c) + r"(?![\w-])", text)]
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

# A file that a failure of the VM tests names ("see d0.disk.log") is one the
# job running that script uploads with its results (#110: the disk build's
# log was named but never uploaded). Each script is checked against the job
# that runs it; a helper of run.sh that update.sh or data-disk.sh call is
# checked against the boot job only.
vm_doc = load(workflows / "vm-tests.yml")
vm_jobs = vm_doc.get("jobs") or {}
for job_id, script in (("boot", "run.sh"), ("update", "update.sh"), ("data-disk", "data-disk.sh")):
    globs = []
    for step in (vm_jobs.get(job_id) or {}).get("steps") or []:
        if str(step.get("uses", "")).startswith("actions/upload-artifact@") and \
                str((step.get("with") or {}).get("name", "")).startswith("vm-results-"):
            globs += str(step["with"].get("path", "")).split()
    named = set()
    for line in (root / "tests" / "boot" / script).read_text().splitlines():
        _, see, rest = line.partition("see ")
        if see:
            named.update(re.findall(r"[\w${}-]+(?:\.[\w-]+)*\.(?:txt|log|ppm)\b", rest))
    for f in sorted(named):
        example = ".build/boot/" + re.sub(r"\$\{?\w+\}?", "x", f)
        if any(fnmatch.fnmatch(example, g) for g in globs):
            print(f"ok tests/boot/{script} names {f}, and the job {job_id} uploads it")
        else:
            print(f"FAIL tests/boot/{script} names {f} in a failure, but the job {job_id} of vm-tests.yml does not upload it")
EOF
) || { echo "FAIL the workflow files could not be read"; exit 1; }

printf '%s\n' "$output" | sed -e 's/^ok /ok    /' -e 's/^FAIL /FAIL  /'
failures=$(grep -c '^FAIL ' <<<"$output" || true)
if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
