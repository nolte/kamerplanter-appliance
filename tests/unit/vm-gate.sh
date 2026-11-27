#!/usr/bin/env bash
# Runs the scripts of .github/workflows/vm-gate.yml and
# .github/workflows/vm-gate-finalize.yml, as the workflow files hold them,
# against a stub of gh, and checks what they decide (#145, #130, #151): the
# label vm-tests is read from the API and not from the event, a push
# withdraws it when the head is in a fork, when the push changes the pull
# request's own version of what the VM jobs run, or when the commit before it
# was not accepted, a label that is set too soon after someone else's push is
# removed again, and vm-gate-finalize writes a result only on a commit that
# vm-gate accepted and while the label is set. Both workflows run as develop
# has them, so a pull request never runs its own version of them: this test
# is what runs a change to them before the merge.
#
# The stub keeps the pull request in files: its labels and events, the
# vm-gate statuses of each commit, the activity of the head repository, and
# the comparisons and trees the API would answer. It answers a call as the
# API would, as far as the scripts depend on it (#167): a list comes in pages
# of `per_page` entries (30 without it), the first one only unless the call
# says --paginate; a call with fields is a POST unless it names its method;
# the activity lists the branch the call names, or every branch; a tree
# holds the top level only without `recursive=1`; and a status is written
# under the context the call names, where only vm-gate counts. jq is the
# real one and runs the workflows' own filters. Needs PyYAML and jq; no
# network, no token.
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

# --- the stub of gh:
# `gh api [--paginate] [-X METHOD] PATH[?QUERY] [--jq FILTER] [-f key=value]...`
# over the files of $STATE; every write is one line in $STATE/log ---
mkdir -p "$work/bin"
cat >"$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = api ] || { echo "gh stub: unexpected command $1" >&2; exit 2; }
shift
method='' path='' filter='' state='' description='' context='' paginate=false
ref='' fields=false field_per_page=''
while [ $# -gt 0 ]; do
    case $1 in
        -X) method=$2; shift 2 ;;
        --jq) filter=$2; shift 2 ;;
        -f)
            fields=true
            case $2 in
                state=*) state=${2#state=} ;;
                description=*) description=${2#description=} ;;
                context=*) context=${2#context=} ;;
                ref=*) ref=${2#ref=} ;;
                per_page=*) field_per_page=${2#per_page=} ;;
            esac
            shift 2 ;;
        --paginate) paginate=true; shift ;;
        *) path=$1; shift ;;
    esac
done
# As gh has it: fields make a call a POST unless it names its method, and
# the fields of a GET are its query.
if [ -z "$method" ]; then
    if [ "$fields" = true ]; then method=POST; else method=GET; fi
