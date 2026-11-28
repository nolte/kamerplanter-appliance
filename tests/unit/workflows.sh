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
# the job of vm-tests.yml that runs the script (#110). Also checks who may
# reach the status at all (#130): no job of a workflow that runs as a branch
# or a pull request has it may write commit statuses, whichever step would
# do it; and the consent behind vm-gate, the label vm-tests: vm-gate.yml
# reads it from the API and not from the event (#145), is the only workflow
# that removes it, no workflow sets it, and vm-gate-finalize.yml writes its
# result only after it has read vm-gate's status of the commit and the
# label. And the runs of the VM tests (#152): every job of vm-tests.yml waits
# for the job consent, which reads the label from the API with a token that
# only reads, and runs on the same statuses of vm-gate as the other two
# scripts. And what the job consent cannot see (#180): it compares the run's
# commit with the head of the pull request, every suite job reads the label
# again in its first step, with a token that reads the code and the pull
# request and nothing else, and no job of vm-tests.yml may read the runs of
# Actions. What the scripts decide is checked by tests/unit/vm-gate.sh.
# Reads the YAML files and the scripts only; needs PyYAML.
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

# Only these events run a workflow as develop has it.
AS_DEVELOP = {"pull_request_target", "workflow_run"}


def events(doc):
    on = triggers(doc)
    if isinstance(on, (str, list)):
        on = {e: None for e in ([on] if isinstance(on, str) else on)}
    return on


def scripts(job):
    # Everything a job's steps execute: run scripts and inline scripts.
    return "\n".join(str(s.get("run", "")) + "\n" + str((s.get("with") or {}).get("script", ""))
                     for s in ((job or {}).get("steps") or []))


def grants(job, doc, scope):
    # Whether the job's token may write the scope. A job's permissions
    # replace the workflow's; None: neither level declares any, so the
    # repository's default applies, which no file here shows.
    perms = (job or {}).get("permissions", doc.get("permissions"))
    if perms is None:
        return None
    if isinstance(perms, str):
        return perms == "write-all"
    return perms.get(scope) == "write"


# The commit status vm-gate counts only from the GitHub Actions app
# (.github/settings.yml), so every token of a workflow is one that could set
# it. A workflow on any other event than the two above runs as the branch or
# the pull request has it: with statuses: write, any step of it, also one a
# pull request adds, could post the required status (#130). The check above
# on `context=` finds only the workflows that say so.
# Calls that set or remove a label, as gh, the REST API or github-script
# spell them. A text check: it keeps an honest change from adding one
# unnoticed, not a pull request that rewrites this file as well. It reads
# what the jobs of this repository's workflows execute; what a reusable
# workflow or an action does inside, and what an app outside the workflows
# does (Renovate, by renovate.json5), is not in these files.
ADDS_LABEL = r"--add-label|addLabels|setLabels|labels\[\]="
REMOVES_LABEL = r"--remove-label|removeLabel|removeAllLabels"
METHOD = r"(?:-X|--method|--request)[ \t=]*[\"']?([A-Za-z]+)"
# What makes a call without a method a POST: the fields of gh api, the data
# of curl.
FIELDS = r"(?<![\w-])(?:-[fFd]|--field|--raw-field|--input|--data(?:-[a-z]+)?|--json)(?![\w-])"
# The only removal there is: vm-gate.yml takes the label vm-tests away.
THE_REMOVAL = '-X DELETE "repos/$REPO/issues/$NUMBER/labels/vm-tests"'


def label_calls(text):
    # The logical lines of a script that set a label, and those that remove
    # one. A call of the REST API on a path .../labels counts by its
    # method, wherever on the line it stands; without one it sets a label
    # as soon as it sends fields, as gh api and curl do it.
    adds, removes = [], []
    for line in re.sub(r"\\\n[ \t]*", " ", text).splitlines():
        if line.lstrip().startswith("#"):
            continue
        if re.search(ADDS_LABEL, line):
            adds.append(line.strip())
        if re.search(REMOVES_LABEL, line):
            removes.append(line.strip())
        if re.search(r"/labels\b", line):
            methods = {m.upper() for m in re.findall(METHOD, line)}
            if methods & {"POST", "PUT", "PATCH"} or (not methods and re.search(FIELDS, line)):
                adds.append(line.strip())
            if "DELETE" in methods:
                removes.append(line.strip())
    return adds, removes


