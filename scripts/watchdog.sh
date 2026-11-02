#!/bin/bash
# Runs a command and says why it hangs instead of letting it sit, after
# Slopty's xtask watchdog. Every 15 s it looks at the log: when nothing new
# has come for STALL seconds, or the whole run passed TOTAL, it lists every
# process under the run, samples each leaf (`sample`, bounded), writes all
# of it into the log, ends the run's process group and exits 124.
#
#   scripts/watchdog.sh STALL TOTAL LOG -- command args...
#
# A run that waits on something silent (a deadlock, a lock another SwiftPM
# holds, a test blocked in the kernel) is caught in minutes, with its stacks.
set -u
[ $# -ge 5 ] && [ "$4" = "--" ] || {
    echo "usage: $0 STALL TOTAL LOG -- command..." >&2
    exit 2
}
stall=$1 total=$2 log=$3
shift 4
poll=15

# Its own process group, so the whole tree can be ended at once.
python3 -c 'import os, sys; os.setpgrp(); os.execvp(sys.argv[1], sys.argv[1:])' "$@" >"$log" 2>&1 &
pid=$!
start=$SECONDS
last_size=-1
last_change=$SECONDS

# Runs a command for at most N seconds (macOS has no `timeout`).
bounded() {
    local n=$1
    shift
    "$@" &
    local c=$!
    (sleep "$n" && kill "$c" 2>/dev/null) &
    local k=$!
    wait "$c"
    kill "$k" 2>/dev/null
}

report() {
    {
        echo
        echo "WATCHDOG: $1 after $((SECONDS - start)) s; the processes under the run:"
        local all leaves=()
        all=$(pgrep -g "$pid" | tr '\n' ',')
        ps -o pid=,ppid=,stat=,etime=,command= -p "${all%,}" | cut -c1-200
        for p in ${all//,/ }; do
            # A leaf: nothing under the run has it as parent.
            [ -z "$(pgrep -P "$p")" ] && leaves+=("$p")
        done
        for p in "${leaves[@]:0:6}"; do
            echo "--- sample of $p"
            # Bounded, so the watchdog never becomes the hang itself.
            bounded 20 sample "$p" 2 2>/dev/null | grep -E '^ +[+|: ]*[0-9]+ ' | head -60 | cut -c1-200
        done
    } >>"$log"
}

while kill -0 "$pid" 2>/dev/null; do
    sleep "$poll" &
    wait $! 2>/dev/null
    kill -0 "$pid" 2>/dev/null || break
    size=$(stat -f %z "$log" 2>/dev/null || echo 0)
    if [ "$size" != "$last_size" ]; then
        last_size=$size
        last_change=$SECONDS
    fi
    why=""
    [ $((SECONDS - last_change)) -ge "$stall" ] && why="no output for $((SECONDS - last_change)) s"
    [ $((SECONDS - start)) -ge "$total" ] && why="still running at its bound of $total s"
    if [ -n "$why" ]; then
        report "$why"
        kill -TERM -- "-$pid" 2>/dev/null
        sleep 5
        kill -KILL -- "-$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        echo "WATCHDOG: ended ($why)" >>"$log"
        exit 124
    fi
done
wait "$pid"
