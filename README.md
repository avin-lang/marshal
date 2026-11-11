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
marshal wait <id> | --until <cond> [--timeout <t>] [--since <t>]  waits for the job (--timeout also with an id), prints one result line, exits with its status; or waits for an event (--since only here), prints it, exits 0; 124 on timeout
marshal events [--follow] [--since <t>] [<filter>]  the logged events as JSON lines; --follow goes on streaming them until killed
marshal ls                                 jobs queued, running and recently ended; a queued job's state says why it waits: queued (draining)
marshal kill <id>                          stops the job's whole process tree (a queued or waiting job is cancelled)
marshal rerun <id>                         submits an ended job again: its command, directory, environment, kind, label and resources; prints the new id
marshal clean [--older-than <t>] [--keep <n>] [--dry-run]  removes the logs of ended jobs (never a job that is not over), stale run directories and unused compiled steps; prints what went and the bytes freed; --dry-run only lists them
marshal hold <id>                          keeps a queued job from starting; it keeps its place
marshal release <id>                       lets a held job start again
marshal priority <id> <n> | --urgent       places a queued job in its lane: higher first; --urgent: the back of the urgent band
marshal pause [<id>]                       stops a running job's processes, keeping its units, its deadline's clock stopped; with no id, holds the queue
marshal resume [<id>]                      continues a paused job; with no id, releases the queue
marshal tail <id> [-f] [-n <lines>]        the job's log; -f follows it until the job ends
marshal grep <id> <pattern> [-i] [-v] [-n] [-c] [-F] [-m <n>] [-A|-B|-C <n>] [--last <n>]  the lines of the job's log that match the pattern (a regular expression; -F: literal text), as grep prints them; exits 0 when a line matched, 1 when none did, 2 on an error
marshal status [--json]                    the budget in use; --json: one JSON object with the running and queued jobs
marshal history [options]                  ended jobs from the event log, newest first: id, kind, outcome, exit code, duration, when, label
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

`marshal grep <id> <pattern>` searches a job's log without reading all of it into your context: it
prints the matching lines and nothing else. It reads the log file directly, as `tail` does, so it
works on a running job and an ended one alike, and needs no daemon. The log is read a line at a
time, so any size is fine. The pattern is an avin regular expression, found anywhere in a line.