fi
path=${path#repos/example/appliance/}
query=''
case $path in
    *\?*) query=${path#*\?}; path=${path%%\?*} ;;
esac
per_page=30
case "&$query&" in
    *"&per_page="*) per_page=${query##*per_page=}; per_page=${per_page%%&*} ;;
esac
if [ "$method" = GET ] && [ -n "$field_per_page" ]; then per_page=$field_per_page; fi
answer() {  # the JSON on stdin, through the filter if there is one
    if [ -n "$filter" ]; then jq -r "$filter"; else cat; fi
}
# The JSON list on stdin as the API pages it: its first $per_page entries,
# or with --paginate every page as a document of its own. The filter runs on
# each page by itself, as gh runs it.
pages() {
    if [ "$paginate" = true ]; then
        jq -c --argjson n "$per_page" '. as $all | range(0; [length, 1] | max; $n) as $i | $all[$i:$i + $n]'
    else
        jq -c --argjson n "$per_page" '.[:$n]'
    fi | while IFS= read -r page; do answer <<<"$page"; done
}
case "$method $path" in
    "GET issues/7/labels")
        jq -R -s 'split("\n") | map(select(. != "") | {name: .})' "$STATE/labels" | pages ;;
    "DELETE issues/7/labels/vm-tests")
        echo "remove-label" >>"$STATE/log"
        [ ! -e "$STATE/label-stays" ] || exit 1
        grep -vx vm-tests "$STATE/labels" >"$STATE/labels.new" || true
        mv "$STATE/labels.new" "$STATE/labels" ;;
    "GET issues/7/events")
        # The events of #7, oldest first, as the API lists them: one line
        # each of event, label, time and the account's id (- if it is gone).
        [ ! -e "$STATE/events-gone" ] || exit 1
        touch "$STATE/events"
        jq -R -s '[split("\n")[] | select(. != "") | split("\t")
            | {event: .[0], created_at: .[2], actor: (if .[3] == "-" then null else {id: (.[3] | tonumber)} end)}
              + (if .[1] != "" then {label: {name: .[1]}} else {} end)]' "$STATE/events" | pages ;;
    "GET repositories/"*"/activity")
        # The activity of a repository, newest first: one line each of ref,
        # the commit it points to since, time and the account's id. The
        # repository is the one whose id the call names: 10 is this one, 20
        # the fork someone/appliance. A list that lags answers nothing once.
        case $path in
            repositories/10/activity) owner=example ;;
            repositories/20/activity) owner=someone ;;
            *) exit 1 ;;
        esac
        [ ! -e "$STATE/activity-gone" ] || exit 1
        if [ -e "$STATE/activity-lags" ]; then rm "$STATE/activity-lags"; echo '[]'; exit 0; fi
        touch "$STATE/activity-$owner"
        jq -R -s --arg ref "$ref" '[split("\n")[] | select(. != "") | split("\t")
            | {ref: .[0], after: .[1], timestamp: .[2], activity_type: "push",
               actor: (if .[3] == "-" then null else {id: (.[3] | tonumber)} end)}
            | select($ref == "" or .ref == $ref)]' "$STATE/activity-$owner" | pages ;;
    "GET commits/"*/statuses)
        sha=${path#commits/}; sha=${sha%/statuses}
        [ -n "$sha" ] && [ ! -e "$STATE/gone-$sha" ] || exit 1
        touch "$STATE/status-$sha"
        # Newest first, as the API lists them, with the statuses of another
        # context in front: one, or as many as $STATE/others-<sha> says.
        tac "$STATE/status-$sha" |
            jq -R -s --argjson others "$(cat "$STATE/others-$sha" 2>/dev/null || echo 1)" \
                '[range($others) | {context: "other", state: "failure", description: "not vm-gate \(.)"}] +
                (split("\n") | map(select(. != "") | split("\t")
                    | {context: "vm-gate", state: .[0], description: .[1]}))' | pages ;;
    "POST statuses/"*)
        sha=${path#statuses/}
        [ ${#description} -le 140 ] || { echo "gh stub: description over 140 characters" >&2; exit 1; }
        # A status of another context is written, but it is not vm-gate's.
        if [ "$context" = vm-gate ]; then
            printf '%s\t%s\n' "$state" "$description" >>"$STATE/status-$sha"
            echo "status $sha $state $description" >>"$STATE/log"
        else
            echo "status $sha $state $description (context '$context')" >>"$STATE/log"
        fi ;;
    "GET compare/"*)
        file=$STATE/compare-${path#compare/}
        [ -e "$file" ] || exit 1
        answer <"$file" ;;
    "GET git/trees/"*)
        # The tree of a commit: empty unless a test gave it one. Without
        # recursive=1 the API lists the top level only.
        sha=${path#git/trees/}
        [ ! -e "$STATE/gone-$sha" ] || exit 1
        if [ -e "$STATE/tree-$sha" ]; then cat "$STATE/tree-$sha"; else echo '{"truncated": false, "tree": []}'; fi |
            case "&$query&" in
                *"&recursive=1&"*) cat ;;
                *) jq '.tree |= map(select(.path | contains("/") | not))' ;;
            esac | answer ;;
    "GET pulls")
        answer <"$STATE/pulls" ;;
    "GET pulls/7")
        # The head of #7 right now: `new`, unless a test moved it on, in
        # this repository (10) unless a test says another one, or none.
        jq -n --arg sha "$(cat "$STATE/head" 2>/dev/null || echo new)" \
            --arg repo "$(cat "$STATE/head-repo" 2>/dev/null || echo 10)" \
            '{head: {sha: $sha, repo: (if $repo == "" then null else {id: ($repo | tonumber)} end)},
              base: {repo: {id: 10}}}' | answer ;;
    "GET actions/runs/"*)
        answer <"$STATE/jobs" ;;
    *)
        echo "gh stub: unexpected call $method $path" >&2
        exit 2 ;;