# The rule against its own sample (#167: a POST without -X and a method
# after the path were not seen).
label_sample = (
    ('gh api "repos/$REPO/issues/$NUMBER/labels" -f "labels[]=vm-tests"', "adds"),
    ('gh api "repos/$REPO/issues/$NUMBER/labels" -f name=vm-tests', "adds"),
    ('gh api "repos/$REPO/issues/$NUMBER/labels" --input labels.json', "adds"),
    ('gh api "repos/$REPO/issues/$NUMBER/labels" \\\n  -X POST', "adds"),
    ('gh api --method=PUT "repos/$REPO/issues/$NUMBER/labels"', "adds"),
    ('curl -d @labels.json "$API/issues/$NUMBER/labels"', "adds"),
    ('gh pr edit "$NUMBER" --add-label vm-tests', "adds"),
    ('gh api "repos/$REPO/issues/$NUMBER/labels/vm-tests" -X DELETE', "removes"),
    ('gh api --method DELETE "repos/$REPO/issues/$NUMBER/labels"', "removes"),
    ('gh pr edit "$NUMBER" --remove-label vm-tests', "removes"),
    ('gh api "repos/$REPO/issues/$NUMBER/labels?per_page=100" --jq ".[].name"', "reads"),
    ('gh api --paginate "repos/$REPO/issues/$NUMBER/labels"', "reads"),
    ('# gh api "repos/$REPO/issues/$NUMBER/labels" -f name=vm-tests', "reads"),
    ('gh api -X POST "repos/$REPO/statuses/$SHA" -f context=vm-gate', "reads"),
)
wrong = []
for call, expected in label_sample:
    adds, removes = label_calls(call)
    found = "adds" if adds and not removes else "removes" if removes and not adds else \
        "reads" if not adds and not removes else "both"
    if found != expected:
        wrong.append(f"{call!r} {found}, not {expected}")
if wrong:
    print(f"FAIL the rule for the calls that set or remove a label reads {'; '.join(wrong)}")
else:
    print("ok the rule for the calls that set or remove a label tells a POST without a method, "
          "a method after the path and a read apart")

branch_writers = 0
for path in sorted(workflows.glob("*.y*ml")):
    doc = yaml.safe_load(path.read_text()) or {}
    on = events(doc)
    jobs = doc.get("jobs") or {}
    foreign = sorted(set(on) - AS_DEVELOP)
    for job_id, job in jobs.items():
        may = grants(job, doc, "statuses")
        if foreign and may is None:
            branch_writers += 1
            print(f"FAIL {path.name}: the job {job_id} declares no permissions, so the repository's "
                  f"default decides whether it may write commit statuses, and it runs on {', '.join(foreign)}")
        elif foreign and may:
            branch_writers += 1
            print(f"FAIL {path.name}: the job {job_id} may write commit statuses and runs on "
                  f"{', '.join(foreign)}, as the branch has it")
        elif may:
            print(f"ok {path.name}: the job {job_id} may write commit statuses and runs as develop has it")
        # The label vm-tests is a consent (a person's, or Renovate's by
        # renovate.json5): no workflow sets it, and only vm-gate.yml takes
        # it away.
        adds, removes = label_calls(scripts(job))
        # An action or a reusable workflow that is a labeler by its name,
        # as a step or as the job itself.
        labelers = [str(u) for u in [(job or {}).get("uses")] + [s.get("uses") for s in ((job or {}).get("steps") or [])]
                    if re.search(r"label", str(u or ""), re.I)]
        if adds or labelers:
            print(f"FAIL {path.name}: the job {job_id} sets a label; no workflow may set vm-tests")
        # vm-gate.yml removes one label, in one call; any other removal,
        # there as well, is one too many.
        if path.name == "vm-gate.yml":
            removes = [line for line in removes if THE_REMOVAL not in line]
        if removes:
            print(f"FAIL {path.name}: the job {job_id} removes a label; only vm-gate.yml removes "
                  "one, and only vm-tests")
        # A workflow that runs as develop has it holds develop's token on a
        # pull request's event, also when other events start it as well.
        # Writing to the pull request is for vm-gate.yml, which removes the
        # label, and for the call of automerge's reusable workflow.
        if set(on) & AS_DEVELOP and path.name != "vm-gate.yml" and \
                str((job or {}).get("uses", "")) != automerge_uses:
            for scope in ("pull-requests", "issues"):
                if grants(job, doc, scope) is not False:
                    print(f"FAIL {path.name}: the job {job_id} runs as develop has it and may write "
                          f"{scope}; only vm-gate.yml does, to remove the label vm-tests")