| Option | Meaning |
| --- | --- |
| `-i` | Upper and lower case are the same (Unicode's simple case mapping). |
| `-F` | The pattern is literal text. |
| `-v` | Print the lines that do not match. |
| `-n` | Put each line's number before it: `N:` for a match, `N-` for a line of context. |
| `-c` | Print only the number of matching lines. |
| `-m <n>` | Stop after `n` matching lines; the context after the last one is still printed. |
| `-A <n>`, `-B <n>`, `-C <n>` | Lines after, before, and around each match; groups that do not touch are parted by `--`. `-A` and `-B` win over `-C`. |
| `--last <n>` | Search only the last `n` lines; `-n` still gives the log's own line numbers. |

Exit codes follow grep: 0 when a line matched, 1 when none did, 2 on an error (an unknown job, no
log, a pattern that is not a regular expression, a bad option, or a line on which the pattern
backtracks past the regex step budget: the search stops at that line, which the message names, and
`-c` prints no count). `--` ends the options, for a pattern
that begins with `-`: `marshal grep 7 -- -v`.

Options of `submit` and `run`:

| Option | Meaning |
| --- | --- |
| `--kind <k>` | What the job is, for learning its deadline. Default: `test` when a word of the command is `test`, otherwise `build`. |
| `--units <n>` | Its weight. Default: 4 for a `test`, 1 for anything else. |
| `--mem <size>` | Memory it needs: `29G`, `512M` (powers of 1024). Default: the learned peak of its kind in its directory, or of its kind while the directory has fewer than two measured runs (see Budget); 0 until two runs of the kind were measured. `--mem 0` reserves nothing and learns nothing. |
| `--external` | Its work runs outside its own processes: `docker run`, a VM, or a command run as another account through `sudo` (see Work outside the job's processes). It needs `--mem`, and is refused without it; it reserves exactly that and holds it whatever its process tree measures; its measured peak is never learned from, so its kind's later jobs are not taught a near-zero peak. `ls` and `top` show its RESV with `@` before it (`@29G`), `status --json` gives `"external": true`, and `rerun` keeps it. A command whose first word (or the first after `sudo`) is `docker` with `run`, `compose`, `build` or `buildx`, or `docker-compose`, submitted without it gets a warning on stderr and is submitted all the same. |
| `--landing` | The landing lane: starts before every development job, outside the unit budget, at normal priority, once its memory fits beside what runs; until then nothing else starts, so the running jobs drain for it. One landing job runs at a time. One whose memory alone exceeds the budget starts when nothing else runs. |
| `--quick` | The quick lane, for a short job such as the tests of a small package: it starts at once, outside the unit budget, rather than queue for units behind long builds. At most 2 quick jobs run at a time; a third waits in the quick lane, ahead of development jobs, and `ls` shows it `queued (quick lane full)`. Its memory still counts: it starts only when its reservation (`--mem`, or its kind's learned peak) fits in the budget's free memory, and holds it while it runs, so a development job may wait for it; until then it waits `queued (no memory)` and development jobs leave that memory to it. It is niced like a development job, never passes a landing job (one that drains the machine holds the quick lane too), and its deadline is at most 2 minutes: 2m by default, a shorter `--deadline` kept, a longer one refused. Past it, it is stopped as any job past its deadline (`timeout`). `ls` and `top` mark its kind with `^`, `top` says `quick` for it running and `quick: 1/2` in the header; `status` names the lane while a quick job runs, and `status --json` has `quick` (running) and `quick_slots`, and `"quick":true` on the job. `rerun` keeps it; `run-type` and `train` take `--quick` too (a type's own deadline over the cap gives way to the cap). Not with `--landing`. When a job submitted without `--quick` is of a kind whose recent successful runs took under 2 minutes at p90 (at least 3 runs learned), `submit`, `run` and `run-type` print a one-line hint on stderr suggesting `--quick`; nothing moves the job into the lane but the option. |
| `--urgent` | Queues it in its lane's urgent band: ahead of every job not urgent, behind the urgent jobs already queued. `ls` and `top` mark its kind with `!` (`test!`), after the lane's mark when it has one (`test^!` quick, `test*!` landing); the mark stays while it runs and after it ends, and `priority <id> --urgent` adds it too. |
| `--dir <d>` | Where it runs, relative to the current directory. Default: the current directory. |
| `--deadline <t>` | Stops it after `t`: a number of minutes, or `90s`, `30m`, `2h`. Default: learned for its kind. |
| `--quiet-timeout <t>` | Stops it once its log has had no new output for `t`, written as `--deadline` writes one: a hung job ends then rather than at its deadline. It is sampled and stopped as a deadline stops it, but its outcome is `quiet`: `wait` says `killed after 10m00s without output (quiet timeout)`, its log ends with that line, the event is `quiet`, and `ls` and `history` show `quiet`. Time paused does not count, and the quiet clock starts again on `resume` and on `marshal restart`. `status --json` gives it as `quiet_ms`; `rerun` keeps it; `run-type` and `train` take it too. Default: none. |
| `--after <ids>` | Waits until jobs `<ids>` (`3` or `3,4`) have ended; the same as `--after-ok`. |
| `--after-ok <ids>` | Waits until they have ended, then queues it if each exited 0, and otherwise cancels it (`dependency-failed`, exit 126), which cancels in turn what waits for it. |
| `--after-any <ids>` | Waits until they have ended, then queues it however they ended. |
| `--retries <n>` | Runs it again, up to `n` times, when it exits nonzero, is ended by a signal it was not sent by `kill`, or passes its deadline or its quiet timeout. Default 0. |
| `--retry-delay <t>` | Waits `t` before each retry. Default: none. |
| `--label <text>` | A note to find the job by, such as `train 209`: one line of 1 to 80 characters, no control characters (newline, tab), no space at either end; a longer or malformed label is refused, not cut. It shows in `ls`, `history`, `top` (a LABEL column, empty for a job without one; the whole label beside the kind in the log pane) and `status --json`, and is in the events. `rerun` keeps it; `run-type` and `train` take `--label` too. Default: none. |

**Accounting.** `history` and `stats` read `events.jsonl` directly, a line at a time, so they answer
with no daemon running and change nothing. Lines that are not events are skipped and counted on
standard error.

| Option | Meaning |
| --- | --- |
| `--kind <k>` | Only jobs of this kind. |
| `--label <text>` | Only jobs whose label contains `text` (case as written). `history` always has a LABEL column, last, empty for a job without a label. |
| `--since <t>` | Only jobs that ended in the last `t` (`90m`, `2h`, `3d`, `1w`; `s` too) or since a date on the caller's local clock (`2026-11-07`, `2026-11-07T14:30`; `TZ`, else the host's zone), or since a date and minute that ends in `Z` or an offset (`2026-11-07T14:30Z`, `2026-11-07T14:30+02:00`), which is taken as that instant. |
| `--json` | One JSON object on one line. |
| `--failed` | `history` only: jobs that did not exit 0, whatever the cause. |
| `--limit <n>` | `history` only: at most `n` jobs. Default 20. |

`history` has the columns ID, KIND (marked as in `ls`: `*` a landing job, `^` a quick one, `!` an urgent one), OUTCOME (`ok`, `failed`, `signal`,
`killed`, `timeout`, `quiet`, `cancelled`, `lost`), EXIT (the status `wait` exits with), DURATION and ENDED
(the end, to the second, in the caller's local time zone like STARTED; `--json` carries `ended_at` as milliseconds). `stats` has one row per kind (a kind's landing runs are their own row, `kind+landing`, as for
learning deadlines): COUNT, OK (the share that exited 0), P50, P90 and MAX of the run times,
TIMEOUTS, DEADLINE (what the next job of the kind would get, learned from every successful run in the
log whatever the filters) and PEAK P50 / PEAK MAX of the memory the jobs' process trees held, `-`
for jobs whose events do not say; both peaks are sized as RESV and PEAK are (`756M`, `9.7G`), and
`--json` keeps raw bytes in `peak_p50` and `peak_max`. The peaks are the kind's across every
directory, though a reservation learns per directory. Percentiles are nearest-rank, so they are always a run that
happened.

```
$ marshal history --failed --since 1d --limit 5
$ marshal stats --kind test --json
```

`run-type` and `train` take `--dir`, `--deadline`, `--units` and `--mem` too, which override the
type's own, `--quiet-timeout`, `--label` and `--quick`, and `--submit`, which prints the job's id instead of
waiting. A type's parameters may not use those names.

A job runs with the caller's environment, plus `MARSHAL_JOB` (its id) and `MARSHAL_HOME`, in a
process group of its own, under `nice -n 15` unless it is a landing job, with its standard output
and error in `~/.marshal/jobs/<id>.log`.

**Exit statuses.** `wait` and `run` exit with the job's own code; 128 + the signal for a job ended by
a signal (143 for `kill`); 124 for a job stopped at its deadline or its quiet timeout; 143 for a job cancelled before it
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
`ended:kind=avin-gate,outcome=failed`. `label=<text>` keeps the jobs whose label contains `text`; it is
written last and takes the rest of the filter, commas included (`ended:kind=test,label=train 209`).
The outcome of a job that exited 0 is `ok`; of one that exited
any other way or was ended by a signal, `failed`.

`wait <id>` also takes `--timeout`, before or after the id: if the job has not ended by then it prints
one line saying so, leaves the job running and exits 124. `--since` is for `--until` only and is
refused with an id.

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
- **Bounded waiting.** The urgent band and priorities let later jobs start ahead of earlier ones, so
  a big job could wait for ever while small ones keep taking the units as they free. Once a
  development job has waited `drain_after` (10 minutes by default; `config.json`) since it queued,
  it goes ahead of every other development job, and while it does not fit the machine drains for it.
  The drained job is expected to start once enough running jobs have ended, each counted by its
  kind's learned duration, or by its deadline when nothing is learned. Meanwhile another development
  job that fits starts (backfills) when it too is expected to end by then, or when it takes only
  units and memory the drained job will leave spare; its log's first line and its `started` event
  say `backfilled ahead of <id>` (`backfilled_ahead_of`). A job that was running before the drain
  began and has run past its estimate is counted by its deadline; one started since (backfilled)
  that runs past its estimate may end at any moment, so once the drain waits on it nothing more
  backfills. `status --json` gives every job's `expected_ms` and `duration_learned`, and the drained
  job's `expected_start_at`. `ls` shows the drained job
  `queued (draining)` and the jobs it holds back `queued (draining for <id>)`. Landing and quick
  jobs go on beside it. Time queued never counts against a job's deadline, which runs from its
  start.
- **Memory reservations.** A job without `--mem` reserves its learned peak: the most memory any of
  the last 10 measured jobs of its kind in its directory (`--dir`) held, whatever their outcome,
  plus a tenth, once two have been measured there. A directory with fewer than two learns from the
  kind's jobs in every directory instead, and with fewer than two of those reserves 0. So a small
  package's `test` suite does not reserve what a compiler's `test` suite peaks at. A landing job of
  a kind learns apart from the development ones. `status --json` says which in `resv_from`. A
  learned reservation above the whole budget is held to the budget, so the job starts once nothing
  else holds memory and runs alone. `--mem 0` opts out. A running job counts as holding its
  reservation or what it was last measured holding, whichever is more, so a job that reserved
  nothing but holds 27G keeps a 30G one out of a 56G budget. A job submitted with `--external`
  holds exactly its `--mem`, and its peak is never learned.
- **Work outside the job's processes.** Marshal measures a job's own process tree, so work that a
  job hands to something else is invisible to it: `docker run` leaves only the docker client in the
  tree while the container uses the VM's CPU and memory. Such a job is submitted with
  `--external --mem <size>`. The same goes for work that must run as another account, such as a
  Docker Desktop or a Homebrew owned by another user: it goes through your own marshal, as
  `marshal run --external --mem 8G -- sudo -n -u builder -H docker run …`, with a sudoers rule that
  lets you run exactly that command as that account and nothing else. Marshal's socket is yours
  alone (`~/.marshal/sock` under a home other accounts cannot enter), and it stays so: an account
  that could submit to your daemon could make it run commands as you. A second daemon under the
  other account is not the answer either: two daemons are two budgets, each admitting jobs as if the
  machine were its own, which is the overcommitment marshal exists to prevent.
- **Deadlines.** A kind's deadline is twice the median of its last 20 successful runs, never under 5
  minutes; until it has 3 runs it is 20 minutes for a build, 45 for a test, 30 for anything else and
  120 for a landing job. A job past its deadline has its busiest process sampled (where the system
  has `sample`, 5 seconds, to `jobs/<id>.sample.txt`), then its group gets TERM and, 5 seconds later,
  KILL. A job with `--quiet-timeout` is stopped the same way once its log's size has not changed
  for that long; the daemon looks at the log once a second, so the stop comes up to a second late.
- **Events.** `events.jsonl` records every job's `submitted`, `ready` (a job that waited for others
  joining the queue), `held`, `released`, `prioritized`, `started`, `paused`, `resumed`, `retry` and
  ending (`finished`, `timeout`, `quiet`, `killed`, `cancelled`, `lost`), each with the time, the job, and its
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
  upgrade marshal`, it makes the running daemon the program the command was run from, which is
  the one now installed, even when the daemon's own file was removed by the upgrade. The
  daemon writes its jobs, queue and take-slot ticket to `state.json` in marshal's home and replaces
  its program in place, so it keeps its process, and its jobs stay its children; the new program
  reads the file and carries on. A running job keeps running and is answered with its own exit
  status, its deadline keeps counting from when it started, its quiet clock starts again, a job
  being killed or stopped at its deadline or quiet timeout is still stopped, with the same outcome,
  and the queue starts in the same order. A command whose connection closes during the restart
  (a `wait`, say) connects again for up to 30 seconds and asks again, so it never notices. When
  the new program is missing or cannot run, the daemon goes on as it was, and `restart` says why and
  exits 2. `$MARSHAL_RESTART_PROGRAM`, in the daemon's environment, names another program.
  `restart` prints the version before and after; `version` prints this marshal's and the
  daemon's, and neither starts a daemon.

`config.json` in marshal's home changes the defaults: `units`, `memory` (`"56G"` or bytes),
`reserve`, `deadline_floor` (`"5m"`), `learn_window`, `learn_min_runs`, `drain_after` (`"10m"`, or
`"never"`: how long a job waits before the machine drains for it) and `take_slot` (below), and the
retention settings (next).

**Retention.** Marshal's home would grow for ever, so the daemon removes old files when it starts
and every hour, and `marshal clean` does it on request. Only a job that has ended for good is ever
touched: never a running, queued, waiting, paused or retrying one. Four settings, each an age such
as `"12h"`, `"30d"` or `"2w"` (or `"never"`), in `config.json`:

- `keep_logs` (`"30d"`): an ended job's log and run directory go this long after it ended;
- `keep_jobs` (1000, or `"never"`): at most this many ended jobs keep their files, the newest;
- `keep_events` (`"365d"`): an ended job's events leave `events.jsonl` this long after it ended
  (the newest job's never do, so ids are not reused). `history`, `stats` and `rerun` read what
  remains; `rerun` of a job whose events are gone is refused;
- `keep_steps` (`"30d"`): a compiled step unused this long is removed.

`marshal clean` with no option removes the files of every ended job. `--older-than <t>` limits it
to jobs that ended at least `t` ago, `--keep <n>` leaves the `n` newest ended jobs alone (both: a
job must be old and not among the `n` newest), and `--dry-run` prints what would go and removes
nothing. A removed job leaves `ls`; `wait` and `rerun` still answer for it from the event log.
`clean` also removes run directories no job needs, and compiled steps unused for `--older-than`
(else `keep_steps`). A compiled step's last use is the modification time of its executable, which
every use moves forward. It ends by saying how much it freed (`marshal: freed 1.5M`; with `--dry-run`,
`marshal: would free 1.5M`).

`marshal status --json` prints `units`, `unit_budget`, `mem` (what the running jobs reserve,
declared or learned), `mem_budget`, `rss` (what the running jobs hold in RAM, in bytes), `mem_held`
(what admission counts them holding: each job's reservation or its `rss`, whichever is more),
`machine_mem` (the machine's memory, 0 if unknown), `landing` (the landing
job's id or null), `take_slot` (`dir`, `units`, `waiting`, `landing`, or null when none is shared),
`queue_held`, and `running` and `queued`, arrays of jobs as [the protocol](docs/protocol.md) writes
them; a queued job also has `why`, the protocol's word for why it has not started (`units`,
`memory`, `lane`, `draining`, `take-slot`, `behind`, `draining-for`, `starting`, `held`,
`queue-held`), and `behind`, the job's id, when `why` is `behind`, or `draining_for` when it is
`draining-for`. In `marshal ls` the same reason follows `queued` in the state cell, in the words
`top` shows: `queued (no units)`, `queued (behind 405)`, `queued (draining for 1567)`,
`queued (queue held)`.
A job held by hand says just `held`.

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
  take-slot's later runs wait behind it as they wait behind each other. While a landing job waits
  for memory, the ticket is the landing job's, ahead of every take-slot waiter, so take-slot admits
  none of them until it has started.
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
  budget, what the running jobs reserve in cyan and what they hold beyond their reservations in
  blue, then the reserved total, what they hold in RAM (`rss`) and the machine's memory.
- **Memory**: RESV is the memory a job reserves: what it declared with `--mem`, or with `~` before
  it (`~29G`) its learned peak (its kind's in its directory, or its kind's), or with `@` before it
  (`@29G`) what a job submitted with `--external` declared. RSS is what a running job's whole
  process tree holds in RAM, measured by the daemon every second, and PEAK the most it was measured
  holding, kept once it ends; `-` where there is none.
- **Started**: STARTED is when the job started, in the terminal's local time zone (`TZ`, else the
  system's) to the minute, as `MM-DD hh:mm` (`11-07 08:31`); `-` for a job that has not started.
  `marshal ls` has the same column. Under 90 columns `top` leaves PEAK out and shows just `hh:mm` for
  a job that started today, so STARTED and the rest keep their room; `--json` carries `started_at` and the peak as before.
- **Jobs**: running jobs, then queued ones, then the last ten that ended, the latest first, then the
  earlier ones scrolled back to (see Scrolling back). ELAPSED
  is the time since the job started (a paused job's stands still), `-` for a job that has not started,
  and counts on between snapshots; DEADLINE is a running job's time left, yellow under a quarter of its
  deadline or five minutes and red under a tenth or one minute, and a queued job's deadline to come.
  A queued job's STATE is its place in its lane's queue and why it waits: `no units`, `no memory`,
  `lane busy` (another landing job holds the lane), `draining` (a landing job whose memory does
  not fit beside the running jobs: nothing else starts until they have freed it; or a job that has
  waited past `drain_after`: no other development job starts until it has, but those that
  backfill), `take-slot` (what take-slot.zsh holds or a
  take-slot run ahead of it), `behind N`, when it would fit but would delay job N at the head of
  the queue, `draining for N` (job N has waited past `drain_after` and goes first), `held` (`marshal hold`), `queue held` (`marshal pause`) or `quick lane full` (a
  `--quick` job, both quick slots taken). A running quick job shows `quick`. A job waiting for others
  shows `after 3,4`, one waiting to retry `retry 2`. An ended job shows `exit N` (green for 0, red
  otherwise), `killed`, `timeout`, `lost`, `cancelled`, `dep N failed` or `signal N`.
- **Keys**: Up, Down, PgUp, PgDn, Home, End select a job; Enter or `l` opens its log in a pane under
  the table, following the end as it grows (PgUp, PgDn, Home, End scroll it while it is open, Esc
  closes it); `k` kills the selected job after `y`; `f` shows all jobs, the running, the queued or
  the ended ones; `h` the keys; `q` quits.
- **Scrolling back**: the snapshot carries only the last ten ended jobs. Down or PgDn on the last
  line loads the next 100 that ended before them from the event log (what `marshal history` reads)
  and selects the first of them; End loads every page and goes to the very oldest job; Home goes
  back to the top. The pages stay while top runs, through every snapshot (a job that drops out of
  the last ten stays in the list), until `f` changes the filter; the running and queued filters
  list no ended jobs and load none. The table draws a scroll bar down its right edge while its lines
  overflow, and the bottom line says which lines show, `jobs 41–60 of 1,234`, with `+` after the
  count while earlier jobs may be there that are not loaded yet.
- **Log pane header**: the pane opens with the job's `kind` and its whole `command` (wrapped to the
  pane, never cut off, which the table has to do), bold labels and dim values, ruled off from the
  log. The header stays put while the log scrolls under it; in a very short pane the command is
  shortened with `…` so the log keeps a row.
- **Idle**: the selected row's highlight hides after 5 seconds without a key, so a glance at
  progress is not a row to read around; `top` starts that way. The selected job is remembered while
  it is hidden. The first Up, Down, PgUp, PgDn, Home, End, Enter or `l` after that only shows the
  highlight again, on the same job; the next key does what it always did. Other keys act at once
  and count as activity. The highlight never hides while a job's log is open, a kill is being
  confirmed or the help is showing.
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