esac
EOF
chmod +x "$work/bin/gh"

# --- the pull request #7 of the stub ---
# reset LABEL...: a new state with these labels. The head `new` is the tip of
# the branch fix/x since noon, pushed by the account 2, in this repository
# and in the fork someone/appliance alike; the label vm-tests, if it is among
# the labels, was set an hour later by the account 1.
reset() {
    rm -rf "$work/state"
    mkdir -p "$work/state"
    : >"$work/state/log"
    printf '%s\n' "$@" >"$work/state/labels"
    pushed 12:00:00 2
    case " $* " in
        *" vm-tests "*) labelled 13:00:00 1 ;;
    esac
}
# pushed TIME ACCOUNT [COMMIT [OWNER [BRANCH]]]: the newest entry of the
# activity of OWNER's repository says that BRANCH points to COMMIT since
# TIME (of 2026-01-01), pushed by ACCOUNT. Without OWNER, in this repository
# and in the fork alike.
pushed() {
    local owner
    for owner in ${4:-example someone}; do
        touch "$work/state/activity-$owner"
        { printf 'refs/heads/%s\t%s\t2026-01-01T%sZ\t%s\n' "${5:-fix/x}" "${3:-new}" "$1" "$2"
          cat "$work/state/activity-$owner"; } >"$work/state/activity.new"
        mv "$work/state/activity.new" "$work/state/activity-$owner"
    done
}
# labelled TIME ACCOUNT [LABEL]: the newest event of #7 says that ACCOUNT set
# LABEL (vm-tests) at TIME (of 2026-01-01).
labelled() { printf 'labeled\t%s\t2026-01-01T%sZ\t%s\n' "${3:-vm-tests}" "$1" "$2" >>"$work/state/events"; }
# fork [ID]: the head of #7 is in the repository ID (the fork's, 20).
fork() { echo "${1-20}" >"$work/state/head-repo"; }
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
# tree COMMIT [FILE=MODE]...: the tree of COMMIT, as far as a test needs it.
tree() {
    local commit=$1 entry
    shift
    for entry in "$@"; do printf '%s\n' "$entry"; done |
        jq -R -s '{truncated: false, tree: (split("\n") | map(select(. != "") | split("=")
            | {path: .[0], mode: .[1], type: "blob"}))}' >"$work/state/tree-$commit"
}
had() { printf '%s\t%s\n' "$2" "$3" >>"$work/state/status-$1"; }  # had COMMIT STATE DESCRIPTION
# others COMMIT N: N statuses of another context are newer than vm-gate's.
others() { echo "$2" >"$work/state/others-$1"; }
label() { grep -qx vm-tests "$work/state/labels" && echo set || echo removed; }
last() { tail -n1 "$work/state/status-$1" 2>/dev/null | tr '\t' ' '; }  # last COMMIT
log() { paste -sd'|' "$work/state/log"; }

pending='pending waiting for the VM tests of this commit (vm-gate-finalize sets the result)'
missing='failure changes the image, build or boot tests: add the label vm-tests'
again='the label vm-tests was removed, add the label vm-tests again after review'
soon="failure the label was set less than 5 minutes after a push or a reopening: $again"
unread="failure the time of the push or of the label could not be read: $again"

