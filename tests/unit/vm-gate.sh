#!/usr/bin/env bash
# Runs the scripts of .github/workflows/vm-gate.yml and
# .github/workflows/vm-gate-finalize.yml, as the workflow files hold them,
# against a stub of gh, and checks what they decide (#145, #130): the label
# vm-tests is read from the API and not from the event, a push withdraws it
# when the head is in a fork, when the push changes the pull request's own
# version of what the VM jobs run, or when the commit before it was not
# accepted, and vm-gate-finalize writes a result only on a commit that
# vm-gate accepted and while the label is set. Both workflows run as develop
# has them, so a pull request never runs its own version of them: this test
# is what runs a change to them before the merge.
#
# The stub keeps the pull request in files: its labels, the vm-gate statuses
# of each commit and the comparisons the API would answer. jq is the real
# one and runs the workflows' own filters. Needs PyYAML and jq; no network,
# no token.
#
# Usage: tests/unit/vm-gate.sh
set -uo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
expect() {  # expect NAME EXPECTED ACTUAL
    if [ "$2" = "$3" ]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"
        failures=$((failures + 1))
    fi
}

# The scripts under test, taken from the workflow files.
python3 - "$root" "$work" <<'EOF' || { echo "FAIL  the workflow files could not be read"; exit 1; }
import pathlib
import sys

import yaml

root, work = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
for name, job in (("vm-gate", "gate"), ("vm-gate-finalize", "finalize")):
    doc = yaml.safe_load((root / ".github" / "workflows" / f"{name}.yml").read_text())
    runs = [s["run"] for s in doc["jobs"][job]["steps"] if "run" in s]
    assert len(runs) == 1, f"{name}.yml: expected one script, found {len(runs)}"
    (work / f"{name}.sh").write_text(runs[0])
EOF

# --- the stub of gh: `gh api [-X METHOD] PATH [--jq FILTER] [-f key=value]...`
# over the files of $STATE; every write is one line in $STATE/log ---
mkdir -p "$work/bin"
cat >"$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = api ] || { echo "gh stub: unexpected command $1" >&2; exit 2; }
shift
method=GET path='' filter='' state='' description=''
while [ $# -gt 0 ]; do
    case $1 in
        -X) method=$2; shift 2 ;;
        --jq) filter=$2; shift 2 ;;
        -f)
            case $2 in
                state=*) state=${2#state=} ;;
                description=*) description=${2#description=} ;;
            esac
            shift 2 ;;
        --paginate) shift ;;
        *) path=$1; shift ;;
    esac
done
path=${path#repos/example/appliance/}
path=${path%%\?*}
answer() {  # the JSON on stdin, through the filter if there is one
    if [ -n "$filter" ]; then jq -r "$filter"; else cat; fi
}
case "$method $path" in
    "GET issues/7/labels")
        jq -R -s 'split("\n") | map(select(. != "") | {name: .})' "$STATE/labels" | answer ;;
    "DELETE issues/7/labels/vm-tests")
        echo "remove-label" >>"$STATE/log"
        [ ! -e "$STATE/label-stays" ] || exit 1
        grep -vx vm-tests "$STATE/labels" >"$STATE/labels.new" || true
        mv "$STATE/labels.new" "$STATE/labels" ;;
    "GET commits/"*/statuses)
        sha=${path#commits/}; sha=${sha%/statuses}
        [ -n "$sha" ] && [ ! -e "$STATE/gone-$sha" ] || exit 1
        touch "$STATE/status-$sha"
        # Newest first, as the API lists them, with a status of another
        # context in front.
        tac "$STATE/status-$sha" |
            jq -R -s '[{context: "other", state: "failure", description: "not vm-gate"}] +
                (split("\n") | map(select(. != "") | split("\t")
                    | {context: "vm-gate", state: .[0], description: .[1]}))' | answer ;;
    "POST statuses/"*)
        sha=${path#statuses/}
        [ ${#description} -le 140 ] || { echo "gh stub: description over 140 characters" >&2; exit 1; }
        printf '%s\t%s\n' "$state" "$description" >>"$STATE/status-$sha"
        echo "status $sha $state $description" >>"$STATE/log" ;;
    "GET compare/"*)
        file=$STATE/compare-${path#compare/}
        [ -e "$file" ] || exit 1
        answer <"$file" ;;
    "GET pulls")
        answer <"$STATE/pulls" ;;
    "GET actions/runs/"*)
        answer <"$STATE/jobs" ;;
    *)
        echo "gh stub: unexpected call $method $path" >&2
        exit 2 ;;
