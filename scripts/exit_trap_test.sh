#!/bin/sh
# Tests the EXIT trap of scripts/test.sh: a copy of it runs in a private tree with a stub in place
# of the compiler (exit_trap_stub.sh), so no real daemon, build or ~/.marshal is involved.
# Whether the run ends normally, fails or is interrupted, the daemon left under a recorded home is
# gone afterwards, the recorded homes are removed (the record and the home directories, logs and
# all), the script's exit status is kept, and a process that is not this tree's marshal is left
# alone, with its home.
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/marshal-exit-trap.XXXXXX") || exit 1
failed=0
decoys=""

cleanup() {
    for pid in $decoys; do kill -KILL "$pid" 2>/dev/null; done
    rm -rf "$work"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $1"
    failed=1
}

alive() { kill -0 "$1" 2>/dev/null; }

# run MODE EXPECTED-STATUS: one run of the copied test.sh in a fresh tree.
run() {
    mode=$1
    want=$2
    tree="$work/$mode"
    mkdir -p "$tree/scripts"
    cp "$here/test.sh" "$tree/scripts/test.sh"
    cp "$here/exit_trap_stub.sh" "$tree/stub.sh"
    chmod +x "$tree/stub.sh"
    STUB_ROOT="$tree/stub" STUB_MODE="$mode" AVIN="$tree/stub.sh" sh "$tree/scripts/test.sh" > "$tree/out" 2>&1
    got=$?
    [ "$got" = "$want" ] || fail "$mode: exit status $got, wanted $want"
    daemon=$(cat "$tree/stub/daemon.pid")
    decoy=$(cat "$tree/stub/decoy.pid")
    decoys="$decoys $decoy"
    if alive "$daemon"; then
        fail "$mode: the daemon is still running"
        kill -KILL "$daemon" 2>/dev/null
    fi
    alive "$decoy" || fail "$mode: a process that is not this tree's marshal was killed"
    [ ! -e "$tree/.avin/test/homes" ] || fail "$mode: the recorded homes were not removed"
    [ ! -e "$tree/stub/home" ] || fail "$mode: the home of the stopped daemon is still there"
    [ ! -e "$tree/stub/idle" ] || fail "$mode: the home with no daemon is still there"
    [ -d "$tree/stub/decoy" ] || fail "$mode: the home of a process that is not this tree's was removed"
}

run ok 0
run fail 3
run interrupt 143

if [ "$failed" = 0 ]; then
    echo "exit trap: ok"
fi
exit "$failed"