# gate ACTION [NAME=VALUE]...: one run of vm-gate.yml on the head `new` of #7,
# pushed onto `old`; the exit code is in $code. $gate_script is the script
# that runs: the workflow's, unless a test puts a changed copy there.
gate_script=$work/vm-gate.sh
gate() {
    local action=$1
    shift
    env PATH="$work/bin:$PATH" STATE="$work/state" GH_TOKEN=none \
        REPO=example/appliance NUMBER=7 SHA=new BASE=base BASE_REF=develop \
        HEAD_REPO=example/appliance HEAD_REF=fix/x BEFORE=old ACTION="$action" LABEL='' LABEL_AT_EVENT=false \
        RUN_URL=https://example.invalid/run VM_GATE_PAUSE=0 "$@" \
        bash "$gate_script" >"$work/out" 2>&1 </dev/null
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

# The run of a push waited while the head moved on, and the label was set on
# the commit that is the head now: this commit is not accepted.
moved='failure no VM test result for this commit: it is not the head of the pull request any more'
reset vm-tests
compare base new image/Containerfile=a1
echo newer >"$work/state/head"
gate synchronize
expect "a push that is not the head any more, the label set since: it stays" set "$(label)"
expect "a push that is not the head any more, the label set since: no pending" "$moved" "$(last new)"

reset vm-tests
compare base new image/Containerfile=a1
echo newer >"$work/state/head"
gate labeled LABEL=vm-tests LABEL_AT_EVENT=true
expect "the label's event on a commit that is not the head any more: no pending" "$moved" "$(last new)"

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

echo "# vm-gate.yml: the file mode is part of what the VM tests run (#167)"
# The comparison answers the same before and after the push: only the tree
# tells a `chmod +x` on a file the pull request already changes.
reset vm-tests
compare base new tests/boot/run.sh=t1
compare develop new tests/boot/run.sh=t1
compare develop old tests/boot/run.sh=t1
tree new tests/boot/run.sh=100755
tree old tests/boot/run.sh=100644
had old pending "waiting"
gate synchronize LABEL_AT_EVENT=true
expect "a push that changes only the mode of a file under tests/boot/: the label is removed" \
    "remove-label|status new failure a push that changes what the VM tests run: $again" "$(log)"

# develop brought a file of its own under tests/boot/: it is in the tree, but
# it is none of the pull request's files.
reset vm-tests
compare base new tests/boot/run.sh=t1
compare develop new tests/boot/run.sh=t1
compare develop old tests/boot/run.sh=t1
tree new tests/boot/run.sh=100755 tests/boot/from-develop.sh=100755
tree old tests/boot/run.sh=100755
had old pending "waiting"
gate synchronize LABEL_AT_EVENT=true
expect "a rebase that leaves content and mode as they were: the label stays" set "$(label)"
expect "a rebase that leaves content and mode as they were: pending" "$pending" "$(last new)"

reset vm-tests
compare base new tests/boot/run.sh=t1
compare develop new tests/boot/run.sh=t1
compare develop old tests/boot/run.sh=t1
tree new tests/boot/run.sh=100755
tree old tests/boot/run.sh=100755
jq '.truncated = true' "$work/state/tree-new" >"$work/state/tree-new.tmp" && mv "$work/state/tree-new.tmp" "$work/state/tree-new"
had old pending "waiting"
gate synchronize LABEL_AT_EVENT=true
expect "a tree that is truncated: removed" \
    "failure a push that changes what the VM tests run: $again" "$(last new)"

echo "# vm-gate.yml: every page of a list that is read (#167)"
reset vm-tests
compare base new image/Containerfile=a2
compare develop new image/Containerfile=a2
compare develop old image/Containerfile=a1
had old pending "waiting"
others old 100
gate synchronize LABEL_AT_EVENT=true
expect "a push onto a commit whose pending is behind 100 newer statuses: the label stays" set "$(label)"
expect "a push onto a commit whose pending is behind 100 newer statuses: pending" "$pending" "$(last new)"

reset vm-tests
compare base new image/Containerfile=a1
had new success "the VM tests of this commit passed"
others new 250
gate reopened LABEL_AT_EVENT=true
expect "reopened on a head whose result is behind 250 newer statuses: nothing written" "" "$(log)"

# More labels than a page of 30 holds, vm-tests the last of them.
mapfile -t filler < <(seq -f 'label-%g' 40)
reset "${filler[@]}" vm-tests
compare base new image/Containerfile=a1
gate opened
expect "the label as the 41st of the pull request: pending" "$pending" "$(last new)"

echo "# vm-gate.yml: a label set too soon after a push is removed again (#151)"
# A maintainer (the account 1) read the commit before, and the author (the
# account 2) pushed `new` a moment before the label was set: on the label's
# own event, and on the push's run when it finds the label that was set
# after the push arrived.
for event in "labeled LABEL=vm-tests LABEL_AT_EVENT=true" "synchronize LABEL_AT_EVENT=false" "opened"; do
    read -r -a run <<<"$event"
    reset vm-tests
    compare base new image/Containerfile=a1
    pushed 12:59:30 2
    gate "${run[@]}"
    expect "${run[0]}, the head pushed 30 s before the label: the label is removed, no pending" \
        "remove-label|status new $soon" "$(log)"
    expect "${run[0]}, the head pushed 30 s before the label: the label is gone" removed "$(label)"

    reset vm-tests
    compare base new image/Containerfile=a1
    pushed 12:55:01 2
    gate "${run[@]}"
    expect "${run[0]}, the head pushed 299 s before the label: no pending" "$soon" "$(last new)"

    reset vm-tests
    compare base new image/Containerfile=a1
    pushed 12:55:00 2
    gate "${run[@]}"
    expect "${run[0]}, the head pushed 300 s before the label: pending" "status new $pending" "$(log)"
    expect "${run[0]}, the head pushed 300 s before the label: the label stays" set "$(label)"
done

# The second action of the maintainer: the label set again once the head is
# old enough. The status of the removal is on the commit by then.
reset vm-tests
compare base new image/Containerfile=a1
pushed 12:59:30 2
gate labeled LABEL=vm-tests LABEL_AT_EVENT=true
echo vm-tests >>"$work/state/labels"
labelled 13:01:00 1
gate labeled LABEL=vm-tests LABEL_AT_EVENT=true
expect "the label set again 90 s after the push: removed again" "$soon" "$(last new)"
echo vm-tests >>"$work/state/labels"
labelled 13:04:30 1
gate labeled LABEL=vm-tests LABEL_AT_EVENT=true
expect "the label set again 5 minutes after the push: pending" "$pending" "$(last new)"
expect "the label set again 5 minutes after the push: the label stays" set "$(label)"

# Whoever pushed the head has seen it: Renovate on its own pull requests, and
# `gh pr create --label vm-tests` right after the push (the event of opened,
# then the label's own).
reset vm-tests
compare base new build/tools.Containerfile=b2
pushed 12:59:58 1
gate opened
expect "opened with the label, set 2 s after the push by the one who pushed: pending" "status new $pending" "$(log)"
gate labeled LABEL=vm-tests LABEL_AT_EVENT=true
expect "its label's event: pending again, the label stays" "$pending set" "$(last new) $(label)"

reset vm-tests
compare base new image/Containerfile=a1
pushed 12:59:58 2
labelled 13:00:01 2
gate labeled LABEL=vm-tests LABEL_AT_EVENT=true
expect "the label set twice, the second time by the one who pushed: pending" "$pending" "$(last new)"

reset vm-tests
compare base new image/Containerfile=a1
pushed 12:59:58 1
labelled 13:00:01 3
gate labeled LABEL=vm-tests LABEL_AT_EVENT=true
expect "the label set again by another account than the one who pushed: no pending" "$soon" "$(last new)"

# An account that is gone is nobody's: two of them are not the same one.
reset vm-tests
compare base new image/Containerfile=a1
pushed 12:59:58 -
labelled 13:00:01 -
gate labeled LABEL=vm-tests LABEL_AT_EVENT=true
expect "the label and the push by accounts that are gone: no pending" "$soon" "$(last new)"

# The newest entry of the branch decides, also for a commit that was the head
# before: `new` came back a moment ago, by a push whose own run was dropped.
reset vm-tests
compare base new image/Containerfile=a1
had new success "the VM tests of this commit passed"
pushed 12:30:00 2 other
pushed 12:59:30 2 new
gate labeled LABEL=vm-tests LABEL_AT_EVENT=true
expect "a commit that became the head again a moment before the label: no pending" "$soon" "$(last new)"

# The push is read from the repository the head is in, and of its branch.
reset vm-tests
compare base new image/Containerfile=a1
pushed 12:59:30 2 new someone
fork
gate labeled LABEL=vm-tests LABEL_AT_EVENT=true HEAD_REPO=someone/appliance
expect "a fork's head pushed 30 s before the label: no pending" "$soon" "$(last new)"
expect "a fork's head pushed 30 s before the label: the label is gone" removed "$(label)"

reset vm-tests
compare base new image/Containerfile=a1
pushed 12:59:30 2 new example
fork
gate labeled LABEL=vm-tests LABEL_AT_EVENT=true HEAD_REPO=someone/appliance
expect "a fork's head, a branch of the same name here pushed a moment ago: pending" "$pending" "$(last new)"

# The fork is asked for by the id the pull request names, not by the name of
# the event, which its owner can give to another repository since: under the
# name there is a branch that looks old enough.
reset vm-tests
compare base new image/Containerfile=a1
pushed 12:59:30 2 new someone
fork
gate labeled LABEL=vm-tests LABEL_AT_EVENT=true HEAD_REPO=example/appliance
expect "a fork's head, the event's name is another repository's by now: no pending" "$soon" "$(last new)"

# In a fork its owner decides which account pushes: the one who set the
# label counts as the pusher only for a head in this repository.
reset vm-tests
compare base new image/Containerfile=a1
pushed 12:59:58 1
fork
gate labeled LABEL=vm-tests LABEL_AT_EVENT=true HEAD_REPO=someone/appliance
expect "a fork's head pushed by the account that set the label, 2 s before: no pending" "$soon" "$(last new)"

# A head that was pushed while the pull request was closed shows since the
# pull request was reopened.
reset vm-tests
compare base new image/Containerfile=a1
printf 'reopened\t\t2026-01-01T12:59:30Z\t2\n' >>"$work/state/events"
gate labeled LABEL=vm-tests LABEL_AT_EVENT=true
expect "the head pushed an hour ago, the pull request reopened 30 s before the label: no pending" "$soon" "$(last new)"

reset vm-tests
compare base new image/Containerfile=a1
printf 'reopened\t\t2026-01-01T12:55:00Z\t2\n' >>"$work/state/events"
gate labeled LABEL=vm-tests LABEL_AT_EVENT=true
expect "the pull request reopened 300 s before the label: pending" "$pending" "$(last new)"

# The push's run and the label's, in this order: the second one finds no
# label and leaves the status that says why.
reset vm-tests
compare base new image/Containerfile=a1
pushed 12:59:30 2
gate synchronize LABEL_AT_EVENT=false
gate labeled LABEL=vm-tests LABEL_AT_EVENT=true
expect "the push's run removed the label, the label's run after it: the reason stays" \
    "remove-label|status new $soon" "$(log)"
gate unlabeled LABEL=cicd
expect "another label removed after it: the reason stays" "$soon" "$(last new)"

# The activity is behind the run once: the next reading has the push.
reset vm-tests
compare base new image/Containerfile=a1
touch "$work/state/activity-lags"
gate opened
expect "the activity does not have the push at the first reading: pending" "status new $pending" "$(log)"

reset vm-tests
compare base new image/Containerfile=a1
pushed 12:59:30 1 new example other
gate labeled LABEL=vm-tests LABEL_AT_EVENT=true
expect "another branch pushed a moment ago, by the one who set the label: pending by the head's own push" \
    "$pending" "$(last new)"

# A label older than the head: the label's event waited, and the commit came
# back as the head meanwhile.
reset vm-tests
compare base new image/Containerfile=a1
pushed 13:20:00 2
gate labeled LABEL=vm-tests LABEL_AT_EVENT=true
expect "the head pushed after the label was set: no pending" "$soon" "$(last new)"

# What cannot be read counts as too new.
reset vm-tests
compare base new image/Containerfile=a1
pushed 13:10:00 2 newer
gate labeled LABEL=vm-tests LABEL_AT_EVENT=true
expect "the activity does not name this commit as the tip of the branch: no pending" "$unread" "$(last new)"
expect "the activity does not name this commit: the label is removed" removed "$(label)"

reset vm-tests
compare base new image/Containerfile=a1
: >"$work/state/activity-example"
gate labeled LABEL=vm-tests LABEL_AT_EVENT=true
expect "no activity of the branch: no pending" "$unread" "$(last new)"

reset vm-tests
compare base new image/Containerfile=a1
touch "$work/state/activity-gone"
gate labeled LABEL=vm-tests LABEL_AT_EVENT=true
expect "the activity cannot be read: no pending" "$unread" "$(last new)"

reset vm-tests
compare base new image/Containerfile=a1
fork ''
gate labeled LABEL=vm-tests LABEL_AT_EVENT=true HEAD_REPO=''
expect "the head's repository is gone: no pending" "$unread" "$(last new)"

reset vm-tests
compare base new image/Containerfile=a1
touch "$work/state/events-gone"
gate labeled LABEL=vm-tests LABEL_AT_EVENT=true
expect "the events cannot be read: no pending" "$unread" "$(last new)"

reset vm-tests
compare base new image/Containerfile=a1
: >"$work/state/events"
gate opened
expect "no event that set the label: no pending" "$unread" "$(last new)"

reset vm-tests
compare base new image/Containerfile=a1
pushed 12:59:30 2
touch "$work/state/label-stays"
gate labeled LABEL=vm-tests LABEL_AT_EVENT=true
expect "too soon, and the label cannot be removed: the run fails" 1 "$code"
expect "too soon, and the label cannot be removed: failure, not pending" \
    "failure the label was set less than 5 minutes after a push or a reopening: the label vm-tests could not be removed, remove it by hand" \
    "$(last new)"

# The grace time is for a label that was set after the head arrived. A label
# the push found set has passed the rules of #130, and a pull request that
# changes nothing the VM tests cover needs no label.
reset vm-tests
compare base new image/Containerfile=a2
compare develop new image/Containerfile=a2
compare develop old image/Containerfile=a1
had old pending "waiting"
pushed 13:30:00 2
gate synchronize LABEL_AT_EVENT=true
expect "a push that found the label set: pending, whatever the times" "status new $pending" "$(log)"

reset vm-tests
compare base new docs/en/index.md=a1
pushed 12:59:30 2
gate labeled LABEL=vm-tests LABEL_AT_EVENT=true
expect "nothing the VM tests cover, the label set a moment after the push: success, the label stays" \
    "success no change the VM tests cover set" "$(last new) $(label)"

# The run of the label's event waited while the head moved on: the label is
# not this commit's to lose.
reset vm-tests
compare base new image/Containerfile=a1
pushed 12:59:30 2
echo newer >"$work/state/head"
gate labeled LABEL=vm-tests LABEL_AT_EVENT=true
expect "too soon, on a commit that is not the head any more: the label stays" "$moved set" "$(last new) $(label)"

# The label's event is the newest of more than a page of events: an older one
# of the label, from before it was removed by hand, was the pusher's own.
reset vm-tests
compare base new image/Containerfile=a1
pushed 12:59:30 2
: >"$work/state/events"
labelled 12:10:00 2
for _ in $(seq 100); do labelled 12:20:00 1 automerge; done
labelled 13:00:00 1
gate labeled LABEL=vm-tests LABEL_AT_EVENT=true
expect "the label's event behind 101 older events: no pending" "$soon" "$(last new)"

echo "# the stub answers as the API would: a call that lost a parameter fails (#167)"
# Each changed copy of the script must come out differently; a copy that the
# sed did not change comes out like the workflow's and fails here.
sed 's/-f context=vm-gate/-f context=other/' "$work/vm-gate.sh" >"$work/changed.sh"
gate_script=$work/changed.sh
reset
compare base new docs/en/index.md=a1
gate opened
expect "a status written under another context: vm-gate has none" "" "$(last new)"

sed 's/labels?per_page=100/labels/' "$work/vm-gate.sh" >"$work/changed.sh"
reset "${filler[@]}" vm-tests
compare base new image/Containerfile=a1
gate opened
expect "the labels read without per_page=100: the 41st is not seen" "$missing" "$(last new)"

sed 's/statuses?per_page=100/statuses/; s/gh api --paginate/gh api/' "$work/vm-gate.sh" >"$work/changed.sh"
reset vm-tests
compare base new image/Containerfile=a1
had new success "the VM tests of this commit passed"
others new 30
gate reopened LABEL_AT_EVENT=true
expect "the statuses read as one page of 30: the result behind them is not seen" \
    "failure no VM test result for this commit: remove the label vm-tests and set it again" "$(last new)"

sed 's|gh api --paginate \(.*/events?\)|gh api \1|' "$work/vm-gate.sh" >"$work/changed.sh"
reset vm-tests
compare base new image/Containerfile=a1
pushed 12:59:30 2
: >"$work/state/events"
labelled 12:10:00 2
for _ in $(seq 100); do labelled 12:20:00 1 automerge; done
labelled 13:00:00 1
gate labeled LABEL=vm-tests LABEL_AT_EVENT=true
expect "the events read as one page: the label's newest event is not seen" "$pending" "$(last new)"

sed 's|-f ref="[^"]*" ||' "$work/vm-gate.sh" >"$work/changed.sh"
reset vm-tests
compare base new image/Containerfile=a1
pushed 12:59:30 1 new example other
gate labeled LABEL=vm-tests LABEL_AT_EVENT=true
expect "the activity read without the branch: another branch's push hides the head's" "$unread" "$(last new)"

sed 's|gh api -X GET \(.*/activity"\)|gh api \1|' "$work/vm-gate.sh" >"$work/changed.sh"
reset vm-tests
compare base new image/Containerfile=a1
gate labeled LABEL=vm-tests LABEL_AT_EVENT=true
expect "the activity asked for without -X GET: a POST, which the API refuses" "$unread" "$(last new)"

sed 's/?recursive=1//' "$work/vm-gate.sh" >"$work/changed.sh"
reset vm-tests
compare base new tests/boot/run.sh=t1
compare develop new tests/boot/run.sh=t1
compare develop old tests/boot/run.sh=t1
tree new tests/boot/run.sh=100755
tree old tests/boot/run.sh=100644
had old pending "waiting"
gate synchronize LABEL_AT_EVENT=true
expect "the tree read without recursive=1: the mode under tests/boot/ is not seen" set "$(label)"
gate_script=$work/vm-gate.sh

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

echo "# vm-gate-finalize.yml: every page of the statuses, and job names as data (#167)"
tested vm-tests
had new pending "waiting"
others new 100
finalize
expect "pending behind 100 newer statuses of other contexts: the result is written" "$passed" "$(last new)"

# The names of the jobs are the pull request's. A failed job whose name
# holds a tab or a line break must not read as a build that succeeded.
for name in 'build\tsuccess' 'x\nbuild\tsuccess'; do
    tested vm-tests
    had new pending "waiting"
    jq --arg name "$name" '.jobs[0] = {name: ($name | "\"\(.)\"" | fromjson), status: "completed", conclusion: "failure"}' \
        "$work/state/jobs" >"$work/state/jobs.new" && mv "$work/state/jobs.new" "$work/state/jobs"
    finalize
    expect "a failed job named $name: no result of the build" \
        "failure the VM tests of this commit did not pass (build: missing)" "$(last new)"
done

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