esac
EOF
chmod +x "$work/bin/gh"

# --- the pull request #7 of the stub ---
# reset LABEL...: a new state with these labels.
reset() {
    rm -rf "$work/state"
    mkdir -p "$work/state"
    : >"$work/state/log"
    printf '%s\n' "$@" >"$work/state/labels"
}
# compare BASE COMMIT [FILE=BLOB[=STATUS[=PREVIOUS]]]...: what the API answers
# for BASE...COMMIT.
compare() {
    local base=$1 commit=$2 entry
    shift 2
    for entry in "$@"; do printf '%s\n' "$entry"; done |
        jq -R -s '{files: (split("\n") | map(select(. != "") | split("=")
            | {filename: .[0], sha: .[1], status: (.[2] // "modified")}
              + (if .[3] then {previous_filename: .[3]} else {} end)))}' \
            >"$work/state/compare-$base...$commit"
}
# many BASE COMMIT: a comparison that lists 300 files, none of them covered.
many() {
    jq -n '{files: [range(300) | {filename: "docs/page-\(.).md", sha: "d\(.)", status: "modified"}]}' \
        >"$work/state/compare-$1...$2"
}
had() { printf '%s\t%s\n' "$2" "$3" >>"$work/state/status-$1"; }  # had COMMIT STATE DESCRIPTION
label() { grep -qx vm-tests "$work/state/labels" && echo set || echo removed; }
last() { tail -n1 "$work/state/status-$1" 2>/dev/null | tr '\t' ' '; }  # last COMMIT
log() { paste -sd'|' "$work/state/log"; }

pending='pending waiting for the VM tests of this commit (vm-gate-finalize sets the result)'
missing='failure changes the image, build or boot tests: add the label vm-tests'
again='the label vm-tests was removed, add the label vm-tests again after review'

# gate ACTION [NAME=VALUE]...: one run of vm-gate.yml on the head `new` of #7,
# pushed onto `old`; the exit code is in $code.
gate() {
    local action=$1
    shift
    env PATH="$work/bin:$PATH" STATE="$work/state" GH_TOKEN=none \
        REPO=example/appliance NUMBER=7 SHA=new BASE=base BASE_REF=develop \
        HEAD_REPO=example/appliance BEFORE=old ACTION="$action" LABEL='' LABEL_AT_EVENT=false \
        RUN_URL=https://example.invalid/run "$@" \
        bash "$work/vm-gate.sh" >"$work/out" 2>&1 </dev/null
    code=$?
}

echo "# vm-gate.yml: the label as the API has it (#145)"
reset vm-tests automerge
compare base new image/Containerfile=a1
gate opened
expect "opened with the label set after the event: pending" "$pending" "$(last new)"
expect "opened with the label: no failure was written" "status new $pending" "$(log)"

reset automerge
compare base new image/Containerfile=a1
gate opened LABEL_AT_EVENT=true
expect "opened without the label, whatever the event says: failure" "$missing" "$(last new)"

reset
compare base new docs/en/index.md=a1
gate opened
expect "nothing the VM tests cover: success" "success no change the VM tests cover" "$(last new)"

reset
many base new
gate opened
expect "300 files count as covered" "$missing" "$(last new)"

reset vm-tests
compare base new image/Containerfile=a1
gate labeled LABEL=vm-tests LABEL_AT_EVENT=true
expect "the label set: pending" "$pending" "$(last new)"

reset
compare base new image/Containerfile=a1
gate labeled LABEL=vm-tests LABEL_AT_EVENT=true
expect "the label set and removed again before the run: failure" "$missing" "$(last new)"

reset
compare base new image/Containerfile=a1
had new pending "waiting"
gate unlabeled LABEL=vm-tests
expect "the label removed by hand: failure" "$missing" "$(last new)"

