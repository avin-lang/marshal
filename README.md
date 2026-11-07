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
marshal status [--json]                    the budget in use; --json: one JSON object with the running and queued jobs
marshal top                                a live view of the budget, the jobs and their logs; h lists its keys
marshal stop [--wait | --force]            stops the daemon; refused while jobs run unless it may wait for them or kill them
marshal daemon                             runs the daemon in the foreground
```

`marshal --help` (or `-h`, or `help`) prints these lines and the options below; `marshal <command> --help`
describes one command, and both exit 0. A bare `marshal` prints the same usage to standard error and
exits 2. After `--` nothing is an option, so `marshal run -- prog --help` runs `prog`.

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
`reserve`, `deadline_floor` (`"5m"`), `learn_window`, `learn_min_runs` and `take_slot` (below).

`marshal status --json` prints `units`, `unit_budget`, `mem`, `mem_budget`, `rss` (what the
running jobs hold in RAM, in bytes), `machine_mem` (the machine's memory, 0 if unknown), `landing` (the landing
job's id or null), `take_slot` (`dir`, `units`, `waiting`, `landing`, or null when none is shared),
and `running` and `queued`, arrays of jobs as [the protocol](docs/protocol.md) writes them.

## Sharing the machine with take-slot.zsh

While scripts move to marshal one at a time, sysl's agents keep running heavy commands through
`take-slot.zsh`. The two share **one unit budget and one landing lane** through take-slot's own lock
directory, with no change to take-slot:

- **marshal counts take-slot's runs.** A live `slot-units/<pid>` file counts its units, and an old
  `build*.lock` slot held by a live process counts 4. take-slot's waiters (`slot-waiting/<time>-<pid>`)
  stand in marshal's queue by arrival time: a waiter that fits keeps its units, one that does not is
  overtaken only by a job expected to end before it could start, and since take-slot's runs may end
  at any moment, nothing overtakes a waiter or job that is waiting for them.
- **take-slot counts marshal's jobs.** A development job is written as `slot-units/<its pid>`
  holding its units, under take-slot's `slot-units.mutex`, and removed when it ends. While a job
  waits, the daemon keeps a ticket of the first waiting job's arrival in `slot-waiting`, so
  take-slot's later runs wait behind it as they wait behind each other.
- **One landing lane.** A `--landing` job takes `land.lock` as take-slot does and holds it until it
  ends; while a take-slot landing holds it, marshal's landing job waits.
- Files whose process has died are removed by whichever side meets them; a daemon that starts after
  one died removes what that one left (its ticket, and its lost jobs' files).

take-slot does not tell marshal when its runs end, so while jobs wait the daemon reads the
directory every 3 seconds; take-slot itself looks every 10 (20 for a landing). The directory is
`take_slot` in `config.json` (`""` for none), overridden by `$MARSHAL_TAKE_SLOT_DIR` (empty for
none); by default it is `/Users/ed/dev/sysl-lang/sysl/.git` when that exists. Keep take-slot's
`SLOT_BUDGET` and marshal's `units` equal (12 both by default): each side measures the other's use
against its own budget. `marshal status` shows what take-slot holds.

## marshal top

`marshal top` is a live view of the daemon for people, drawn in the terminal with
[tui](https://github.com/avin-lang/tui) and asked of the daemon once a second over its socket (the
`snapshot` request).

- **Header**: the daemon's uptime, how many jobs run and wait, who holds the landing lane (a job,
  take-slot, or free) and the filter; a bar of the unit budget, marshal's development units in green
  and take-slot's share after them in magenta, with take-slot's waiting runs; a bar of the memory
  budget the running jobs reserve, then what they hold in RAM (`rss`) and the machine's memory.
- **Memory**: RESV is the memory a job declared with `--mem`. RSS is what a running job's whole
  process tree holds in RAM, measured by the daemon every second, and PEAK the most it was measured
  holding, kept once it ends; `-` where there is none.
- **Jobs**: running jobs, then queued ones, then the last ten that ended, the latest first. ELAPSED
  counts on between snapshots; DEADLINE is a running job's time left, yellow under a quarter of its
  deadline or five minutes and red under a tenth or one minute, and a queued job's deadline to come.
  A queued job's STATE is its place in its lane's queue and why it waits: `no units`, `no memory`,
  `lane busy` (another landing job holds the lane), `take-slot` (what take-slot.zsh holds or a
  take-slot run ahead of it), or `behind N`, when it would fit but would delay job N at the head of
  the queue. An ended job shows `exit N` (green for 0, red otherwise), `killed`, `timeout`, `lost`,
  `cancelled` or `signal N`.
- **Keys**: Up, Down, PgUp, PgDn, Home, End select a job; Enter or `l` opens its log in a pane under
  the table, following the end as it grows (PgUp, PgDn, Home, End scroll it while it is open, Esc
  closes it); `k` kills the selected job after `y`; `f` shows all jobs, the running, the queued or
  the ended ones; `h` the keys; `q` quits.
- **No daemon**: top does not start one by itself. It says there is none, looks again every second,
  and `s` starts one. A daemon older than the `snapshot` request is named as such.

The protocol between the command line and the daemon is in [docs/protocol.md](docs/protocol.md),
and the choices behind the design in [docs/decisions.md](docs/decisions.md).

## Building and testing

```
avin build . -o marshal
scripts/test.sh
```

marshal depends on [tui](https://github.com/avin-lang/tui), fetched at the commit `avin.hocon` pins.

`scripts/test.sh` builds marshal and runs the unit tests (scheduler, deadlines, protocol, event log,
settings, take-slot's format, top's screen and keys) and the end-to-end tests, among them `top`
under `script` in a pseudo-terminal, which start real daemons in temporary homes,
each with a take-slot directory of its own, and run the real `take-slot.zsh` against it (`$TAKE_SLOT`
names the script). `$AVIN` names the compiler.
