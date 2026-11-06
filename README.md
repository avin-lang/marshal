# marshal

marshal runs the heavy commands of building, testing and releasing on one machine without them
fighting over it. Each command is a **job** with a weight in **units** and an amount of **memory**;
a daemon starts jobs while they fit a budget, keeps the rest in a first-come queue, gives the
**landing lane** to the one job everyone is waiting for, and stops any job that runs far past how
long jobs of its kind normally take. Written in Avin.

## Commands

```
marshal submit [options] -- <command...>   queue a job; prints its id
marshal run [options] -- <command...>      submit and wait: prints the log's path, then the result; exits with the job's status
marshal wait <id>                          waits for the job; prints one result line; exits with the job's status
marshal ls                                 jobs queued, running and recently ended
marshal kill <id>                          stops the job's whole process tree (a queued job is cancelled)
marshal tail <id> [-f] [-n <lines>]        the job's log; -f follows it until the job ends
marshal status                             the budget in use
marshal stop [--wait | --force]            stops the daemon; refused while jobs run unless it may wait for them or kill them
marshal daemon                             runs the daemon in the foreground
```

Options of `submit` and `run`:

| Option | Meaning |
| --- | --- |
| `--kind <k>` | What the job is, for learning its deadline. Default: `test` when a word of the command is `test`, otherwise `build`. |
| `--units <n>` | Its weight. Default: 4 for a `test`, 1 for anything else. |
| `--mem <size>` | Memory it needs: `29G`, `512M` (powers of 1024). Default 0. |
| `--landing` | The landing lane: starts before every development job, outside the unit budget, at normal priority. One landing job runs at a time. |
| `--dir <d>` | Where it runs, relative to the current directory. Default: the current directory. |
| `--deadline <t>` | Stops it after `t`: a number of minutes, or `90s`, `30m`, `2h`. Default: learned for its kind. |

A job runs with the caller's environment, in a process group of its own, under `nice -n 15` unless it
is a landing job, with its standard output and error in `~/.marshal/jobs/<id>.log`.

**Exit statuses.** `wait` and `run` exit with the job's own code; 128 + the signal for a job ended by
a signal (143 for `kill`); 124 for a job stopped at its deadline; 143 for a job cancelled before it
started; 125 for a job lost when a daemon died. marshal's own failures (a bad command line, an unknown
job, no daemon) exit 2.

```
$ marshal run --kind test -- sysl test compiler --timeout 1800
marshal: job 14: log /Users/me/.marshal/jobs/14.log
marshal: job 14 exited 0 after 18m12s; log /Users/me/.marshal/jobs/14.log
$ id=$(marshal submit --landing -- ./scripts/train.sh)
$ marshal wait $id
```

## The daemon

The first command that finds no daemon starts one in the background; it listens on `sock` in
marshal's home, `~/.marshal` or `$MARSHAL_HOME`. A `wait` is answered the moment the job's process
ends: nothing polls.

- **Budget.** Development jobs share 12 units and the machine's memory less 8G. A job starts when
  its units and memory fit beside what runs. The queue is first come, first served; a later job
  may start ahead of a head that does not fit only when it fits now and is expected to end before
  the head could start, so it never delays the head.
- **Deadlines.** A kind's deadline is twice the median of its last 20 successful runs, never under 5
  minutes; until it has 3 runs it is 20 minutes for a build, 45 for a test, 30 for anything else and
  120 for a landing job. A job past its deadline has its busiest process sampled (`sample`, 5
  seconds, to `jobs/<id>.sample.txt`), then its group gets TERM and, 5 seconds later, KILL.
- **Events.** `events.jsonl` records every job's `submitted`, `started` and ending (`finished`,
  `timeout`, `killed`, `lost`), each with the time, the job, and its durations and exit status.
  Deadlines are learned from it, and a daemon that starts after one died records the jobs that
  were left open as `lost`.
- **Stopping.** `marshal stop` or a TERM signal ends the daemon. TERM, like `stop --force`, kills
  what runs and cancels what waits.

`config.json` in marshal's home changes the defaults: `units`, `memory` (`"56G"` or bytes),
`reserve`, `deadline_floor` (`"5m"`), `learn_window` and `learn_min_runs`.

The protocol between the command line and the daemon is in [docs/protocol.md](docs/protocol.md),
and the choices behind the design in [docs/decisions.md](docs/decisions.md).

## Building and testing

```
avin build . -o marshal
scripts/test.sh
```

`scripts/test.sh` builds marshal and runs the unit tests (scheduler, deadlines, protocol, event log,
settings) and the end-to-end tests, which start real daemons in temporary homes. `$AVIN` names the
compiler.
