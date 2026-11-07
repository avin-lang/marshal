# marshal

marshal runs the heavy commands of building, testing and releasing on one machine without them
fighting over it. Each command is a **job** with a weight in **units** and an amount of **memory**;
a daemon starts jobs while they fit a budget, keeps the rest in a first-come queue, gives the
**landing lane** to the one job everyone is waiting for, and stops any job that runs far past how
long jobs of its kind normally take.

Work that takes several steps (merge some branches, build, test, land them, clean up) is written
as a **job type**: a small data file naming the steps, which marshal runs as one job. marshal ships
one type, **train**, which gates a batch of git branches together and lands them; your project can
add its own. marshal is written in [Avin](https://github.com/avin-lang/avin).

## Install

With Homebrew:

```
brew install avin-lang/tap/marshal
```

From source, with an Avin compiler on your `PATH`:

```
git clone https://github.com/avin-lang/marshal
cd marshal
avin build . -o marshal
```

Put `marshal` on your `PATH`, and the `stock` directory at `share/marshal` beside the directory that
holds it (`/usr/local/bin/marshal` and `/usr/local/share/marshal/`), or name it with
`$MARSHAL_STOCK`. marshal's own steps are Avin programs, compiled the first time a type uses them, so
running the `train` type needs an Avin compiler too (`$AVIN`, or `avin` on the `PATH`).

## A first job

```
$ marshal run -- make test
marshal: job 1: log /Users/me/.marshal/jobs/1.log
marshal: job 1 exited 0 after 2m12s; log /Users/me/.marshal/jobs/1.log
```

The first command starts the daemon. `marshal run` waits and exits with the job's own status;
`marshal submit` queues the job and prints its id, for `marshal wait <id>` later. `marshal top`
shows what runs and waits, live.

## A first train

The train merges branches onto a target branch, as the remote has them, in a worktree of its own;
runs a build command and a test command there; and, when both pass, pushes the merged commit to the
target and tears each branch down. A throwaway repository shows the whole of it:

```
git init -q --bare -b main /tmp/demo.git
git clone -q /tmp/demo.git /tmp/demo
cd /tmp/demo
printf 'test:\n\ttest ! -e broken\n' > Makefile
git add Makefile
git commit -q -m start
git push -q origin main
git switch -q -c one
echo 1 > one.txt
git add one.txt
git commit -q -m one
git push -q -u origin one
git switch -q -c two main
echo 2 > two.txt
git add two.txt
git commit -q -m two
git push -q -u origin two
git switch -q main
marshal train --test "make test" one two
```

```
marshal: job 1: train, log /Users/me/.marshal/jobs/1.log
marshal: job 1 exited 0 after 2.1s; log /Users/me/.marshal/jobs/1.log
marshal: train green
  landed one two as 3f0c…
```

`main` on the remote is now the merge of both branches, your own `main` has followed it, and the
branches are gone, locally and on the remote. Had `make test` failed, nothing would have landed and
nothing would have been torn down. `marshal train --help` lists every parameter:

| Parameter | Meaning |
| --- | --- |
| `<branch>...` / `--branch` | the branches to batch, in order, as the remote has them |
| `--test <command>` | the test command, run by `sh` in the merged tree (required) |
| `--build <command>` | a build command run before it (none by default) |
| `--remote <name>` | the remote (default `origin`) |
| `--target <branch>` | the branch to land on (default: the one the remote's HEAD names) |
| `--on-red bisect` | on red, find the branches to blame and land the rest (default `report`) |
| `--fail-map <command>` | a command that names the branch behind each failing test |
| `--step-deadline <t>` | how long the build and the test may each run (default `12h`) |

The train keeps git's safety rules, and refuses rather than forces: it lands only a fast-forward of
the target as the remote has it at that moment, and pushes that very commit; it tears nothing down
unless the push succeeded; it deletes a branch with `git branch -d`, never `-D`; it removes a
branch's worktree without `--force`, so one with changes is kept; and it deletes the remote's copy
of a branch only where what landed contains it, so a branch amended or pushed again after the merge
is kept. Whatever it keeps, it says, and the run is then red.

A test command that knows which branch broke a test says `=== FAIL <test> <branch>` on its output;
the train then blames that branch without bisecting. See [the step protocol](docs/protocol.md#the-step-protocol).

## Job types

A type is a `.job` file. `marshal run-type <name>` looks for it in the project's
`.marshal/types/<name>.job`, then `~/.marshal/types/<name>.job`, then marshal's own types; a path
names a file directly. `marshal run-type <name> --help` describes it. This one builds and tests the
working tree (it is [examples/types/gate.job](examples/types/gate.job)):

```
{
  "about": "Builds and tests the working tree, with a deadline on each.",
  "lane": "dev",
  "units": 4,
  "params": {
    "build": {"default": "make", "about": "the build command, run by sh"},
    "test": {"default": "make test", "about": "the test command, run by sh"}
  },
  "steps": [
    {"name": "build", "run": ["sh", "-c", "${build}"], "deadline": "30m"},
    {"name": "test", "run": ["sh", "-c", "${test}"], "deadline": "1h", "on_failure": "report"}
  ]
}
```

```
marshal run-type gate --test "make check"
```

A step is any program: a shell command, a script, an Avin program (`avin:steps/check.avin`, compiled
once and cached). It gets its parameters as arguments (`${name}`) and as variables
(`$MARSHAL_PARAM_NAME`), and talks to marshal with lines on its output, such as `=== HEAD <sha>` and
`=== FAIL <test> <branch>`. [docs/jobs.md](docs/jobs.md) is the reference for the file, and
[docs/protocol.md](docs/protocol.md#the-step-protocol) for the lines.

## Commands

```
marshal submit [options] -- <command...>   queue a job; prints its id
marshal run [options] -- <command...>      submit and wait: prints the log's path, then the result; exits with the job's status
marshal run-type <type> [parameters]       runs a job type's steps as one job and waits; <type> --help lists its parameters
marshal train [parameters] <branch...>     run-type train: merges the branches, builds and tests them, lands them when green
marshal wait <id> | --until <cond> [--timeout <t>] [--since <t>]  waits for the job, prints one result line, exits with its status; or waits for an event, prints it, exits 0 (124 on timeout)
marshal events [--follow] [--since <t>] [<filter>]  the logged events as JSON lines; --follow goes on streaming them until killed
marshal ls                                 jobs queued, running and recently ended
marshal kill <id>                          stops the job's whole process tree (a queued or waiting job is cancelled)
marshal rerun <id>                         submits an ended job again: its command, directory, environment, kind and resources; prints the new id
marshal hold <id>                          keeps a queued job from starting; it keeps its place
marshal release <id>                       lets a held job start again
marshal priority <id> <n> | --urgent       places a queued job in its lane: higher first; --urgent: the back of the urgent band
marshal pause [<id>]                       stops a running job's processes, keeping its units, its deadline's clock stopped; with no id, holds the queue
marshal resume [<id>]                      continues a paused job; with no id, releases the queue
marshal tail <id> [-f] [-n <lines>]        the job's log; -f follows it until the job ends
marshal status [--json]                    the budget in use; --json: one JSON object with the running and queued jobs
marshal history [options]                  ended jobs from the event log, newest first: id, kind, outcome, exit code, duration, when
marshal stats [options]                    per kind from the event log: count, success rate, p50/p90/max duration, timeouts, deadline, peak memory
marshal top                                a live view of the budget, the jobs and their logs; h lists its keys
marshal stop [--wait | --force]            stops the daemon; refused while jobs run unless it may wait for them or kill them
marshal restart                            the daemon becomes the marshal installed now, keeping its jobs running and queued
marshal version                            marshal's version, and the running daemon's
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
| `--urgent` | Queues it in its lane's urgent band: ahead of every job not urgent, behind the urgent jobs already queued. |
| `--dir <d>` | Where it runs, relative to the current directory. Default: the current directory. |
| `--deadline <t>` | Stops it after `t`: a number of minutes, or `90s`, `30m`, `2h`. Default: learned for its kind. |
| `--after <ids>` | Waits until jobs `<ids>` (`3` or `3,4`) have ended; the same as `--after-ok`. |
| `--after-ok <ids>` | Waits until they have ended, then queues it if each exited 0, and otherwise cancels it (`dependency-failed`, exit 126), which cancels in turn what waits for it. |
| `--after-any <ids>` | Waits until they have ended, then queues it however they ended. |
| `--retries <n>` | Runs it again, up to `n` times, when it exits nonzero, is ended by a signal it was not sent by `kill`, or passes its deadline. Default 0. |
| `--retry-delay <t>` | Waits `t` before each retry. Default: none. |

**Accounting.** `history` and `stats` read `events.jsonl` directly, a line at a time, so they answer
with no daemon running and change nothing. Lines that are not events are skipped and counted on
standard error.

| Option | Meaning |
| --- | --- |
| `--kind <k>` | Only jobs of this kind. |
| `--since <t>` | Only jobs that ended in the last `t` (`90m`, `2h`, `3d`, `1w`; `s` too) or since a date in UTC (`2026-11-07`, `2026-11-07T14:30`). |
| `--json` | One JSON object on one line. |
| `--failed` | `history` only: jobs that did not exit 0, whatever the cause. |
| `--limit <n>` | `history` only: at most `n` jobs. Default 20. |

`history` has the columns ID, KIND (`*` marks a landing job), OUTCOME (`ok`, `failed`, `signal`,
`killed`, `timeout`, `cancelled`, `lost`), EXIT (the status `wait` exits with), DURATION and ENDED
(UTC). `stats` has one row per kind (a kind's landing runs are their own row, `kind+landing`, as for
learning deadlines): COUNT, OK (the share that exited 0), P50, P90 and MAX of the run times,
TIMEOUTS, DEADLINE (what the next job of the kind would get, learned from every successful run in the
log whatever the filters) and PEAK P50 / PEAK MAX of the memory the jobs' process trees held, `-`
for jobs whose events do not say. Percentiles are nearest-rank, so they are always a run that
happened.

```
$ marshal history --failed --since 1d --limit 5
$ marshal stats --kind test --json
```

`run-type` and `train` take `--dir`, `--deadline`, `--units` and `--mem` too, which override the
type's own, and `--submit`, which prints the job's id instead of waiting. A type's parameters may not
use those names.

A job runs with the caller's environment, plus `MARSHAL_JOB` (its id) and `MARSHAL_HOME`, in a
process group of its own, under `nice -n 15` unless it is a landing job, with its standard output
and error in `~/.marshal/jobs/<id>.log`.

**Exit statuses.** `wait` and `run` exit with the job's own code; 128 + the signal for a job ended by
a signal (143 for `kill`); 124 for a job stopped at its deadline; 143 for a job cancelled before it
started; 125 for a job lost when a daemon died; 126 for a job cancelled because a job it waited for
did not succeed. A type's run exits 0 when it is green, 1 when it is red and 2 when its type or
parameters are wrong. marshal's own failures (a bad command line, an unknown job, no daemon) exit 2.

**Waiting for other jobs, and retries.** A job submitted with `--after` names only jobs that
already exist, so waits never form a cycle. While it waits, `ls` and `top` show it as `after 3,4`,
the jobs it still waits for; once they have ended it joins the queue (the event `ready`): at the
back of the urgent band for a job submitted with `--urgent`, otherwise behind the jobs of its
priority. A job that waits may be held with `hold`, which it keeps when it joins the queue, so it
starts only once it is released; "held" always means held by hand. A paused job has not ended, so
the jobs waiting for it go on waiting. A retried job keeps its id: each attempt is recorded in the
event log (an attempt that runs again ends with `"retrying":true`, then `retry`), its output is
appended to the same log after a `marshal: attempt 2 of 3` line, each attempt has the whole
deadline, and `wait` (and `wait --until job=<id>`) answers with the last attempt's status. A job
waiting out its retry delay shows as `retry 2`; a retry of an urgent job joins the back of the
urgent band again. `kill` cancels a waiting job or one waiting to retry, and a killed job is never
retried. All of it survives `marshal restart`.

```
$ a=$(marshal submit -- make)
$ b=$(marshal submit --after $a --retries 2 -- make test)
$ marshal wait $b
$ marshal rerun $b
```


## Waking on events

A program that wants to resume when something happens runs one blocking command, in the
background, and is resumed when it exits. Nothing polls: the daemon answers from the message that
ends a job.

```
$ marshal wait --until idle
$ marshal wait --until job=14,15
$ marshal wait --until ended:kind=gate,outcome=failed --timeout 30m
$ marshal events --follow failed
```

| Condition | Met when |
| --- | --- |
| `idle` | nothing is running, queued, waiting for other jobs or waiting to retry; at once if that is already so |
| `job=<id>[,<id>...]` | every one of those jobs has ended, its last attempt included; at once if all have |
| `ended` | a job ended, however (an attempt that is retried too) |
| `failed` | a job ended any way but `ok` |
| `landing-done` | a landing-lane job ended |
| `started`, `submitted` | a job started, or was submitted |
| `ready` | a job that waited for others (`--after`) joined the queue |
| `retry` | a job that failed is to run again (`--retries`) |
| `held`, `released` | a job was held, or released, by hand |
| `paused`, `resumed` | a running job was paused, or resumed |
| `prioritized` | a queued job was given a priority |

Every condition but `idle` and `job=` takes filters after a colon, joined by commas: `kind=<k>`, and
for `ended`, `failed`, `landing-done` and `any` `outcome=<ok|failed|timeout|killed|cancelled|lost>`, as in
`ended:kind=avin-gate,outcome=failed`. The outcome of a job that exited 0 is `ok`; of one that exited
any other way or was ended by a signal, `failed`.

`wait --until` prints the event that met the condition as one JSON line (the line the event log
holds; for `idle`, `{"ts":...,"event":"idle","running":0,"queued":0}`; for `job=`, the ending event of
the job that ended last) and exits 0. It exits 124 when `--timeout` (minutes, or `90s`, `30m`, `2h`)
comes first, 2 for a condition that is not one or names no job, and 1 when no daemon can be reached.
A wait for an event sees events that happen after it asks, unless `--since` looks back: a job id
(that job's events and later ones), a time ago (`90s`, `10m`, `2h`, `1d`) or `@<milliseconds since
1970>`. No event is missed between asking and the daemon's registering the wait: the daemon looks at the
log and registers on its own thread. A wait goes on across `marshal restart`: the command connects
again and asks again, and the daemon looks for what happened while it handed over.

`events` prints the logged events the filter lets through (all of them without one) and exits;
with `--follow` it goes on, printing each as it is logged, until killed. A reader that falls behind
is dropped, never waited for: its stream ends with the line `{"ok":false,"error":"events were
dropped: ..."}` (on standard error, with exit 1, from the command), and `--since` sees what it
missed. The protocol is in `docs/protocol.md`.

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
  120 for a landing job. A job past its deadline has its busiest process sampled (where the system
  has `sample`, 5 seconds, to `jobs/<id>.sample.txt`), then its group gets TERM and, 5 seconds later,
  KILL.
- **Events.** `events.jsonl` records every job's `submitted`, `ready` (a job that waited for others
  joining the queue), `held`, `released`, `prioritized`, `started`, `paused`, `resumed`, `retry` and
  ending (`finished`, `timeout`, `killed`, `cancelled`, `lost`), each with the time, the job, and its
  durations and exit status.
  Deadlines are learned from it, and a daemon that starts after one died records the jobs that
  were left open as `lost`.
- **Pausing a job.** `marshal pause <id>` sends STOP to a running job's whole process group and
  `marshal resume <id>` sends CONT. A paused job keeps its units and memory, since its processes
  still hold their memory, and its deadline's clock stops: its ELAPSED and the time left before its
  deadline count only the time it ran. `ls` and `top` show it as `paused`, and it stays paused, its
  clock stopped, across `marshal restart`. `kill` of a paused job, and `stop --force`, continue it
  before the TERM, so it can act on it; `stop --wait` is refused while a job is paused.
- **Holding and ordering the queue.** `marshal pause` holds the whole queue: running jobs go on,
  and nothing new starts in either lane, landing jobs included, until `marshal resume`. `marshal
  hold <id>` keeps one queued job from starting; it keeps its place and the jobs behind it start as
  if it were not there, until `marshal release <id>`. `marshal priority <id> <n>` places a queued
  job in its lane's queue: higher priorities first, every job starting at 0, equal ones by arrival.
  Each lane's queue begins with its **urgent band**: `submit --urgent` (or `run --urgent`) queues a
  job there, and `priority <id> --urgent` moves a queued one there. The band goes ahead of every job
  not urgent, whatever its priority, and is first come, first served: a job joins it at the back,
  behind every urgent job already queued, held ones included. A number given to an urgent job takes
  it out of the band. A development job never passes the landing lane this way: landing jobs have a
  queue of their own, which always goes first, with its own urgent band. Priority orders marshal's
  own jobs; take-slot's waiters keep their places by arrival. `ls` shows a held job as `held`, and
  `status` and `top` say when the queue is held. A held queue, held jobs, priorities and the urgent
  band survive `marshal restart`. `kill` cancels a held job like any queued one.
- **Stopping.** `marshal stop` or a TERM signal ends the daemon. TERM, like `stop --force`, kills
  what runs and cancels what waits. `stop --wait` is refused while the queue or a queued job is
  held, since what waits would never end.
- **Restarting.** `marshal restart` upgrades the daemon without stopping anything: after `brew
  upgrade marshal`, it makes the running daemon the program now installed at its own path. The
  daemon writes its jobs, queue and take-slot ticket to `state.json` in marshal's home and replaces
  its program in place, so it keeps its process, and its jobs stay its children; the new program
  reads the file and carries on. A running job keeps running and is answered with its own exit
  status, its deadline keeps counting from when it started, a job being killed is still killed,
  and the queue starts in the same order. A command whose connection closes during the restart
  (a `wait`, say) connects again for up to 30 seconds and asks again, so it never notices. When
  the new program cannot run, the daemon goes on as it was, and `restart` says why and exits 2.
  `restart` prints the version before and after; `version` prints this marshal's and the
  daemon's, and neither starts a daemon.

`config.json` in marshal's home changes the defaults: `units`, `memory` (`"56G"` or bytes),
`reserve`, `deadline_floor` (`"5m"`), `learn_window`, `learn_min_runs` and `take_slot` (below).

`marshal status --json` prints `units`, `unit_budget`, `mem`, `mem_budget`, `rss` (what the
running jobs hold in RAM, in bytes), `machine_mem` (the machine's memory, 0 if unknown), `landing` (the landing
job's id or null), `take_slot` (`dir`, `units`, `waiting`, `landing`, or null when none is shared),
`queue_held`, and `running` and `queued`, arrays of jobs as [the protocol](docs/protocol.md) writes
them.

## Sharing the machine with take-slot.zsh

marshal can share one unit budget and one landing lane with `take-slot.zsh`, a lock-directory script
some projects use for the same purpose, through take-slot's own lock directory and with no change to
take-slot. It is off unless configured: `take_slot` in `config.json` names the directory, and
`$MARSHAL_TAKE_SLOT_DIR` overrides it (empty for none).

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
directory every 3 seconds; take-slot itself looks every 10 (20 for a landing). Keep take-slot's
`SLOT_BUDGET` and marshal's `units` equal (12 both by default): each side measures the other's use
against its own budget. `marshal status` shows what take-slot holds.

## marshal top

`marshal top` is a live view of the daemon for people, drawn in the terminal with
[tui](https://github.com/avin-lang/tui) and asked of the daemon once a second over its socket (the
`snapshot` request).

- **Header**: the daemon's uptime, how many jobs run and wait, who holds the landing lane (a job,
  take-slot, or free), `(held)` in red beside the queued count while the queue is held, and the
  filter; a bar of the unit budget, marshal's development units in green
  and take-slot's share after them in magenta, with take-slot's waiting runs; a bar of the memory
  budget the running jobs reserve, then what they hold in RAM (`rss`) and the machine's memory.
- **Memory**: RESV is the memory a job declared with `--mem`. RSS is what a running job's whole
  process tree holds in RAM, measured by the daemon every second, and PEAK the most it was measured
  holding, kept once it ends; `-` where there is none.
- **Started**: STARTED is when the job started, in the terminal's local time zone (`TZ`, else the
  system's) to the minute, as `MM-DD hh:mm` (`11-07 08:31`); `-` for a job that has not started.
  `marshal ls` has the same column. Under 90 columns `top` leaves PEAK out and shows just `hh:mm` for
  a job that started today, so STARTED and the rest keep their room; `--json` carries `started_at` and the peak as before.
- **Jobs**: running jobs, then queued ones, then the last ten that ended, the latest first. ELAPSED
  counts on between snapshots; DEADLINE is a running job's time left, yellow under a quarter of its
  deadline or five minutes and red under a tenth or one minute, and a queued job's deadline to come.
  A queued job's STATE is its place in its lane's queue and why it waits: `no units`, `no memory`,
  `lane busy` (another landing job holds the lane), `take-slot` (what take-slot.zsh holds or a
  take-slot run ahead of it), `behind N`, when it would fit but would delay job N at the head of
  the queue, `held` (`marshal hold`) or `queue held` (`marshal pause`). A job waiting for others
  shows `after 3,4`, one waiting to retry `retry 2`. An ended job shows `exit N` (green for 0, red
  otherwise), `killed`, `timeout`, `lost`, `cancelled`, `dep N failed` or `signal N`.
- **Keys**: Up, Down, PgUp, PgDn, Home, End select a job; Enter or `l` opens its log in a pane under
  the table, following the end as it grows (PgUp, PgDn, Home, End scroll it while it is open, Esc
  closes it); `k` kills the selected job after `y`; `f` shows all jobs, the running, the queued or
  the ended ones; `h` the keys; `q` quits.
- **No daemon**: top does not start one by itself. It says there is none, looks again every second,
  and `s` starts one. A daemon older than the `snapshot` request is named as such.

The protocol between the command line and the daemon, and the step protocol, are in
[docs/protocol.md](docs/protocol.md); the `.job` file in [docs/jobs.md](docs/jobs.md); the choices
behind the design in [docs/decisions.md](docs/decisions.md).

## Building and testing

```
avin build . -o marshal
scripts/test.sh
```

marshal depends on [tui](https://github.com/avin-lang/tui), fetched at the commit `avin.hocon` pins,
and needs an Avin with `process.exec` and `process.waitPid`.

`scripts/test.sh` builds marshal and runs the unit tests (scheduler, deadlines, protocol, event log,
settings, take-slot's format, top's screen and keys, the state a restart hands over, `.job` files,
the step protocol, transitions and bisection) and the end-to-end tests, among them `top` under
`script` in a pseudo-terminal, and the train against throwaway git repositories. The end-to-end tests
start real daemons in temporary homes, each with a take-slot directory of its own, and run the real
`take-slot.zsh` against it (`$TAKE_SLOT` names the script). `$AVIN` names the compiler, which also
compiles marshal's own steps from `stock/` (`$MARSHAL_STOCK`). The restart tests point the daemon at
another program with `$MARSHAL_RESTART_PROGRAM`, and stand in for a newer marshal with
`$MARSHAL_TEST_VERSION`, the version the daemon then reports.
