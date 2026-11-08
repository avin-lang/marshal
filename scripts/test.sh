#!/bin/sh
# Builds marshal and runs every test: the unit tests, and the end-to-end tests, which drive the
# executable just built through $MARSHAL_BIN. $AVIN names the avin compiler (default: `avin` on
# PATH); arguments are passed to `avin test` (a filter, for one).
cd "$(dirname "$0")/.."
avin=${AVIN:-avin}
mkdir -p .avin/test
# Never the real take-slot directory: each end-to-end test gives its daemon one of its own.
export MARSHAL_TAKE_SLOT_DIR=
# marshal's own steps and types are this tree's, and the stock steps are compiled with $AVIN.
export MARSHAL_STOCK="$PWD/stock"
export AVIN="$avin"

# The end-to-end tests record each home they make in .avin/test/homes. However this script ends
# (finished, interrupted, terminated), a daemon still running under one of those homes is ended
# here: first TERM, then KILL, and only when the process really is this tree's marshal.
bin="$PWD/.avin/test/marshal"
reap() {
    for entry in .avin/test/homes/*; do
        [ -f "$entry" ] || continue
        home=$(sed -n 1p "$entry")
        pid=$(cat "$home/daemon.pid" 2>/dev/null)
        case "$pid" in ''|*[!0-9]*) continue ;; esac
        case "$(ps -p "$pid" -o command= 2>/dev/null)" in "$bin daemon"*) ;; *) continue ;; esac
        kill -TERM "$pid" 2>/dev/null
        for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
        kill -KILL "$pid" 2>/dev/null
    done
    rm -rf .avin/test/homes
}
trap 'reap' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

"$avin" build . -o .avin/test/marshal || exit $?
MARSHAL_BIN="$bin" "$avin" test . "$@"