echo "# vm-gate.yml: events that start no VM tests"
reset vm-tests automerge
compare base new image/Containerfile=a1
had new pending "waiting"
gate labeled LABEL=automerge LABEL_AT_EVENT=true
expect "another label on an accepted head: nothing written" "" "$(log)"

reset vm-tests automerge
compare base new image/Containerfile=a1
had new failure "changes the image, build or boot tests: add the label vm-tests"
gate labeled LABEL=automerge LABEL_AT_EVENT=true
expect "another label on a head that says the label is missing: no pending from an old status" \
    "failure no VM test result for this commit: remove the label vm-tests and set it again" "$(last new)"

reset vm-tests cicd
compare base new .github/workflows/vm-tests.yml=n2
had new failure "a push from a fork: $again"
gate unlabeled LABEL=cicd LABEL_AT_EVENT=true HEAD_REPO=someone/appliance
expect "another label removed on a head whose label was withdrawn: no pending" \
    "failure no VM test result for this commit: remove the label vm-tests and set it again" "$(last new)"

reset vm-tests
compare base new image/Containerfile=a1
had new success "the VM tests of this commit passed"
gate reopened LABEL_AT_EVENT=true
expect "reopened on an accepted head: nothing written" "" "$(log)"

reset
compare base new misc/run.sh=n1=renamed=tests/boot/run.sh
gate opened
expect "a file moved out of tests/boot/ counts as covered" "$missing" "$(last new)"

reset vm-tests
compare base new image/Containerfile=a1
had new failure "a push from a fork: $again"
gate reopened LABEL_AT_EVENT=true
expect "reopened on a head whose label was withdrawn: failure" \
    "failure no VM test result for this commit: remove the label vm-tests and set it again" "$(last new)"

reset vm-tests
compare base new image/Containerfile=a1
gate reopened LABEL_AT_EVENT=true
expect "reopened on a head without a status: failure" \
    "failure no VM test result for this commit: remove the label vm-tests and set it again" "$(last new)"
expect "reopened: the label stays" set "$(label)"

echo "# vm-gate.yml: a push keeps the label (#130)"
# The pull request's own changes against develop: old is the head before
# the push, new the head after it.
reset vm-tests
compare base new image/Containerfile=a2 build/tools.Containerfile=b1
compare develop new image/Containerfile=a2 build/tools.Containerfile=b1
compare develop old image/Containerfile=a1 build/tools.Containerfile=b1
had old pending "waiting"
gate synchronize LABEL_AT_EVENT=true
expect "a push that changes image/ only: the label stays" set "$(label)"
expect "a push that changes image/ only: pending" "$pending" "$(last new)"
expect "a push that changes image/ only: nothing but the status" "status new $pending" "$(log)"

reset vm-tests
compare base new tests/boot/run.sh=t1 tests/boot/update.sh=u1 docs/a.md=d1
compare develop new tests/boot/update.sh=u1 tests/boot/run.sh=t1 docs/a.md=d2
compare develop old tests/boot/run.sh=t1 tests/boot/update.sh=u1
had old failure "the VM tests of this commit did not pass (boot: failure)"
gate synchronize LABEL_AT_EVENT=true
expect "a rebase onto a develop, after failed VM tests: the label stays" set "$(label)"
expect "a rebase onto a newer develop: pending" "$pending" "$(last new)"

reset vm-tests
compare base new tests/boot/run.sh=t2
compare develop new tests/boot/run.sh=t2
had old failure "changes the image, build or boot tests: add the label vm-tests"
gate synchronize LABEL_AT_EVENT=false HEAD_REPO=someone/appliance
expect "the label set after the push arrived: it stays" set "$(label)"
expect "the label set after the push arrived: pending" "$pending" "$(last new)"

reset
compare base new tests/boot/run.sh=t2
gate synchronize
expect "a push without the label: failure, nothing to remove" "status new $missing" "$(log)"

echo "# vm-gate.yml: a push withdraws the label (#130)"
for path in tests/boot/run.sh build/disk.sh tests/image/metadata-guard.sh .github/workflows/vm-tests.yml; do
    reset vm-tests automerge
    compare base new "$path=n2"
    compare develop new "$path=n2"
    compare develop old "$path=n1"
    had old pending "waiting"
    gate synchronize LABEL_AT_EVENT=true
    expect "a push that changes $path: the label is removed, then the failure set" \
        "remove-label|status new failure a push that changes what the VM tests run: $again" "$(log)"
    expect "a push that changes $path: the other labels stay" automerge "$(paste -sd' ' "$work/state/labels")"