if not branch_writers:
    print("ok no job of a workflow that runs as a branch or a pull request has it may write commit statuses")

gate_text = (workflows / "vm-gate.yml").read_text()
gate_doc = yaml.safe_load(gate_text)
gate_job = gate_doc["jobs"]["gate"]
gate_script = scripts(gate_job)
# #145: the event of `opened` is older than a label set at creation.
if re.search(r'gh api "repos/\$REPO/issues/\$NUMBER/labels[?"]', gate_script):
    print("ok vm-gate.yml reads the pull request's labels from the API")
else:
    print("FAIL vm-gate.yml does not read the pull request's labels from the API")
from_event = sorted(k for k, v in {**(gate_doc.get("env") or {}), **(gate_job.get("env") or {})}.items()
                    if re.search(r"github\.event\.pull_request\.labels", str(v)))
if from_event in ([], ["LABEL_AT_EVENT"]) and \
        len(re.findall(r"github\.event\.pull_request\.labels", gate_text)) == len(from_event) and \
        len(re.findall(r"\$\{?LABEL_AT_EVENT\b", gate_script)) <= 1 and \
        "GITHUB_EVENT_PATH" not in gate_script and \
        all("synchronize" in line for line in gate_script.splitlines() if "LABEL_AT_EVENT" in line):
    print("ok vm-gate.yml takes the event's labels only to tell whether a push found the label set")
else:
    print("FAIL vm-gate.yml decides on the labels of the event (only LABEL_AT_EVENT, in the "
          "condition on synchronize, may hold them)")
# #130: removing the label is what pull-requests: write is there for.
if gate_script.count(THE_REMOVAL) == 1:
    print("ok vm-gate.yml removes the label vm-tests, in one call")
else:
    print(f"FAIL vm-gate.yml removes the label vm-tests in {gate_script.count(THE_REMOVAL)} calls, not in one")
gate_perms = gate_job.get("permissions", gate_doc.get("permissions")) or {}
if gate_perms == {"contents": "read", "pull-requests": "write", "statuses": "write"}:
    print("ok vm-gate.yml may write the pull request and commit statuses, and nothing else")
else:
    print(f"FAIL vm-gate.yml's permissions are {gate_perms}: beyond reading, only pull-requests "
          "(the label) and statuses")
# The finalizer writes only after it has read what vm-gate.yml said about
# the commit and whether the label is still set. The order of the text, with
# the comments left out, and one write only: that the script acts on what it
# read is what tests/unit/vm-gate.sh runs it for (no status, a failure of
# vm-gate.yml, the label removed after the lookup: nothing written).
finalize_script = "\n".join(
    line for line in scripts(yaml.safe_load((workflows / "vm-gate-finalize.yml").read_text())["jobs"]["finalize"]).splitlines()
    if not line.lstrip().startswith("#"))
writes = len(re.findall(r"/statuses/", finalize_script))
write = finalize_script.find('-X POST "repos/$REPO/statuses/$SHA"')
if writes == 1 and write >= 0:
    print("ok vm-gate-finalize.yml writes a commit status in one place")
else:
    print(f"FAIL vm-gate-finalize.yml names a path to write a commit status {writes} times, not once")
