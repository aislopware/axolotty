#!/bin/bash
# The long checks the gate has no time for (TESTING.md, "Knobs"). Each step
# runs on its own and the script fails if any did; a sanitizer's report can
# follow a "passed" line, so the exit code is what counts. One run at a time:
# a second SwiftPM on this .build waits silently for the first.
#
#   scripts/deep.sh            everything (about 25 minutes)
#   scripts/deep.sh flakes     one step: tsan | asan | flakes | sim | fuzz
#
# It tests HEAD, in a worktree of its own with its own .build (AXDEEP_TREE,
# default $TMPDIR/axolotty-deep). Edits made while it runs can't reach it,
# and builds in this tree don't wait on its lock. Commit first: changes not
# committed are not in the run.
set -u
cd "$(dirname "$0")/.." || exit 1
if [ -z "${AXDEEP_INSIDE:-}" ]; then
    tree=${AXDEEP_TREE:-${TMPDIR:-/tmp}/axolotty-deep}
    tree=${tree%/}
    sha=$(git rev-parse HEAD) || exit 1
    if [ -d "$tree/.git" ] || [ -f "$tree/.git" ]; then
        git -C "$tree" checkout -q --detach "$sha" || exit 1
    else
        git worktree add -q --detach "$tree" "$sha" || exit 1
    fi
    # Built by scripts/build-ghostty-vt.sh, not tracked.
    rsync -a --delete Vendor/GhosttyVT.xcframework "$tree/Vendor/" || exit 1
    [ -n "$(git status --porcelain --untracked-files=no)" ] && echo "deep: uncommitted changes are not in this run"
    echo "deep: $(git log -1 --format='%h %s' "$sha") in $tree"
    AXDEEP_INSIDE=1 exec "$tree/scripts/deep.sh" "$@"
fi
logs=.build/deep
mkdir -p "$logs"
failed=()

# Each step runs under the watchdog: STALL seconds with no new output, or
# TOTAL in all, and its stacks are sampled into its log and it is ended.
# The long tests print progress, so a quiet step is a stuck one.
step() {
    local name=$1 stall=$2 total=$3
    shift 3
    printf '%-8s ' "$name"
    scripts/watchdog.sh "$stall" "$total" "$logs/$name.log" -- "$@"
    local rc=$?
    # A stray SIGPIPE is survived, as in production, but is still a failure.
    [ $rc -eq 0 ] && grep -q '^AXTEST SIGPIPE' "$logs/$name.log" && rc=141
    if [ $rc -eq 0 ]; then
        echo "ok"
    elif [ $rc -eq 124 ]; then
        echo "HUNG ($(grep -m1 '^WATCHDOG' "$logs/$name.log"); stacks in $logs/$name.log)"
        failed+=("$name")
    else
        echo "FAILED (exit $rc, $logs/$name.log)"
        failed+=("$name")
    fi
}

only=("$@")
run() { [ ${#only[@]} -eq 0 ] || [[ " ${only[*]} " == *" $1 "* ]]; }

run tsan && step tsan 300 1800 swift test --sanitize=thread
# ASan's fork handler takes its allocator lock while other test threads
# allocate, and on Darwin that deadlocks: the in-process fork tests run alone.
# (ptyd, which forks for real, is one thread.)
run asan && step asan 300 1800 bash -c 'swift test --sanitize=address --skip PTYSpawn &&
    swift test --sanitize=address --filter PTYSpawn --no-parallel'
# The suites on real sockets and processes, repeated until one fails.
# Anchored on the suite: a bare HostTests also matches the target, AxHostTests.
run flakes && step flakes 300 1800 env AXREAP_RUNS=1000 swift test --filter '\.(FaultyLinkTests|RemoteLinkTests|HolderTests|HostTests|TailnetTests)/' \
    --maximum-repetitions 30 --repeat-until fail
run sim && step sim 180 1200 env AXSIM_SEEDS=200 swift test --filter LinkSimTests
run fuzz && step fuzz 180 900 env AXFUZZ_RUNS=200000 AXMODEL_RUNS=20000 swift test --filter 'WireFuzzTests|SendLanesModelTests'

if [ ${#failed[@]} -gt 0 ]; then
    echo "failed: ${failed[*]}"
    exit 1
fi