done

reset vm-tests
compare base new tests/boot/run.sh=n1 image/Containerfile=a1
compare develop new tests/boot/run.sh=n1 image/Containerfile=a1
compare develop old image/Containerfile=a1
had old success "the VM tests of this commit passed"
gate synchronize LABEL_AT_EVENT=true
expect "a push that brings the first change to tests/boot/: removed" removed "$(label)"

reset vm-tests
compare base new image/Containerfile=a1
compare develop new image/Containerfile=a1
compare develop old image/Containerfile=a1 tests/boot/run.sh=n1
had old pending "waiting"
gate synchronize LABEL_AT_EVENT=true
expect "a push that takes a change to tests/boot/ back: removed" removed "$(label)"

reset vm-tests
compare base new tests/moved.sh=n1=renamed=tests/boot/run.sh
compare develop new tests/moved.sh=n1=renamed=tests/boot/run.sh
compare develop old image/Containerfile=a1
had old pending "waiting"
gate synchronize LABEL_AT_EVENT=true
expect "a push that moves a file out of tests/boot/: removed" removed "$(label)"

reset vm-tests
compare base new docs/a.md=d1
compare develop new docs/a.md=d1
compare develop old docs/a.md=d1
had old success "no change the VM tests cover"
gate synchronize LABEL_AT_EVENT=true HEAD_REPO=someone/appliance
expect "a push from a fork: removed, whatever it changes" removed "$(label)"
expect "a push from a fork that changes nothing covered: success" \
    "success no change the VM tests cover" "$(last new)"

reset vm-tests
compare base new image/Containerfile=a1
compare develop new image/Containerfile=a1
compare develop old image/Containerfile=a1
had old pending "waiting"
gate synchronize LABEL_AT_EVENT=true HEAD_REPO=''
expect "a push from a fork that is gone: removed" \
    "failure a push from a fork: $again" "$(last new)"

for before in "" "failure	changes the image, build or boot tests: add the label vm-tests" \
    "failure	a push that changes what the VM tests run: $again" \
    "failure	no VM test result for this commit: remove the label vm-tests and set it again" \
    "error	something else"; do
    reset vm-tests
    compare base new image/Containerfile=a2
    compare develop new image/Containerfile=a2
    compare develop old image/Containerfile=a1
    [ -z "$before" ] || printf '%s\n' "$before" >"$work/state/status-old"
    gate synchronize LABEL_AT_EVENT=true
    name=${before:-no status}
    expect "a push onto a commit with ${name//$'\t'/: }: removed" \
        "failure a push onto a commit vm-gate had not accepted: $again" "$(last new)"
done

reset vm-tests
compare base new image/Containerfile=a2
compare develop new image/Containerfile=a2
touch "$work/state/gone-old"
gate synchronize LABEL_AT_EVENT=true
expect "a force push whose previous commit is gone: removed" \
    "failure a push onto a commit vm-gate had not accepted: $again" "$(last new)"

# A file name with a line break must not pass for a second file's line
# (one line of text per file would compare equal here).
reset vm-tests
jq -n '{files: [{filename: "tests/boot/x\nq", sha: "p1", status: "added"},
    {filename: "tests/boot/run.sh", sha: "b2", status: "modified"}]}' |
    tee "$work/state/compare-base...new" >"$work/state/compare-develop...new"
jq -n '{files: [{filename: "tests/boot/x\nmodified - tests/boot/run.sh b2\nq", sha: "p1", status: "added"}]}' \
    >"$work/state/compare-develop...old"
had old pending "waiting"
gate synchronize LABEL_AT_EVENT=true
expect "a file name that imitates another file's line: removed" removed "$(label)"

reset vm-tests
compare base new image/Containerfile=a2
compare develop new image/Containerfile=a2
had old pending "waiting"
gate synchronize LABEL_AT_EVENT=true
expect "a previous commit that cannot be compared: removed" \
    "failure a push that changes what the VM tests run: $again" "$(last new)"