for what, call in (("vm-gate's status of the commit", r'gh api (--paginate )?"repos/\$REPO/commits/\$SHA/statuses'),
                   ("the pull request's labels", r'gh api "repos/\$REPO/issues/\$number/labels')):
    read = re.search(call, finalize_script)
    if read and read.start() < write:
        print(f"ok vm-gate-finalize.yml reads {what} from the API before it writes the result")
    else:
        print(f"FAIL vm-gate-finalize.yml writes the result without reading {what} from the API first")

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
def named_files(text):
    # The names after a "see", up to the end of the logical line: a line
    # that ends in a backslash continues on the next one, and so does a
    # message that breaks right after its "see" (#146: a name on the line
    # after its "see" was not looked at).
    text = re.sub(r"\\\n[ \t]*", "", text)
    text = re.sub(r"\bsee[ \t]*\n[ \t]*", "see ", text)
    named = set()
    for line in text.splitlines():
        _, see, rest = line.partition("see ")
        if see:
            named.update(re.findall(r"[\w${}-]+(?:\.[\w-]+)*\.(?:txt|log|ppm)\b", rest))
    return named


sample = (
    'record a FAIL - "failed, see $name.console.txt and " \\\n        "a.late.log"\n'
    'fail b "the disk build failed, see\n    b.disk.log"\n'
    'guest true >"$OUT/c.unnamed.txt"\n'
)
if named_files(sample) == {"$name.console.txt", "a.late.log", "b.disk.log"}:
    print('ok a file named on the line after its "see" is found, and one that no "see" names is not')
else:
    print(f"FAIL the rule for the files a failure names finds {sorted(named_files(sample))} in its sample")

vm_doc = load(workflows / "vm-tests.yml")
vm_jobs = vm_doc.get("jobs") or {}

# #152: the label in the event that starts a run of the VM tests is older
# than what vm-gate.yml decides about it. The job consent reads the label
# and vm-gate's status from the API, and nothing is built or booted before
# it has said that the run goes on. A text check, as above: a pull request
# runs its own vm-tests.yml, so this keeps an honest change from taking the
# job out of the way, and vm-gate-finalize.yml is what keeps the result.
# What the file says outside its comments.
vm_text = "\n".join(line for line in (workflows / "vm-tests.yml").read_text().splitlines()
                    if not line.lstrip().startswith("#"))
consent = vm_jobs.get("consent") or {}
consent_script = scripts(consent)
if re.search(r'gh api "repos/\$REPO/issues/\$NUMBER/labels[?"]', consent_script):
    print("ok vm-tests.yml: the job consent reads the pull request's labels from the API")
else:
    print("FAIL vm-tests.yml: the job consent does not read the pull request's labels from the API")
# The event's labels only sort out, in the condition of consent, the events
# that never start the tests; no other job and no script decides on them.
if len(re.findall(r"github\.event\.pull_request\.labels", vm_text)) == 1 and \
        "github.event.pull_request.labels" in str(consent.get("if", "")) and \
        "GITHUB_EVENT_PATH" not in vm_text:
    print("ok vm-tests.yml takes the event's labels only in the condition of the job consent")
else:
    print("FAIL vm-tests.yml decides on the labels of the event outside the condition of the job consent")
build = vm_jobs.get("build") or {}
build_needs = build.get("needs") or []
build_if = str(build.get("if", ""))
if "consent" in ([build_needs] if isinstance(build_needs, str) else build_needs) and \
        re.fullmatch(r"\s*needs\.consent\.outputs\.run == 'true'\s*", build_if):
    print("ok vm-tests.yml: the build runs only when the job consent says so")
else:
    print(f"FAIL vm-tests.yml: the build does not depend on the job consent alone (needs {build_needs}, if {build_if!r})")


def after_build(job_id, seen=()):
    # Whether the job needs the build, directly or through another job.
    needs = (vm_jobs.get(job_id) or {}).get("needs") or []
    needs = [needs] if isinstance(needs, str) else needs
    return "build" in needs or any(after_build(n, seen + (job_id,)) for n in needs if n not in seen)


