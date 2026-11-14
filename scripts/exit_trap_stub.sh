#!/bin/sh
# A stand-in for the avin compiler, used only by exit_trap_test.sh to drive scripts/test.sh.
# `build . -o OUT` writes an empty executable; `test` plays one end-to-end test that leaves a
# daemon behind (recorded under .avin/test/homes, as the real tests do), plus a decoy home whose
# pid file names an ordinary process that is not this tree's marshal, and a home with no daemon.
# Each pid is also written beside the homes, which the trap removes. $STUB_MODE says how the
# run ends: ok (the daemon is stopped first), fail (exit 3) or interrupt (TERM to the script).
case "$1" in
build)
    printf '#!/bin/sh\n' > "$4"
    chmod +x "$4"
    exit 0
    ;;
esac

mkdir -p .avin/test/homes
home="$STUB_ROOT/home"
decoy="$STUB_ROOT/decoy"
idle="$STUB_ROOT/idle"
mkdir -p "$home" "$decoy" "$idle"
printf 'a log\n' > "$home/events.jsonl"
printf 'a log\n' > "$idle/events.jsonl"
printf '%s\n' "$home" > .avin/test/homes/daemon
printf '%s\n' "$decoy" > .avin/test/homes/decoy
# a home whose test failed before its clean-up, with no daemon left
printf '%s\n' "$idle" > .avin/test/homes/idle

bash -c 'exec -a "$0 daemon" sleep 300' "$MARSHAL_BIN" > /dev/null 2>&1 &
echo $! > "$home/daemon.pid"
echo $! > "$STUB_ROOT/daemon.pid"
sleep 300 > /dev/null 2>&1 &
echo $! > "$decoy/daemon.pid"
echo $! > "$STUB_ROOT/decoy.pid"

case "$STUB_MODE" in
ok)
    kill "$(cat "$home/daemon.pid")"
    exit 0
    ;;
fail)
    exit 3
    ;;
interrupt)
    kill -TERM "$PPID"
    sleep 1
    exit 0
    ;;
esac
