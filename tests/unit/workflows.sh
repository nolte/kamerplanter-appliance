#!/usr/bin/env bash
# Checks that automerge re-evaluates a pull request whenever one of its
# required checks can have turned green (#70): every workflow that sets a
# required check of develop (.github/settings.yml), as a job of that name or
# as a commit status it posts with `context=`, is listed in the
# `workflow_run` trigger of .github/workflows/automerge.yaml, and every name
# listed there is a workflow that exists. The checks are set with
# GITHUB_TOKEN, whose `status` and `check_suite` events start no workflow, so
# a producer missing from the list leaves a pull request open with every
# check green. A workflow that runs on workflow_run itself names no pull
# request in its own run, so it calls automerge's reusable workflow instead
# of being listed (#51). Also checks that no workflow running the pull
# request's own code (pull_request) writes a required commit status, that
# the workflows running as develop has them (pull_request_target,
# workflow_run) check out no code and keep the event out of their scripts
# (#51), and that every file a failure of the VM tests names is uploaded by
# the job of vm-tests.yml that runs the script (#110). Reads the YAML files
# and the scripts only; needs PyYAML.
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
# The job's condition must let through the runs of a pull request: ci runs
# on pull_request, vm-gate on pull_request_target.
condition = str((automerge_doc["jobs"]["automerge"]).get("if", ""))
for event in ("pull_request", "pull_request_target"):
    if not condition or f"== '{event}'" in condition:
        print(f"ok automerge takes a workflow_run of a {event} event")
    else:
        print(f"FAIL automerge's condition drops a workflow_run of a {event} event")

automerge_uses = str(automerge_doc["jobs"]["automerge"].get("uses", ""))

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
    on = triggers(doc)
    if isinstance(on, (str, list)):
        on = {e: None for e in ([on] if isinstance(on, str) else on)}
    # A required check is a job of that name (a check run of the job itself)
    # or a commit status the workflow posts with context=.
    statuses = [c for c in contexts
                if re.search(r"context\\?[\"']?\s*[=:]\s*\\?[\"']?" + re.escape(c) + r"(?![\w-])", text)]
    sets = [c for c in contexts
            if any((job or {}).get("name", job_id) == c for job_id, job in jobs.items())
            or c in statuses]
    for c in statuses:
        # Only pull_request_target and workflow_run run as develop has them.
        # pull_request, push or workflow_dispatch on a branch, and a
        # workflow_call from one of those run the branch's own file, which
        # could post the required status with whatever state it likes (#51).
        foreign = sorted(set(on) - {"pull_request_target", "workflow_run"})
        if foreign:
            print(f"FAIL {path.name} ({name}) posts the required status {c} and runs on "
                  f"{', '.join(foreign)}, as the branch has it")
        else:
            print(f"ok {path.name} ({name}) posts the required status {c} and runs as develop has it")
    for c in sets:
        produced.add(c)
        if "workflow_run" in on:
            # Only a pull request's run of vm-tests.yml itself, not a push,
            # a run by hand or another file named like it, may set it.
            watched = (on.get("workflow_run") or {}).get("workflows") or []
            paths = [f".github/workflows/{p.name}" for p in workflows.glob("*.y*ml")
                     if (yaml.safe_load(p.read_text()) or {}).get("name") in watched]
            guarded = [job_id for job_id, job in jobs.items()
                       if re.search(r"context=" + re.escape(c) + r"(?![\w-])", str((job or {}).get("steps", "")))
                       and "github.event.workflow_run.event == 'pull_request'" in str(job.get("if", ""))
                       and any(f"github.event.workflow_run.path == '{p}'" in str(job.get("if", ""))
                               for p in paths)]
            if guarded:
                print(f"ok {path.name} ({name}) sets {c} only for a pull request's run "
                      f"of a named workflow file ({guarded[0]})")
            else:
                print(f"FAIL {path.name} ({name}) runs on workflow_run and sets {c}, but the job's "
                      "condition does not require workflow_run.event pull_request and its path")
            calls = [job_id for job_id, job in jobs.items()
                     if str((job or {}).get("uses", "")) == automerge_uses and job.get("needs")]
            if calls:
                print(f"ok {path.name} ({name}) runs on workflow_run, sets {c} and "
                      f"calls automerge's reusable workflow after it ({calls[0]})")
            else:
                print(f"FAIL {path.name} ({name}) runs on workflow_run and sets {c}, but no "
                      "job of it calls automerge's reusable workflow after that")
        elif name in listened:
            print(f"ok {path.name} ({name}) sets {c} and automerge listens for it")
        else:
            print(f"FAIL {path.name} ({name}) sets the required check {c}, "
                  "but automerge.yaml does not list it under workflow_run")
    # A workflow on pull_request_target or workflow_run runs with develop's
    # token on a pull request's event: it checks out no code, and the
    # event's fields reach its scripts through env only.
    if "pull_request_target" in on or "workflow_run" in on:
        steps = [s for job in jobs.values() for s in ((job or {}).get("steps") or [])]
        # Code or artifacts of the pull request: a checkout, a fetch, or the
        # artifacts of the triggering run (artifact poisoning).
        fetches = [s for s in steps
                   if str(s.get("uses", "")).startswith(("actions/checkout@", "actions/download-artifact@"))
                   or re.search(r"\b(gh (run download|pr checkout)|git (clone|fetch))\b", str(s.get("run", "")))]
        if fetches:
            print(f"FAIL {path.name} ({name}) runs as develop has it and fetches code or artifacts")
        else:
            print(f"ok {path.name} ({name}) runs as develop has it and fetches no code or artifacts")
        if any("${{" in str(s.get("run", "")) or "${{" in str((s.get("with") or {}).get("script", ""))
               for s in steps):
            print(f"FAIL {path.name} ({name}) runs as develop has it and expands an "
                  "expression inside a script")
        else:
            print(f"ok {path.name} ({name}) runs as develop has it and passes the event through env")

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