loose = sorted(j for j in vm_jobs if j not in ("consent", "build") and not after_build(j))
if loose:
    print(f"FAIL vm-tests.yml: the job(s) {', '.join(loose)} run without the build, so without the job consent")
else:
    print("ok vm-tests.yml: every job but consent is the build or needs it")
# A job with a status function in its condition runs although the build was
# skipped, unless the condition says otherwise: only the report job's
# condition, as a whole, is known to (an `||` beside it would not be).
eager = sorted(j for j, job in vm_jobs.items() if j not in ("consent", "build")
               and re.search(r"always\(|cancelled\(|failure\(|success\(", str((job or {}).get("if", "")))
               and " ".join(str(job.get("if", "")).split()) != "always() && needs.build.result != 'skipped'")
if eager:
    print(f"FAIL vm-tests.yml: the job(s) {', '.join(eager)} run also when the build was skipped")
else:
    print("ok vm-tests.yml: no job runs when the build was skipped")
if consent.get("permissions") == {"pull-requests": "read", "statuses": "read"}:
    print("ok vm-tests.yml: the job consent may read the pull request and commit statuses, and nothing else")
else:
    print(f"FAIL vm-tests.yml: the permissions of the job consent are {consent.get('permissions')}: "
          "only pull-requests: read and statuses: read")
if "${{" in consent_script or any("uses" in s for s in consent.get("steps") or []):
    print("FAIL vm-tests.yml: the job consent expands an expression inside its script or uses an action")
else:
    print("ok vm-tests.yml: the job consent passes the event through env and uses no action")
# #180: a new attempt of an old run has the event of its first attempt, so
# consent asks the API which commit is the head, before anything else.
head_read = consent_script.find('gh api "repos/$REPO/pulls/$NUMBER"')
label_read = consent_script.find('gh api "repos/$REPO/issues/$NUMBER/labels')
if 0 <= head_read < label_read and '[ "$head" != "$SHA" ]' in consent_script:
    print("ok vm-tests.yml: the job consent compares the run's commit with the head of the pull request, from the API")
else:
    print("FAIL vm-tests.yml: the job consent does not compare the run's commit with the head of the pull "
          "request (pulls/$NUMBER) before it reads the label")

# And whether the pull request is open, from the same answer and before the
# label (#195): one read of the pull request, not two.
state_read = consent_script.find('[ "$state" != open ]')
if consent_script.count('gh api "repos/$REPO/pulls/$NUMBER"') == 1 and head_read < state_read < label_read and \
        '(.state // "unknown")' in consent_script and ".merged" in consent_script:
    print("ok vm-tests.yml: the job consent reads whether the pull request is open, with the head and before the label")
else:
    print("FAIL vm-tests.yml: the job consent does not read whether the pull request is open from its one "
          "read of the pull request, before the label")

# #180: consent decides before the build, so each suite job reads the label
# again in its first step and fails when it is gone. The step is the same
# text in the three jobs, runs on a pull request only, and the steps that
# report results although a step failed stay out when the label is gone.
# A job's permissions replace the workflow's: the checkout needs contents,
# the read of the label pull-requests, and nothing else is given.
SUITES = ("boot", "update", "data-disk")
GONE = "steps.label.outputs.gone != 'true'"
first_steps = []
for job_id in SUITES:
    job = vm_jobs.get(job_id) or {}
    steps = job.get("steps") or []
    first = steps[0] if steps else {}
    first_steps.append(first)
    script = str(first.get("run", ""))
    if first.get("id") == "label" and \
            " ".join(str(first.get("if", "")).split()) == "github.event_name == 'pull_request'" and \
            re.search(r'gh api "repos/\$REPO/issues/\$NUMBER/labels[?"]', script) and \
            'echo "gone=true" >>"$GITHUB_OUTPUT"' in script and "${{" not in script and "uses" not in first:
        print(f"ok vm-tests.yml: the job {job_id} reads the label from the API in its first step, on a pull request only")
    else:
        print(f"FAIL vm-tests.yml: the first step of the job {job_id} is not the read of the label vm-tests "
              "(id label, on pull_request only, from the API, the event through env)")
    if job.get("permissions") == {"contents": "read", "pull-requests": "read"}:
        print(f"ok vm-tests.yml: the job {job_id} may read the code and the pull request, and nothing else")
    else:
        print(f"FAIL vm-tests.yml: the permissions of the job {job_id} are {job.get('permissions')}: "
              "only contents: read and pull-requests: read")
    # Whatever runs after a failed step would report on tests that never
    # started: the check of the results file and the upload of the results.
    unguarded = [str(s.get("name") or s.get("uses")) for s in steps[1:]
                 if re.search(r"always\(|failure\(|cancelled\(", str(s.get("if", "")))
                 and GONE not in str(s.get("if", ""))
                 and (str(s.get("run", "")).startswith("tests/boot/results.sh")
                      or str(s.get("uses", "")).startswith("actions/upload-artifact@"))]
    if unguarded:
        print(f"FAIL vm-tests.yml: the job {job_id} reports results also when the label is gone ({', '.join(unguarded)})")
    else:
        print(f"ok vm-tests.yml: the job {job_id} reports no results when the label is gone")
