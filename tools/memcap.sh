#!/bin/sh
# memcap.sh <GB> <cmd…>: runs cmd with a memory cap. cmd runs in a process group of its own; every 0.5 s the
# memory footprint (phys_footprint, what Activity Monitor's "Memory" shows: it includes MLX's Metal buffers, which
# resident memory, `ps -o rss=`, misses) of that group, and of every process cmd started that left it (uv may put
# its child in a group of its own), is added up. Above <GB> gigabytes all of them are killed (SIGKILL) and memcap
# exits 137 with a message on stderr; otherwise it exits with cmd's status. The footprint is read by a few lines of
# C compiled with clang at the start (proc_pid_rusage); without clang memcap says so and falls back to RSS.
#
#   tools/memcap.sh 2 uv run --extra dev python tools/parity/e5_gate.py
#
# Every model or runtime experiment runs under it (plan, Global Constraints: "Memory cap").

usage() {
    echo "usage: tools/memcap.sh <GB> <cmd…>   (GB: a positive number, e.g. 2 or 1.5)" >&2
    exit 2
}

[ $# -ge 2 ] || usage
cap_gb=$1
shift
case $cap_gb in
    '' | *[!0-9.]* | *.*.* | . ) usage ;;
esac
cap_kb=$(awk -v g="$cap_gb" 'BEGIN { printf "%d", g * 1024 * 1024 }')
[ "$cap_kb" -gt 0 ] || usage

# The footprint reader: "pid footprint_kb" per pid given (proc_pid_rusage, RUSAGE_INFO_V4).
work=$(mktemp -d "${TMPDIR:-/tmp}/memcap.XXXXXX") || exit 1
footprint="$work/footprint"
cat > "$work/footprint.c" <<'C'
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        struct rusage_info_v4 ri;
        int pid = atoi(argv[i]);
        if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ri) == 0)
            printf("%d %llu\n", pid, (unsigned long long)(ri.ri_phys_footprint / 1024));
    }
    return 0;
}
C
if ! clang -O2 -o "$footprint" "$work/footprint.c" 2>/dev/null; then
    echo "memcap: clang is missing: capping resident memory (RSS), which misses GPU memory (MLX)" >&2
    footprint=""
fi

# The process group: perl makes itself a group leader, then becomes cmd (same pid, so pid = group id).
perl -e 'setpgrp(0, 0) or die "memcap: setpgrp: $!\n"; exec { $ARGV[0] } @ARGV or die "memcap: can not run $ARGV[0]: $!\n"' "$@" &
leader=$!

# The group's processes and every descendant of the leader (by parent pid), as "pid rss_kb" lines.
members() {
    ps -A -o pid= -o ppid= -o pgid= -o rss= | awk -v root="$leader" '
        { pid[NR] = $1; ppid[NR] = $2; pgid[NR] = $3; rss[NR] = $4 }
        END {
            n = NR; inside[root] = 1
            for (i = 1; i <= n; i++) if (pgid[i] == root) inside[pid[i]] = 1
            do {
                grew = 0
                for (i = 1; i <= n; i++) if (!(pid[i] in inside) && (ppid[i] in inside)) { inside[pid[i]] = 1; grew = 1 }
            } while (grew)
            for (i = 1; i <= n; i++) if (pid[i] in inside) print pid[i], rss[i]
        }'
}

# The memory of the processes of a members() snapshot, in KB: their footprints, else (no reader) their RSS.
used_by() {
    if [ -n "$footprint" ]; then
        # shellcheck disable=SC2046
        "$footprint" $(printf '%s\n' "$1" | awk '{ print $1 }') | awk '{ s += $2 } END { printf "%d", s }'
    else
        printf '%s\n' "$1" | awk '{ s += $2 } END { printf "%d", s }'
    fi
}

kill_all() {
    kill -KILL -- "-$leader" 2>/dev/null
    for p in $1; do kill -KILL "$p" 2>/dev/null; done
}

trap 'kill -TERM -- "-$leader" 2>/dev/null; for p in $(members | awk "{ print \$1 }"); do kill -TERM "$p" 2>/dev/null; done' INT TERM HUP
trap 'rm -rf "$work"' EXIT

while kill -0 "$leader" 2>/dev/null; do
    snapshot=$(members)
    used_kb=$(used_by "$snapshot")
    if [ "$used_kb" -gt "$cap_kb" ]; then
        kill_all "$(printf '%s\n' "$snapshot" | awk '{ print $1 }')"
        wait "$leader" 2>/dev/null
        echo "memcap: $1 used $((used_kb / 1024)) MB, more than the cap of $cap_gb GB: killed" >&2
        exit 137
    fi
    sleep 0.5
done
wait "$leader"