reset vm-tests
compare base new image/Containerfile=a2
many develop new
compare develop old image/Containerfile=a1
had old pending "waiting"
gate synchronize LABEL_AT_EVENT=true
expect "a comparison of 300 files: removed" removed "$(label)"

reset vm-tests
compare base new tests/boot/run.sh=n2
compare develop new tests/boot/run.sh=n2
compare develop old tests/boot/run.sh=n1
had old pending "waiting"
touch "$work/state/label-stays"
gate synchronize LABEL_AT_EVENT=true
expect "the label cannot be removed: the run fails" 1 "$code"
expect "the label cannot be removed: failure, not pending" \
    "failure a push that changes what the VM tests run: the label vm-tests could not be removed, remove it by hand" "$(last new)"

# --- vm-gate-finalize.yml ---
# finalize: one run on the completed vm-tests run of the commit `new`.
finalize() {
    : >"$work/output"
    env PATH="$work/bin:$PATH" STATE="$work/state" GH_TOKEN=none GITHUB_OUTPUT="$work/output" \
        REPO=example/appliance RUN_ID=1 ATTEMPT=1 SHA=new HEAD_REPO=example/appliance \
        HEAD_BRANCH=fix/x CONCLUSION=success RUN_URL=https://example.invalid/run \
        bash "$work/vm-gate-finalize.sh" >"$work/out" 2>&1 </dev/null
    code=$?
}
# tested [LABEL]... : #7 with these labels and a vm-tests run whose jobs passed.
tested() {
    reset "$@"
    printf '%s\n' "$@" | jq -R -s '[{number: 7, head: {sha: "new", ref: "fix/x", repo: {full_name: "example/appliance"}},
        labels: (split("\n") | map(select(. != "") | {name: .}))}]' >"$work/state/pulls"
    jq -n '{jobs: [("build", "boot (1)", "boot (2)", "update", "data-disk", "report")
        | {name: ., status: "completed", conclusion: "success"}]}' >"$work/state/jobs"
}
passed='success the VM tests of this commit passed'

echo "# vm-gate-finalize.yml: a result only on a commit vm-gate accepted (#130)"
tested vm-tests
had new pending "waiting"
finalize
expect "pending and the label: the result is written" "$passed" "$(last new)"
expect "pending and the label: the state is handed to automerge" "state=success" "$(cat "$work/output")"

tested vm-tests
had new failure "the VM tests of this commit did not pass (boot: failure)"
finalize
expect "an earlier result of the VM tests: the new attempt's result is written" "$passed" "$(last new)"

tested vm-tests
had new success "no change the VM tests cover"
finalize
expect "a green vm-gate: the result is written" "$passed" "$(last new)"

tested vm-tests
had new pending "waiting"
jq '.jobs[1].conclusion = "failure"' "$work/state/jobs" >"$work/state/jobs.new" && mv "$work/state/jobs.new" "$work/state/jobs"
finalize
expect "a failed suite: failure" "failure the VM tests of this commit did not pass (boot: failure)" "$(last new)"

tested vm-tests
finalize
expect "no vm-gate status on the commit, the label still set: nothing written" "" "$(log)"
expect "no vm-gate status: no state for automerge" "state=" "$(cat "$work/output")"
expect "no vm-gate status: the run says why" \
    "vm-gate: unchanged (vm-gate.yml has not accepted this commit for the VM tests (no status))" "$(cat "$work/out")"

for refused in "a push that changes what the VM tests run: $again" \
    "changes the image, build or boot tests: add the label vm-tests" \
    "no VM test result for this commit: remove the label vm-tests and set it again"; do
    tested vm-tests
    had new failure "$refused"
    finalize
    expect "vm-gate failed with '${refused%%:*}', the label set: nothing written" "" "$(log)"
done

tested automerge
had new pending "waiting"
finalize
expect "pending, the label removed: nothing written" "" "$(log)"

# The list of pull requests still shows the label, the label itself is gone:
# the read right before the write decides.
tested vm-tests
had new pending "waiting"
echo automerge >"$work/state/labels"
finalize
expect "pending, the label removed after the lookup: nothing written" "" "$(log)"
expect "the label removed after the lookup: the run says why" \
    "vm-gate: unchanged (the label vm-tests was removed from #7 meanwhile)" "$(cat "$work/out")"

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