if first_steps[0] and all(s == first_steps[0] for s in first_steps):
    print("ok vm-tests.yml: the three suite jobs read the label with the same step")
else:
    print("FAIL vm-tests.yml: the first steps of the jobs boot, update and data-disk differ")
# The only jobs that may read anything but the code are consent and the
# suites, and none may read the runs of Actions (#180: telling whether
# another run of the head already counts was decided against).
for job_id, job in vm_jobs.items():
    perms = (job or {}).get("permissions", vm_doc.get("permissions"))
    allowed = {"consent": {"pull-requests": "read", "statuses": "read"}}.get(
        job_id, {"contents": "read", "pull-requests": "read"} if job_id in SUITES else {"contents": "read"})
    if perms != allowed:
        print(f"FAIL vm-tests.yml: the permissions of the job {job_id} are {perms}, not {allowed}")
if vm_doc.get("permissions") == {"contents": "read"} and \
        not any("actions" in ((job or {}).get("permissions") or {}) for job in vm_jobs.values()) and \
        not re.search(r"^\s*actions:", vm_text, re.M):
    print("ok vm-tests.yml: the workflow's token reads the code, and no job may read the runs of Actions")
else:
    print("FAIL vm-tests.yml: the workflow's permissions are not contents: read alone, or a job names actions:")

# The three scripts agree on what an accepted commit is: vm-gate.yml sets
# it, vm-gate-finalize.yml writes a result on it, and consent runs on it.
ACCEPTED = r"pending$'\t'* | success$'\t'* | failure$'\t''the VM tests of this commit'*)"
for name, script in (("vm-gate.yml", gate_script), ("vm-gate-finalize.yml", finalize_script),
                     ("vm-tests.yml (consent)", consent_script)):
    if script.count(ACCEPTED) == 1:
        print(f"ok {name} takes pending, green and a result of the VM tests as an accepted commit")
    else:
        print(f"FAIL {name} does not name the accepted statuses as the other scripts do ({ACCEPTED})")
# The one refusal of vm-gate.yml on which consent gives up at once.
MOVED = "no VM test result for this commit: it is not the head of the pull request any more"
if gate_script.count(f'status failure "{MOVED}"') == 1 and consent_script.count(f"failure$'\\t''{MOVED}')") == 1:
    print("ok vm-tests.yml (consent) gives up on the text vm-gate.yml writes for a commit that is not the head any more")
else:
    print("FAIL vm-tests.yml (consent) and vm-gate.yml do not name a commit that is not the head any more alike")
for job_id, script in (("boot", "run.sh"), ("update", "update.sh"), ("data-disk", "data-disk.sh")):
    globs = []
    for step in (vm_jobs.get(job_id) or {}).get("steps") or []:
        if str(step.get("uses", "")).startswith("actions/upload-artifact@") and \
                str((step.get("with") or {}).get("name", "")).startswith("vm-results-"):
            globs += str(step["with"].get("path", "")).split()
    named = named_files((root / "tests" / "boot" / script).read_text())
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
