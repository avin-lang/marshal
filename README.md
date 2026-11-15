# marshal

marshal runs the heavy commands of building, testing, benchmarking and releasing on one machine
without them fighting over it. Each command is a **job** with a weight in **units** (about a core
each) and an amount of **memory**; one daemon per user starts jobs while they fit a budget (12 units
and the machine's memory less 8G by default), keeps the rest in a first-come queue, gives the
**landing lane** to the one job everyone is waiting for, and stops any job that runs far past how
long its command normally takes. It **learns** each command's cores, memory and duration from its
runs, so most jobs need no sizing at all.

Work that takes several steps (merge some branches, build, test, land them, clean up) is written
as a **job type**: a small data file naming the steps, which marshal runs as one job. marshal ships
one type, **train**, which gates a batch of git branches together and lands them; your project can
add its own. marshal is written in [Avin](https://github.com/avin-lang/avin).

## Quick start for agents

Every heavy build, test or benchmark goes through marshal, under `caffeinate -dimsu` so the machine
does not sleep under it:

```
caffeinate -dimsu marshal run --dir ~/dev/proj --label "proj fix-x: parser tests" -- make test > ~/scratch/test.log 2>&1
```

- `--dir` is where the command runs (default: the current directory). Give it explicitly: an agent's
  shell may not be where it thinks.
- `--label` says whose job it is and what it is (1 to 80 characters, one line). `ls`, `top` and
  `history` show it; it is how another session knows the job is yours.
- Leave out `--units`, `--mem` and `--deadline`: marshal learns them from the command's earlier
  runs. See [Which options do I need?](#which-options-do-i-need) for when to give them.
- After `--` comes the command, word for word; nothing after `--` is an option.

**Waiting for it.** `marshal run` itself waits: it prints `marshal: job 4384: log
/Users/me/.marshal/jobs/4384.log` first, then, when the job ends, one result line, and exits with the
job's own status. So run it **in the background** with its output redirected, and let its exit be
the one notification; do not poll. An AI agent ends its turn after starting it: every poll (`marshal
ls`, `tail`, `sleep` loops, even `echo`) re-sends its whole context and learns nothing.

```
marshal: job 4384: log /Users/me/.marshal/jobs/4384.log
marshal: job 4384 exited 1 after 8.7s; log /Users/me/.marshal/jobs/4384.log
```

Where the job was queued with `marshal submit` (which prints just its id) instead, wait with one
`marshal wait <id>`: it prints the same result line and exits with the same status. `marshal wait
--until job=3,4` waits for several. Killing a `marshal run` or `marshal wait` does **not** stop the
job: it belongs to the daemon. Stop a job with `marshal kill <id>`.

**Reading the result.** The job's whole output is in `~/.marshal/jobs/<id>.log` (the first line
`run` prints names it). A log can be megabytes; read it by pattern, never whole:

```
marshal grep 4384 "FAIL|error|passed|failed" -n -m 40
marshal grep 4384 "error" -C 3 --last 500
marshal tail 4384 -n 30
```

`grep` and `tail` read the file directly, on a running or an ended job, with no daemon needed.
`grep` exits 0 when a line matched, 1 when none did, 2 on an error.

**The exit status** is the job's own; 124 means it was stopped at its deadline (or quiet timeout),
128 + N a signal (143 for `kill`), 143 cancelled before it started, 125 lost when a daemon died, 126
cancelled because a job it waited for failed, and 2 is also marshal's own failure (a bad command
line, an unknown job): the result line says which. See [Exit statuses](#exit-statuses).

**Seeing the machine.** `marshal ls` lists the jobs and why each queued one waits; `marshal status`
is one line of the budget in use; `marshal top` is the live view, for people.

## Which options do I need?

| Situation | Options | Why |
| --- | --- | --- |
| An ordinary build or test | none beyond `--dir` and `--label` | Units, memory and deadline are learned from the same command's recent runs (see [How marshal learns](#how-marshal-learns)). |
| A heavy command marshal has never run (a new gate script, a new compiler suite) | `--mem 34G` for its first run; `--units <n>` only if far from the default | Until it has run once it reserves no memory, and weighs 4 units for a `test` and 1 otherwise. After one run its memory is learned; leave `--mem` out from then on. |
| You know the parallelism and want it kept | `--units <n>` | A given `--units` is a **ceiling**: once the command has 3 measured runs, the job weighs the fewer of what you gave and what the runs used (`8→~1.5` in UNITS). |
| The job truly needs exactly n cores whatever it was measured using | `--units <n> --units-exact` | Keeps n even where runs used fewer. Refused without `--units`. |
| A short check: one package's tests, a lint, a probe | `--quick` | Starts at once in the quick lane (2 slots), outside the unit budget, rather than queueing behind long builds. Its deadline is at most 2 minutes. |
| The gate of a merge train: the one run everyone is waiting on | `--landing` (or `marshal train`, which uses the landing lane itself) | Starts before every development job; drains the machine until its memory fits. One at a time. |
| A release's critical path | `--urgent` | Joins the urgent band, ahead of every job not urgent, and runs un-niced. Not for ordinary work: it delays everyone else. |
| A benchmark or any timing run | `--exclusive --quiet-load auto` | Owns the machine: waits for the running jobs to end and the outside load to settle, and nothing else starts while it runs. Never `marshal pause` the queue for a benchmark. See [Benchmarks](#benchmarks). |
| Work that must not overlap another job (two runs in one worktree, build then test) | `--after <id>` (`--after-any <id>` to run however it ended) | Waits until those jobs have ended; `--after`/`--after-ok` cancels it (exit 126) if one failed. |
| A run that can hang | `--deadline <t>` a little above its known time, or `--quiet-timeout <t>` | The learned deadline already exists after 3 runs; give one for a new command, or `--quiet-timeout` to stop a run whose log goes silent. |
| A flaky step worth retrying | `--retries <n> [--retry-delay <t>]` | Reruns it on a nonzero exit, a signal or a deadline. |
| Work done outside the job's own processes: `docker run`, a VM, `sudo -u` another account | `--external --mem <size>` | marshal cannot measure it; it reserves exactly `--mem` and learns nothing. |
| A job submitted on another session's behalf | `--owner <name>` | Otherwise the owner is the project its `--dir` is in, or its label. |
| A queued job should go sooner or later | `marshal priority <id> <n>` (higher first) or `marshal priority <id> --urgent` | Orders marshal's own queue; a held job (`marshal hold`) keeps its place. |
| You are working at the machine | `marshal polite` (or config.json's `polite_schedule`) | Admits jobs against three quarters of the budget; `marshal polite off` gives it all back. |

**Units, in short.** A unit is about a core. Leave `--units` out: a command's weight is learned from
the cores its runs held (see [How marshal learns](#how-marshal-learns)), shown with `~` in UNITS
(`~2.25`). Where a given `--units` is far from what recent runs used (2 units or more apart, and
twice or half), `run` and `submit` say so on stderr — `marshal: declared 4 units; recent runs used
about 1.2` — and that is the value to give, or to leave out. A job held under what it gave says so
too: `marshal: units 1.5, learned (asked 8); --units-exact keeps 8`.

**Memory, in short.** Memory is learned per command (`sysl test compiler`, `zsh /path/gate.zsh`), not
per kind. Keep the names of recurring scripts stable (`gate.zsh`, not `gate4.zsh`): the script's
path is what its memory, cores and duration are learned under. Do not give `--mem` to work marshal
already knows: a learned reservation follows the work up and down, while a given one stays wrong
once the work changes.

**Deadlines, in short.** After 3 successful runs a command's deadline is learned (twice the median,
or 1.5 times the longest, at least 5 minutes). Before that it is 20 minutes for a build, 45 for a
test, 30 for anything else and 120 for a landing job — so a new command known to take longer needs
`--deadline`. Time queued never counts against it.

### Benchmarks

`--exclusive` makes a job own the machine: it starts only once no other marshal job runs in any
lane, never pauses or kills one, and while it runs nothing else starts. `--quiet-load auto` also
waits until the 1-minute load average has stayed below a quarter of the processors (4.5 on an
18-core Mac) for a whole minute, so work outside marshal has calmed down. Prefer `auto` to a small
fixed number: a desktop's background apps keep the load near 2–3 indefinitely.

```
caffeinate -dimsu marshal run --exclusive --quiet-load auto --dir ~/dev/proj --label "proj: bench" --deadline 30m -- make bench
```

While it waits it moves through these states in `ls`:

- `queued (emptying)`: marshal's own jobs still run. From the moment it queues it reserves the
  machine, whatever the load: no job queued after it starts (they say `queued (exclusive N)`), so
  the running jobs end and marshal empties. The load is not shown yet; much of it is marshal's own.
- `settling (load 7.9 ≥ 4.5)` / `settling (load 3.5 < 4.5 for 20.0s)`: nothing of marshal's runs,
  and it holds the machine waiting for the **outside** load alone. ELAPSED is how long it has waited
  for the load, not run time.
- `settling (…, overdue)`, red in `top`: it has waited past `load_wait` (15 minutes). Its log names
  the busiest processes outside marshal; it still waits. Quiet the machine, or kill it.

Its log begins with `marshal exclusive: load 1.52 1.4 1.31; busiest outside marshal: WindowServer
412 12.3%, …`, and gets another such line every 30 s, so a result can say whether anything disturbed
it. A landing job queued before the benchmark starts still goes first.

## Common mistakes

- **Running heavy work bare.** A build or test outside marshal competes for cores with the jobs
  marshal has admitted, while marshal's queue waits for units the bare run is using. Everything
  heavy goes through `marshal run`. The one exception is a fix to marshal itself, which runs bare
  as `caffeinate -dimsu nice <command>` so a broken marshal cannot block its own fix.
- **Passing `--units 12` (or any big number) "to be safe".** Until the command has 3 measured runs,
  a 12-unit job waits for the whole budget to empty and then blocks everyone. Leave `--units` out;
  for a benchmark use `--exclusive`, not `--units 12`.
- **Polling a job.** A loop over `marshal ls`, `marshal tail`, `sleep` or the log size spends an
  agent's context and learns nothing. Wait once: on `marshal run` itself in the background, on
  `marshal wait <id>`, or on the run's PID with one loop that exits. A redirected log may stay empty
  for the whole run, so never wait on its size.
- **Pausing marshal to benchmark.** `marshal pause` holds every session's queue and stops nothing
  already running or outside marshal. `--exclusive --quiet-load auto` empties the machine for the
  benchmark and gives it back after.
- **Killing another session's job.** Read the owner and label in `marshal ls` and ask its owner. Kill
  only a job you started.
- **Killing the `marshal run` client to stop a job.** The job goes on; use `marshal kill <id>`.
- **Reading a whole log.** Use `marshal grep <id> <pattern>` and `marshal tail <id> -n 30`.
- **Using `--urgent` or `--landing` for ordinary work.** They are for a release's critical path and a
  train's gate; anything else in those lanes delays everyone.
- **Renaming a recurring script each time** (`gate2.zsh`, `gate3.zsh`). Each new name starts with
  nothing learned: no memory reservation, the default units and deadline.
- **Giving a stale `--mem`.** A given value never follows the work; a learned one does.

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
shows what runs and waits, live. Its header gives the daemon's version after the name (`marshal 0.3.9`);
when the top you are running is another version it adds it in yellow with a hint,
`marshal 0.3.9 (top 0.3.8, restart top)`, and `marshal ?` stands for a daemon too old to say.

## Reading the queue

`marshal ls` lists the running and queued jobs and the recently ended ones, with the columns ID,
STATE, KIND, UNITS, USED, RESV, STARTED, ELAPSED, ETA, OWNER, LABEL and COMMAND. KIND is marked
`*` for a landing job, `^` a quick one, `#` an exclusive one, then `!` an urgent one (`test^!`).
A queued job's STATE says why it waits, as `queued (<reason>)`; `top` shows the same reason after
the job's place in its lane (`#2 no units`), in a few words shortened as noted.

| State | Meaning | What to do |
| --- | --- | --- |
| `queued (no units)` / `queued (no memory)` | the budget is full | wait; ask for fewer `--units` or a smaller `--mem` only if the job truly needs less |
| `queued (behind N)` | it would fit, but would delay job N at the head of the queue | wait |
| `queued (draining)` | it has waited past `drain_after` (or is a landing job whose memory does not fit): nothing else starts until it has | wait |
| `queued (draining for N)` | the machine is emptying so job N can start | wait; it is bounded by `drain_after` |
| `queued (lane busy)` | another landing job holds the landing lane | wait |
| `queued (take-slot)` | take-slot.zsh holds the units, or a take-slot run waits ahead of it | wait |
| `queued (quick lane full)` (`top`: `quick full`) | both quick slots are taken | wait; it goes ahead of development jobs |
| `queued (starting)` | the daemon is starting it now | nothing |
| `held` | someone ran `marshal hold <id>` | `marshal release <id>`, if it is yours |
| `queued (queue held)` | someone ran `marshal pause` with no id | `marshal resume`, if the hold is yours |
| `queued (disk low: 14G free)` (`top`: `disk low`) | free disk is under `disk_min` | free disk space; nothing new starts in any lane until then |
| `queued (emptying)` | an exclusive job waits for the running jobs to end; nothing queued after it starts meanwhile, whatever its `--quiet-load` | wait |
| `queued (exclusive N)` | exclusive job N runs, or waits ahead of this one | wait; the job is not stuck |
| `settling (load 7.9 ≥ 4)`, `settling (load 3.5 < 4 for 20.0s)` | an exclusive job has the machine (nothing of marshal's runs) and waits for the outside load alone | wait, or quiet the machine |
| `settling (…, overdue)`, red in `top` | it has waited past `load_wait` and still waits | find the busy process its log names and stop it, or kill the job |
| `queued (polite budget)` (`top`: `polite`) | marshal is polite and the polite part of the budget is full | wait, or `marshal polite off` if the machine is free |
| `queued (polite: runs alone)` (`top`: `runs alone`) | marshal is polite and the job is bigger than the polite budget: it waits for marshal to empty, then runs by itself | wait |
| `queued (polite: N runs alone)` (`top`: `alone N`) | job N runs alone, or waits to, ahead of it | wait |
| `after 3,4` | it waits for jobs 3 and 4 to end (`--after`) | wait |
| `retry 2` | it failed and waits out its retry delay before attempt 2 | wait |
| `paused` | someone ran `marshal pause <id>` | `marshal resume <id>`, if it is yours |

An ended job shows `exit N`, `killed`, `timeout`, `quiet`, `lost`, `cancelled`, `dep N failed` or
`signal N`.

The other columns: UNITS is what a job weighs (`~` before learned ones, `8→~1.5` for one that gave 8
and weighs what its command's runs teach); USED the cores a running job keeps busy, or an ended job's
peak (`-` where nothing was measured); RESV the memory it reserves (`~29G` learned, `@29G` an
`--external` job's declared, plain a given `--mem`); STARTED the local date and minute; ELAPSED the
run time (a settling job's wait for the load); ETA a running job's expected time left (`~6m`, `<1m`
once past it) or a queued job's expected start (`in ~3m`), `-` where not known; OWNER who the job is
for.

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
marshal polite [<fraction> | off]          while you work: admit jobs against only a fraction of the budget (default 0.75, or 3/4 and the like); a job bigger than that runs alone; off: the whole budget again. Running jobs go on; config.json's polite_schedule switches it on by the clock
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
(or `marshal help <command>`) describes one command, and both exit 0. A bare `marshal` prints the
same usage to standard error and exits 2. After `--` nothing is an option, so `marshal run -- prog
--help` runs `prog`. `events` takes `-f` for `--follow`.

### Options of submit and run

| Option | Meaning |
| --- | --- |
| `--kind <k>` | What the job is, for learning its deadline. Default: `test` when a word of the command is `test`, otherwise `build`. |
| `--units <n>` | Its weight, a number above 0 in steps of 0.25 (`0.5`, `1.25`, `4`); anything else is refused. Default: the cores recent runs of the same command used, rounded up to a quarter (`~` in UNITS; see [How marshal learns](#how-marshal-learns)), and 4 for a `test`, 1 for anything else until the command has been measured. A given value is a ceiling: once the command has `learn_min_runs` (3) measured runs, the job weighs the fewer of it and what they teach (`8→~1.5` in UNITS, `units_capped` in `status --json`, and a line on stderr). A given value it keeps that is far from what recent runs used gets a one-line hint on stderr. |
| `--units-exact` | With `--units`: weigh exactly the units given, even where the command's runs used fewer. Refused without `--units`. |
| `--mem <size>` | Memory it needs: `29G`, `512M` (powers of 1024). Default: the learned peak of the same command in its directory, or anywhere while it has not run in that directory; 0 until the command has run once. `--mem 0` reserves nothing and learns nothing. |
| `--external` | Its work runs outside its own processes: `docker run`, a VM, or a command run as another account through `sudo` (see [Work outside the job's processes](#work-outside-the-jobs-processes)). It needs `--mem`, and is refused without it; it reserves exactly that and holds it whatever its process tree measures; its measured peak is never learned from, so its command's later jobs are not taught a near-zero peak. `ls` and `top` show its RESV with `@` before it (`@29G`), `status --json` gives `"external": true`, and `rerun` keeps it. A command whose first word (or the first after `sudo`) is `docker` with `run`, `compose`, `build` or `buildx`, or `docker-compose`, submitted without it gets a warning on stderr and is submitted all the same. |
| `--landing` | The landing lane: starts before every development job, outside the unit budget, at normal priority, once its memory fits beside what runs; until then nothing else starts, so the running jobs drain for it. One landing job runs at a time. One whose memory alone exceeds the budget starts when nothing else runs. |
| `--quick` | The quick lane, for a short job such as the tests of a small package: it starts at once, outside the unit budget, rather than queue for units behind long builds. At most 2 quick jobs run at a time; a third waits in the quick lane, ahead of development jobs, and `ls` shows it `queued (quick lane full)`. Its memory still counts: it starts only when its reservation (`--mem`, or its command's learned peak) fits in the budget's free memory, and holds it while it runs, so a development job may wait for it; until then it waits `queued (no memory)` and development jobs leave that memory to it. It is niced like a development job, never passes a landing job (one that drains the machine holds the quick lane too) nor an exclusive one, and its deadline is at most 2 minutes: 2m by default, a shorter `--deadline` kept, a longer one refused. Past it, it is stopped as any job past its deadline (`timeout`). `ls` and `top` mark its kind with `^`, `top` says `quick` for it running and `quick: 1/2` in the header; `status` names the lane while a quick job runs, and `status --json` has `quick` (running) and `quick_slots`, and `"quick":true` on the job. `rerun` keeps it; `run-type` and `train` take `--quick` too (a type's own deadline over the cap gives way to the cap). Not with `--landing`. When a job submitted without `--quick` is of a kind whose recent successful runs took under 2 minutes at p90 (at least 3 runs learned), `submit`, `run` and `run-type` print a one-line hint on stderr suggesting `--quick`; nothing moves the job into the lane but the option. |
| `--exclusive` | The job owns the machine, for a benchmark. It starts only when no other marshal job runs, in any lane (development, quick, landing) and take-slot holds nothing; while it runs, nothing else starts, a landing job included. It never pauses or kills a running job: it waits for them, `queued (emptying)`, behind any job queued ahead of it that still waits (`queued (behind N)`). Every job queued after it waits for it, `queued (exclusive N)`, so no stream of short jobs can keep the machine from emptying — except a landing job: one queued before the exclusive job starts goes first, so a benchmark never holds up a release train. It weighs the whole unit budget (`--units` is ignored), is not niced, and keeps its `--deadline`. Its log begins with a line `marshal exclusive: load 1.52 1.4 1.31; busiest outside marshal: WindowServer 412 12.3%, mds 88 5%` (the load averages, and the 5 busiest processes that are not marshal's or the job's own), and gets another every 30 s, so a result can tell whether anything disturbed it. `ls` and `top` mark its kind with `#`, `top` says `exclusive` for it running, `status` says `exclusive job N owns the machine`, and `status --json` has `exclusive` (the running one's id) and `"exclusive":true` on the job. Two exclusive jobs run one after the other; `rerun` keeps it. Not with `--landing` or `--quick`. |
| `--quiet-load <n>` | With `--exclusive`: also wait, before starting, until the 1-minute load average has stayed below `n` for a whole minute — work outside marshal it cannot stop but can wait out. The load is read every second; a reading at or above `n` starts the minute again. Where the load cannot be read, it does not hold the job. `--quiet-load auto` is a quarter of the processors (`sysctl hw.ncpu`), at least 1: 4.5 on an 18-core Mac, whose desktop alone keeps the load near 2–3. While marshal's own jobs run it reserves the machine as any exclusive job does, whatever the load: it is `queued (emptying)` and nothing queued after it starts, so marshal's own load cannot keep it waiting. Once nothing of marshal's runs and the load still holds it, it is `settling`: it keeps the machine, `ls` shows `settling (load 7.9 ≥ 4)` while the load is at or above `n` and `settling (load 3.5 < 4 for 20.0s)` while the minute runs, with the wait for the load in ELAPSED, `status --json` lists it under `settling` with `"state": "settling"`, `settling_ms` and `load_overdue`, and `status` counts it apart (`0 running, 2 queued, 1 settling`). A settling job is neither running nor queued: no deadline, ETA or learned duration counts its wait. It never starts before the load settles. Past `load_wait` (`config.json`, 15 minutes, counted from when it began settling) it is overdue: `load_overdue` is true, `ls` adds `overdue`, `top` draws its row red, and its log gets one line, `marshal exclusive: overdue: waited 15m00s for the load to fall below 2; the load is 2.13; still waiting`, then the busiest processes outside marshal. It still waits; quiet the machine or kill it. A settling job keeps all of this across `marshal restart`. |
| `--urgent` | Queues it in its lane's urgent band: ahead of every job not urgent, behind the urgent jobs already queued. It runs un-niced, as a landing job does, backfilled or not; it still weighs its learned units, or its kind's default without `--units`. `ls` and `top` mark its kind with `!` (`test!`), after the lane's mark when it has one (`test^!` quick, `test*!` landing); the mark stays while it runs and after it ends, and `priority <id> --urgent` adds it too. |
| `--dir <d>` | Where it runs, relative to the current directory. Default: the current directory. |
| `--deadline <t>` | Stops it after `t`: a number of minutes, or `90s`, `30m`, `2h`. Default: learned from its command's runs, or its kind's (see [Deadlines](#deadlines)). |
| `--quiet-timeout <t>` | Stops it once its log has had no new output for `t`, written as `--deadline` writes one: a hung job ends then rather than at its deadline. It is sampled and stopped as a deadline stops it, but its outcome is `quiet`: `wait` says `killed after 10m00s without output (quiet timeout)`, its log ends with that line, the event is `quiet`, and `ls` and `history` show `quiet`. Time paused does not count, and the quiet clock starts again on `resume` and on `marshal restart`. `status --json` gives it as `quiet_ms`; `rerun` keeps it; `run-type` and `train` take it too. Default: none. |
| `--after <ids>` | Waits until jobs `<ids>` (`3` or `3,4`) have ended; the same as `--after-ok`. |
| `--after-ok <ids>` | Waits until they have ended, then queues it if each exited 0, and otherwise cancels it (`dependency-failed`, exit 126), which cancels in turn what waits for it. |
| `--after-any <ids>` | Waits until they have ended, then queues it however they ended. |
| `--retries <n>` | Runs it again, up to `n` times, when it exits nonzero, is ended by a signal it was not sent by `kill`, or passes its deadline or its quiet timeout. Default 0. |
| `--retry-delay <t>` | Waits `t` before each retry. Default: none. |
| `--label <text>` | A note to find the job by, such as `train 209`: one line of 1 to 80 characters, no control characters (newline, tab), no space at either end; a longer or malformed label is refused, not cut. It shows in `ls`, `history`, `top` (a LABEL column, empty for a job without one; the whole label beside the kind in the log pane) and `status --json`, and is in the events. `rerun` keeps it; `run-type` and `train` take `--label` too. Default: none. |
| `--owner <name>` | Who the job is for, such as the session or project that submits it: one word of 1 to 40 letters, digits, `-`, `_` and `.`. Without it the owner is the project the job's `--dir` is in, under the directory projects live in (`~/dev`, or `config.json`'s `projects`): the first directory under it (`~/dev/nex/src` is `nex`), or, where that is an organisation's directory holding repositories rather than one itself, the repository under it (`~/dev/avin-lang/avin/compiler` is `avin`); a git worktree named `<repo>-<branch>` beside its repository is its repository's (`~/dev/sysl-lang/sysl-fix-x` is `sysl`), and a repository with a dash in its name stays itself (`sysl-bootstrap`). Outside that directory the owner is the job's label, and without one there is none (`-`). It shows in OWNER in `ls` and `top`, whose `o` key shows one owner's jobs, and in `status --json` as `owner`; `rerun` keeps it. |

`run-type` and `train` take `--dir`, `--deadline`, `--units` and `--mem` too, which override the
type's own, `--quiet-timeout`, `--label` and `--quick`, `--units-exact` (the units `--units` or the
type gives, kept exactly; alone it keeps the type's), and `--submit`, which prints the job's id instead of
waiting. A type's parameters may not use those names.

A job runs with the caller's environment, plus `MARSHAL_JOB` (its id) and `MARSHAL_HOME`, in a
process group of its own, under `nice -n 15` unless it is a landing, exclusive or urgent job (one in
the urgent band as it starts, by `--urgent` or `priority --urgent`, whether it starts in its turn or
backfilled ahead of a draining job), which runs un-niced, with its standard output
and error in `~/.marshal/jobs/<id>.log`. When its main process ends, what is left of its process tree
is sent TERM.

### Exit statuses

`wait` and `run` exit with the job's own code; 128 + the signal for a job ended by a signal (143 for
`kill`); 124 for a job stopped at its deadline or its quiet timeout; 143 for a job cancelled before it
started; 125 for a job lost when a daemon died; 126 for a job cancelled because a job it waited for
did not succeed. A type's run exits 0 when it is green, 1 when it is red and 2 when its type or
parameters are wrong. marshal's own failures (a bad command line, an unknown job, no daemon) exit 2;
`wait --until` exits 1 when no daemon can be reached.

### Reading a log: tail and grep

`marshal tail <id>` prints the end of the job's log (`-n <lines>`), and `-f` follows it until the
job ends. `marshal grep <id> <pattern>` searches a job's log without reading all of it into your
context: it prints the matching lines and nothing else. Both read the log file directly, so they work
on a running job and an ended one alike, and need no daemon. The log is read a line at a time, so any
size is fine. The pattern is an avin regular expression, found anywhere in a line.

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

### history and stats

`history` and `stats` read `events.jsonl` directly, a line at a time, so they answer
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

`history` has the columns ID, KIND (marked as in `ls`: `*` a landing job, `^` a quick one, `#` an exclusive one, `!` an urgent one), OUTCOME (`ok`, `failed`, `signal`,
`killed`, `timeout`, `quiet`, `cancelled`, `lost`), EXIT (the status `wait` exits with), DURATION and ENDED
(the end, to the second, in the caller's local time zone like STARTED; `--json` carries `ended_at` as milliseconds). `stats` has one row per kind (a kind's landing runs are their own row, `kind+landing`, as for
learning deadlines): COUNT, OK (the share that exited 0), P50, P90 and MAX of the run times,
TIMEOUTS, DEADLINE (what the next job of the kind would get while its command has too few runs of its
own, learned from every successful run of the kind in the log whatever the filters) and PEAK P50 / PEAK MAX of the memory the jobs' process trees held, `-`
for jobs whose events do not say; both peaks are sized as RESV and PEAK are (`756M`, `9.7G`), and
`--json` keeps raw bytes in `peak_p50` and `peak_max`. The peaks are the kind's across every
directory, though a reservation learns per command and directory. Percentiles are nearest-rank, so they are always a run that
happened.

```
$ marshal history --failed --since 1d --limit 5
$ marshal stats --kind test --json
```

### Waiting for other jobs, and retries

A job submitted with `--after` names only jobs that
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
| `idle` | nothing is running, queued, waiting for other jobs or waiting to retry; at once if that is already so (`wait` only) |
| `job=<id>[,<id>...]` | every one of those jobs has ended, its last attempt included; at once if all have (`wait` only) |
| `ended` | a job ended, however (an attempt that is retried too) |
| `failed` | a job ended any way but `ok` |
| `landing-done` | a landing-lane job ended |
| `started`, `submitted` | a job started, or was submitted |
| `ready` | a job that waited for others (`--after`) joined the queue |
| `retry` | a job that failed is to run again (`--retries`) |
| `held`, `released` | a job was held, or released, by hand |
| `paused`, `resumed` | a running job was paused, or resumed |
| `prioritized` | a queued job was given a priority |
| `any` | any event (`events` only) |

Every condition but `idle` and `job=` takes filters after a colon, joined by commas: `kind=<k>`, and
for `ended`, `failed`, `landing-done` and `any` `outcome=<ok|failed|timeout|quiet|killed|cancelled|lost>`, as in
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

## How marshal schedules

The first command that finds no daemon starts one in the background; it listens on `sock` in
marshal's home, `~/.marshal` or `$MARSHAL_HOME`. A `wait` is answered the moment the job's process
ends: nothing polls.

- **Budget.** Development jobs share 12 units and the machine's memory less 8G. A job starts when
  its units and memory fit beside what runs. The queue is first come, first served; a later job
  may start ahead of a head that does not fit only when it fits now and is expected to end before
  the head could start, so it never delays the head.
- **Lanes.** Each lane has its own queue. The **landing** lane always goes first, outside the unit
  budget, one job at a time; the **quick** lane runs up to 2 short jobs outside the unit budget; the
  **development** lane is everything else. An **exclusive** job stands apart from all three and owns
  the machine while it runs.
- **Bounded waiting.** The urgent band and priorities let later jobs start ahead of earlier ones, so
  a big job could wait for ever while small ones keep taking the units as they free. Once a
  development job has waited `drain_after` (10 minutes by default; `config.json`) since it queued,
  it goes ahead of every other development job, and while it does not fit the machine drains for it.
  The drained job is expected to start once enough running jobs have ended, each counted by its
  learned duration (its command's, else its kind's), or by its
  deadline when nothing is learned. Meanwhile another development
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
- **Holding and ordering the queue.** `marshal pause` holds the whole queue: running jobs go on,
  and nothing new starts in any lane, landing jobs included, until `marshal resume`. `marshal
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
- **Pausing a job.** `marshal pause <id>` sends STOP to a running job's whole process tree (its
  groups and every descendant's, as it is measured) and `marshal resume <id>` sends CONT; `kill`,
  a deadline and the end of a job reach the same tree. A paused job keeps its units and memory, since its processes
  still hold their memory, and its deadline's clock stops: its ELAPSED and the time left before its
  deadline count only the time it ran. `ls` and `top` show it as `paused`, and it stays paused, its
  clock stopped, across `marshal restart`. `kill` of a paused job, and `stop --force`, continue it
  before the TERM, so it can act on it; `stop --wait` is refused while a job is paused.
- **Disk guard.** Every 3 seconds the daemon measures the free space (`df`) of each volume holding
  marshal's home or the directory of a job that runs or waits, and keeps the least. While that is
  under `disk_min` (`config.json`, `"20G"` by default; `"0"` turns the guard off) no new job starts
  in any lane, the landing lane included: the queued ones wait `queued (disk low: 14G free)` (`top`:
  `disk low`), and the running ones go on, since stopping a build halfway frees nothing it has
  written. Nothing is ever killed. Once the space is back the queue moves again by itself. The
  daemon's log says when the guard holds the queue and when it lets go. A measurement that cannot
  be made holds nothing back. `status` ends with `disk 120G free` and, while the guard holds, `the
  disk is under disk_min 20G: nothing new starts`; `status --json` has `disk_free`, `disk_min` and
  `disk_low`, and `top`'s header shows the free space, yellow under twice `disk_min` and red under
  it.
- **Open files.** A daemon launchd starts inherits launchd's soft limit of 256 open files, far under
  a login shell's, and a job inherits the daemon's. So the daemon raises its soft limit when it
  starts, before any job: to the hard limit where that is a number, and to the kernel's
  `kern.maxfilesperproc` where the hard limit is unlimited (`OPEN_MAX`, 10240, where the kernel will
  not say), never above that ceiling, keeping a soft limit that is already higher. A job's
  `ulimit -n` is that limit. `nofile` in `config.json` asks for another, held to the hard limit. The
  daemon's start line names it (`open files 245760`), `status` ends with `open files 245760` and
  `status --json` has `nofile`.
- **The machine's processors.** With each measurement the daemon reads the kernel's processor tick
  counters (the user, system, idle and nice ticks of every processor, which htop and Activity
  Monitor read), so the cores the whole machine kept busy over the last two seconds are its running
  ticks over all its ticks times its processors: every process counts, however short-lived. Beside
  it is the running jobs' share. `status` says `cpu 8.4 (jobs 4.9)`, `status --json` has `cpu` and
  `job_cpu` in cores, and `top` draws them against the unit budget (a unit is about a core).
- **Polite mode, for while you work on the machine.** `marshal polite` makes marshal admit jobs
  against only part of its budget, three quarters by default (`marshal polite 0.5`, `marshal polite
  2/3` for another part; a fraction above 0 and at most 1), so the machine never jams under you;
  `marshal polite off` gives the whole budget back at once. Each prints the state it leaves, such as
  `polite ¾: 9 of 12 units, 42G of 56G memory`. The units are rounded down to a quarter and the
  memory to a mebibyte. Every lane counts against the polite budget: a landing job's units and a
  quick job's are counted beside the development jobs' while they run, and a landing job waits for
  its units to fit as it waits for its memory, draining the machine meanwhile. **A job bigger than
  the polite budget runs alone**, single file: it is neither refused nor starved; it waits until
  nothing else of marshal's runs (`ls`: `queued (polite: runs alone)`), holds back the jobs queued
  behind it so the machine empties (`queued (polite: N runs alone)`), and then runs with its full
  size, nothing starting beside it, not even a quick job. A job that fits the polite budget but not
  beside what runs says `queued (polite budget)`. Turning polite mode on stops nothing: running jobs
  go on whatever their size, and it only governs what starts next. An exclusive job is unchanged.
  `status` and `top` show `polite ¾` beside the budget, the meters drawn against the polite budget of
  the full one (`3.25/9 of 12`), and `status --json` gives `polite` (`fraction`, `units`, `memory`) or
  null. The setting survives `marshal restart`.

  **A schedule.** config.json's `polite_schedule` makes marshal polite by the clock, in local time:

  ```
  "polite_schedule": [{"days": "mon-fri", "from": "08:00", "until": "16:05", "fraction": 0.75}]
  ```

  `days` is days and ranges of them (`mon-fri`, `sat,sun`, `fri-mon`), every day when left out;
  `until` may be `24:00`, and a window whose `until` is before its `from` runs overnight, belonging to
  the day it begins on; `fraction` is 0.75 when left out; where windows overlap the first holds. Inside
  a window `status` says `polite ¾ (schedule until 16:05)`. What you say by hand wins for as long as
  you said it for: a `marshal polite off` inside a window holds until the window ends, a `marshal
  polite 0.5` there changes the fraction until it ends, and after the window marshal is not polite.
  A setting made outside every window holds outside them, and a window that begins later overrides
  it while it lasts. A schedule config.json cannot read keeps the daemon from starting, saying what
  is wrong.
- **Events.** `events.jsonl` records every job's `submitted`, `ready` (a job that waited for others
  joining the queue), `held`, `released`, `prioritized`, `started`, `paused`, `resumed`, `retry` and
  ending (`finished`, `timeout`, `quiet`, `killed`, `cancelled`, `lost`), each with the time, the job, and its
  durations and exit status; an ending event also carries what was measured (`peak_rss`,
  `peak_cores`, `held_cores`, `cpu_ms`). Deadlines are learned from it, and a daemon that starts
  after one died records the jobs that were left open as `lost`.
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

### Work outside the job's processes

Marshal measures a job's own process tree, so work that a job hands to something else is invisible
to it: `docker run` leaves only the docker client in the tree while the container uses the VM's CPU
and memory. Such a job is submitted with `--external --mem <size>`. The same goes for work that must
run as another account, such as a Docker Desktop or a Homebrew owned by another user: it goes through
your own marshal, as `marshal run --external --mem 8G -- sudo -n -u builder -H docker run …`, with a
sudoers rule that lets you run exactly that command as that account and nothing else. Marshal's
socket is yours alone (`~/.marshal/sock` under a home other accounts cannot enter), and it stays so:
an account that could submit to your daemon could make it run commands as you. A second daemon under
the other account is not the answer either: two daemons are two budgets, each admitting jobs as if
the machine were its own, which is the overcommitment marshal exists to prevent.

## How marshal learns

Units, memory, durations and deadlines are all learned per **command signature**: the program, its
subcommand and its target, each as the last part of a path (`sysl test compiler`, `sysl test .`,
`gradlew test`), or a shell and its script's path as written (`zsh /tmp/rel/gate2.zsh`, a leading
`./` left out), with wrappers such as `env`, `nice`, `caffeinate`, `nohup`, `time`, `timeout`,
`sudo`, `exec` and `command` and `NAME=value` settings passed over, and a `zsh -c` as the command it
runs. An interpreter (`python3`, `perl`, `ruby`, `node`, ...) running a script is the interpreter,
the script's path and its first argument, and a program that is itself a script (`./gate.zsh`) its
path and first argument. So a compiler's suite and a small package's suite learn apart, two scripts
of one name in two directories learn apart, and every worktree of a repository shares what a command
(or a script named by a relative path) has learned. A job's `--label` is not part of it: the same
script under another label is the same work. Runs of the command in the job's own directory (`--dir`)
come first once there is one; then its runs anywhere. A kind (`build`, `test`) is never learned from
on its own for memory or units, and a landing job learns apart from development ones.

### Memory

A job without `--mem` reserves the learned peak of what it runs: the most memory (physical
footprint, Activity Monitor's Memory column, of its whole process tree) any of the **last 3**
measured runs of the same command held, whatever their outcome, rounded up to a mebibyte. A command
never run before reserves 0. Because only the last 3 runs count, a reservation follows the work: a
run that peaks higher raises the next reservation at once (and the reservations of jobs still
queued), and once a command needs less, its reservation comes down within 3 runs. `status --json`
says where a reservation came from in `resv_from`: `cmd+dir`, `cmd`, `given` or `none`. A learned
reservation above the whole budget is held to the budget, so the job starts once nothing else holds
memory and runs alone. `--mem 0` opts out. A running job counts as holding its reservation or what
it was last measured holding, whichever is more, so a job that reserved nothing but holds 27G keeps
a 30G one out of a 56G budget. A job submitted with `--external` holds exactly its `--mem`, and its
peak is never learned.

### Units

Units come in quarters (`0.25`, `1.5`, `4`): the budget's 12 units are 48 quarters, and the
scheduler adds whole quarters, so fractional jobs fill the budget exactly. Each second, with the
memory, the daemon lists the machine's processes (one `ps` for all jobs) and asks the kernel
(`proc_pid_rusage`) the processor time of every process in a running job's tree, its own and that of
the children it has reaped: the processes of its own process groups, every descendant of them by
parent pid, and the groups those descendants lead, so a program that starts its children in process
groups of their own (a test runner that ends a test's whole group when it overruns) is measured with
them. A group the tree was found in stays the job's while anyone is in it, so a process whose parent
has ended (a child of process 1 by then) is still the job's. Over an interval the cores a job keeps
busy are the processor time its processes used divided by the time that passed (a process seen
before counts what it used since, its reaped children's included; a new one all it has used; a
process seen and then reaped is not counted again in its parent's). The job's level is the last two
intervals together, so one busy second between quiet ones counts at half, and its peak is the most
that level has been. What it **held** is the level three quarters of its samples were at or below
(the 75th percentile of its levels), so a gate that bursts to 8 cores while it compiles and then
runs lighter for most of its time holds its lighter level. A job's `finished` (or other ending)
event records the peak as `peak_cores`, what it held as `held_cores` and the processor time counted
as `cpu_ms`; a job that ended within its first second was never measured and records none of them.
A process that ends between two samples counts through the process that reaps it, so a shell's or a
build's many programs shorter than a second are measured in full while what reaps them lives; when
the job's own process ends, the time its reaping reports (its own and every descendant's it reaped)
is counted where it is more than the samples found. What is not counted is the time, after the last
sample, of a process whose parent ended before it (process 1 reaps it).

A job that gives no `--units` weighs what the runs of the same command teach: the most of what the
**last 5** measured runs held, rounded up to a quarter, at least 0.25 and at most the budget (a run
recorded before `held_cores` was teaches its peak); a command never measured weighs its kind's
default (4 for a `test`, 1 for anything else). Memory is still learned from peaks: a job over its
share of processors only slows the niced jobs beside it, while one over its memory can take the
machine into swap. A given `--units` is a **ceiling**, and a job type's `units` counts as given:
once the command has at least `learn_min_runs` (3) measured runs, the job weighs the fewer of what it
gave and what those runs teach, so `--units 8` on a command that holds one core weighs about 1 and
leaves the other cores to the queue. `--units-exact` keeps the given units exactly, for work that
needs them whatever it was measured using; with fewer runs, the given units stand as they are. A job
that turns out to use more than it weighs is left alone, and its command's next runs learn the
higher level. An exclusive job still weighs the whole budget, and a quick job its own units outside
it. When a run teaches a new value, the queued and waiting jobs that gave no units, or gave them as a
ceiling, weigh again at once; a running job keeps what it started with. A restart weighs them again
from what the new program reads, and a running job it takes over keeps its measured peak, the levels
it held and the groups its tree was found in, and is measured on from a fresh baseline. An external
job's cores are never learned. `status --json` gives `units` as a number (`1.25`), `units_learned`,
`units_asked` and `units_capped: true` for a job held under what it gave, and `cores`, `peak_cores`,
`held_cores` and `cpu_ms` once measured; the `submitted` event's spec records `units_asked`,
`units_capped` and `units_exact` the same way. `top`'s UNITS shows the same units with `~`, the given
ones and the arrow only where they fit its 5 cells, and its PEAK stays the peak.

### Durations and ETAs

Every run that exits 0 is remembered under its command. A job's expected duration is the median of
the **last 5** such runs of its command in its directory, or anywhere while it has not run there;
before any, its kind's (the median of the kind's last runs once it has 3, half its default deadline
until then); never more than its deadline. The scheduler's backfill and drains read it, whichever it
is, and a command's own runs make them sharper. A queued job estimates again when a run of its
command ends. Only a duration learned from the command's own runs gives an ETA, since a kind's runs
(every test of every project) say little of when one of them ends: a running job's ETA is its
expected duration less the time it has run (`~6m`, `~1h05`, and `<1m` once it is past it). A queued
job's expected start is reckoned from the running jobs' expected ends: the jobs of each lane, in
queue order, each start at the earliest end after which its units and memory fit beside what runs
and what is reckoned to start before it (`in ~3m`, and to the hour from an hour on, `in ~2h`). Where
a start waits on an end that is not known (a running job whose command has no learned duration), or
on what no duration measures (take-slot, the load, an exclusive job, a held queue, a low disk), that
job and every one behind it in its lane have none (`-`); a held job is passed over. `ls` and `top`
show both in ETA; `status --json` gives `duration_from` (`cmd+dir`, `cmd`, `kind` or `none`), a
running job's `eta_ms` and a queued job's `starts_in_ms` (from when the daemon answered), each where
it is known.

### Deadlines

A job's deadline is learned from the last 20 successful runs of its command in its directory, or of
its command anywhere while its directory has fewer than 3, or of its kind (with `+landing` for a
landing job) while its command has fewer than 3: twice their median or 1.5 times the longest of them,
whichever is later, never under 5 minutes. Until any of those has 3 runs it is 20 minutes for a
build, 45 for a test, 30 for anything else and 120 for a landing job. A run its deadline stopped took
at least that long, so until its command next exits 0, the command's deadline is at least 1.5 times
how long that run ran: a repeat is not stopped where it was. `--deadline` overrides all of it. A job
past its deadline has its busiest process sampled (where the system has `sample`, 5 seconds, to
`jobs/<id>.sample.txt`, which the result line names), then its group gets TERM and, 5 seconds later,
KILL. A job with `--quiet-timeout` is stopped the same way once its log's size has not changed for
that long; the daemon looks at the log once a second, so the stop comes up to a second late.

### memory.json

After every job that ends, the daemon writes what it has learned to `memory.json` in marshal's home:
`{"version": 4, "peaks": {...}, "cores": {...}, "durations": {...}}`, each key a kind (`+landing`
for the landing lane), a line feed and a command's signature, with a line feed and a directory
after it for runs in that directory, holding that key's last 20 memory peaks in bytes (`peaks`),
peak cores as numbers (`cores`, such as `1.25`) and run times of successful runs in milliseconds
(`durations`), oldest first. An older file is read: a version 2 file keeps its peaks
and cores and its durations are learned from the event log's successful `finished` events
(`run_ms`); a version 1 file, which has only `peaks`, keeps them and learns the cores (from
`peak_cores`) and the durations so. Before version 4 a script's signature was its name alone
(`zsh gate.zsh`), so one key could mix the runs of several scripts of that name: a file of
version 1, 2 or 3 drops those keys (a shell, an interpreter or a script running a script) and
keeps every other, and the scripts' runs still in the event log are learned again under their
paths; what the event log no longer has of them is gone. Any older file is written again as
version 4 at once. It is written to a temporary file and renamed into place, so a reader sees
the whole of one write, never part. A starting daemon reads it, so what was learned survives
`stop`, `restart`, an upgrade, a reboot and `marshal clean` trimming the event log. When the file
is missing, does not read, or is of another version, the daemon says so on stderr (a missing one
silently), learns again from the event log's ending events (the `cmd`, `dir`, `peak_rss` and
`peak_cores` each records) and writes the file at once. Removing it is safe.

## Marshal's home and config.json

Marshal's files are in `$MARSHAL_HOME`, or `~/.marshal`:

| File | What it holds |
| --- | --- |
| `sock` | the daemon's socket; yours alone |
| `jobs/<id>.log` | a job's standard output and error; `jobs/<id>.sample.txt` the stack sample of a job stopped at its deadline or quiet timeout |
| `events.jsonl` | the event log: one JSON line per event; `history`, `stats`, `rerun` and learning read it |
| `memory.json` | what has been learned (above) |
| `state.json` | the jobs and queue a `restart` hands over |
| `config.json` | the settings (below); optional |
| `daemon.log`, `daemon.pid` | the daemon's own log and process id; the log is where to look when a daemon will not start |
| `runs/`, `steps/`, `typed/` | job types' run directories and compiled steps |

`config.json` changes the defaults; every key is optional, and an unknown key keeps the daemon from
starting, saying which. A change takes effect when the daemon next starts (`marshal restart`).

| Key | Default | Meaning |
| --- | --- | --- |
| `units` | `12` | the development unit budget |
| `memory` | the machine's memory less `reserve` | the memory budget: a size such as `"56G"`, or bytes |
| `reserve` | `"8G"` | what the default memory budget leaves the rest of the machine |
| `deadline_floor` | `"5m"` | the shortest deadline learning may give |
| `learn_window` | `20` | how many recent successful runs deadline learning reads |
| `learn_min_runs` | `3` | how many runs a command (or kind) needs before its deadline is learned, and before a given `--units` becomes a ceiling |
| `drain_after` | `"10m"` | how long a development job waits before the machine drains for it; `"never"` never drains |
| `load_wait` | `"15m"` | how long a settling exclusive job waits for its `--quiet-load` before it is marked overdue (it still waits); `"never"` never marks it |
| `disk_min` | `"20G"` | the least free disk new jobs start beside; `"0"` for no guard |
| `projects` | `~/dev` | the absolute directory projects live in, whose first level names a job's owner |
| `nofile` | the hard limit, or `kern.maxfilesperproc` | the soft limit on open files every job inherits, held to the hard limit |
| `polite_schedule` | none | the windows of the week marshal is polite in (see Polite mode) |
| `take_slot` | none | take-slot.zsh's lock directory, whose budget and landing lane marshal shares; `$MARSHAL_TAKE_SLOT_DIR` overrides it (empty for none) |
| `keep_logs` | `"30d"` | how long an ended job's log and run directory are kept; `"never"` keeps them for ever |
| `keep_jobs` | `1000` | at most this many ended jobs keep their files, the newest; `"never"` for no limit |
| `keep_events` | `"365d"` | how long an ended job's events stay in `events.jsonl` |
| `keep_steps` | `"30d"` | how long a compiled step may go unused before it is removed |

**Retention.** Marshal's home would grow for ever, so the daemon removes old files when it starts
and every hour, and `marshal clean` does it on request. Only a job that has ended for good is ever
touched: never a running, queued, waiting, paused or retrying one. The newest job's events are never
removed, so ids are not reused; `history`, `stats` and `rerun` read what remains, and `rerun` of a
job whose events are gone is refused.

`marshal clean` with no option removes the files of every ended job. `--older-than <t>` limits it
to jobs that ended at least `t` ago, `--keep <n>` leaves the `n` newest ended jobs alone (both: a
job must be old and not among the `n` newest), and `--dry-run` prints what would go and removes
nothing. A removed job leaves `ls`; `wait` and `rerun` still answer for it from the event log.
`clean` also removes run directories no job needs, and compiled steps unused for `--older-than`
(else `keep_steps`). A compiled step's last use is the modification time of its executable, which
every use moves forward. It ends by saying how much it freed (`marshal: freed 1.5M`; with `--dry-run`,
`marshal: would free 1.5M`).

## status --json

`marshal status` prints one line: `units 0/12, memory 0/56G, 0 running, 2 queued, 1 settling,
landing lane free; take-slot holds 0 units, 0 waiting; cpu 1 (jobs 0), disk 156G free, open files
245760`. `marshal status --json` prints one JSON object, for scripts:

- the budget: `units`, `unit_budget` (numbers of units, `1.25` among them), `mem` (what the running
  jobs reserve, declared or learned), `mem_budget`, `rss` (the physical footprint of what the running
  jobs hold, in bytes), `mem_held` (what admission counts them holding: each job's reservation or its
  `rss`, whichever is more), `machine_mem` (the machine's memory, 0 if unknown);
- the lanes: `landing` (the landing job's id or null), `quick` (quick jobs running) and
  `quick_slots`, `exclusive` (the running exclusive job's id or null), `take_slot` (`dir`, `units`,
  `waiting`, `landing`, or null when none is shared), `queue_held`, `polite` (`fraction`, `units`,
  `memory`, or null);
- the machine: `cpu` and `job_cpu` (cores, once measured), `disk_free` (bytes, once measured),
  `disk_min`, `disk_low`, `nofile`;
- the jobs: `running`, `queued` and `settling`, arrays of jobs as [the protocol](docs/protocol.md)
  writes them (with `owner`, `label`, `units_learned`, `resv_from`, `duration_from`, `eta_ms` and
  `starts_in_ms` where there are any).

A queued or settling job also has `why`, the protocol's word for why it has not started: `units`,
`memory`, `lane`, `draining`, `take-slot`, `behind`, `draining-for`, `starting`, `held`,
`queue-held`, `quick-lane`, `emptying`, `load`, `exclusive`, `disk-low`, `polite`, `alone` or
`for-alone`; and beside it the job or value the reason names: `behind` (an id) for `behind`,
`draining_for` for `draining-for`, `exclusive_id` for `exclusive`, `alone_id` for `for-alone`,
`disk_free` for `disk-low`, and `load`, `load_limit` and `calm_ms` for `load`. In `marshal ls` the
same reason follows `queued` in the words of [Reading the queue](#reading-the-queue).

## Job types and trains

### A first train

The train merges branches onto a target branch, as the remote has them, in a worktree of its own;
runs a build command and a test command there; and, when both pass, pushes the merged commit to the
target and tears each branch down. It runs as one job of kind `train` in the landing lane. A
throwaway repository shows the whole of it:

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

### Writing a job type

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
`snapshot` request). It takes no arguments.

- **Header**: the daemon's uptime, how many jobs run and wait, who holds the landing lane (a job,
  take-slot, or free), `(held)` in red beside the queued count while the queue is held, and the
  filter; then three meters drawn as htop draws its own, `units[||||||      5+4/12]`: a `|` in
  each part's colour for every cell it fills, and the numbers inside the brackets, against `]`.
  The unit meter has marshal's development units in green and take-slot's share after them in
  magenta (`5+4/12`: marshal's units, take-slot's, the budget), with take-slot's waiting runs
  after the bracket; the memory meter what the running jobs reserve in cyan and what they hold
  beyond their reservations in blue (`12G/56G`, the reserved total and the budget), then what they
  hold in RAM (`rss`) and the machine's memory; and the processor meter the machine's processor
  use, from the same one-second `ps` sample the jobs are measured from, against the unit budget (a
  unit is about a core): the cores marshal's running jobs keep busy in green and every other
  process's in yellow (`4.9+3.5/12`; `-/12` before the first measurement), then the free disk
  (`disk 31G free`), yellow under twice `disk_min` and red under it, where it says `< 20G: nothing
  starts`. With an owner chosen, `owner: sysl` follows the filter. While marshal is polite the
  header says `polite ¾` (with `until 16:05` while the schedule sets it) and the units and memory
  meters are drawn against the polite budget, of the full one: `3.25/9 of 12`, `12G/42G of 56G`.
- **Cores, ETA and owner**: CORES is the cores a running job keeps busy now, as `ls`'s USED has it
  (`-` for any other). ETA is a running job's expected time left (`~6m`) or a queued job's expected
  start (`in ~3m`, dim), counting on between snapshots, `-` where it is not known (see Durations
  and ETAs). OWNER is who the job is for (`--owner`, its project, or its label; `-` for
  none), up to 10 cells, cut with `…`; it stands before LABEL, and LABEL gives way first on a
  narrow screen.
- **Memory**: RESV is the memory a job reserves: what it declared with `--mem`, or with `~` before
  it (`~29G`) the learned peak of its command (in its directory, or anywhere), or with `@` before it
  (`@29G`) what a job submitted with `--external` declared. RSS is the physical footprint (Activity Monitor's Memory column) of a running job's whole
  process tree, measured by the daemon every second, and PEAK the most it was measured
  holding, kept once it ends; `-` where there is none.
- **Started**: STARTED is when the job started, in the terminal's local time zone (`TZ`, else the
  system's) to the minute, as `MM-DD hh:mm` (`11-07 08:31`); `-` for a job that has not started.
  `marshal ls` has the same column. A narrow screen leaves columns out so that OWNER, LABEL and
  COMMAND keep their room: under 140 columns `top` leaves CORES out, and under 130 PEAK too, and
  shows just `hh:mm` for a job that started today; `ls` and `--json` carry `started_at`, the cores
  and the peak as before.
- **Jobs**: running jobs, then queued ones, then the last ten that ended, the latest first, then the
  earlier ones scrolled back to (see Scrolling back). ELAPSED
  is the time since the job started (a paused job's stands still), `-` for a job that has not started,
  and counts on between snapshots; DEADLINE is a running job's time left, yellow under a quarter of its
  deadline or five minutes and red under a tenth or one minute, and a queued job's deadline to come.
  A queued job's STATE is its place in its lane's queue and why it waits, in yellow (`#2 no units`),
  in the words of [Reading the queue](#reading-the-queue) with five shortened: `quick full`, `disk
  low`, `polite`, `runs alone`, `alone N`. A running quick job shows `quick`, a running exclusive job
  `exclusive`, a settling one `settling`. A job waiting for others shows `after 3,4`, one waiting to
  retry `retry 2`. An ended job shows `exit N` (green for 0, red otherwise), `killed`, `timeout`,
  `quiet`, `lost`, `cancelled`, `dep N failed` or `signal N`.
- **Keys**: Up, Down, PgUp, PgDn, Home, End select a job; Enter or `l` opens its log in a pane under
  the table, following the end as it grows (PgUp, PgDn, Home, End scroll it while it is open, Esc
  closes it); `k` kills the selected job after `y`; `f` shows all jobs, the running, the queued or
  the ended ones; `o` shows only the first owner's jobs (in alphabetical order, among the jobs
  listed and loaded), the next owner's at the next press, and every owner's again after the last,
  with whichever `f` filter is on; `h` or `?` the keys; `s` starts a daemon when there is none; `q`
  or Ctrl-C quits.
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

## Troubleshooting

- **A job sits `queued`.** Read the reason in its STATE (`marshal ls`), and the table in
  [Reading the queue](#reading-the-queue). `no units` and `no memory` are the budget being full;
  `exclusive N`, `emptying` and `draining for N` are bounded waits for another job; `queue held`,
  `held` and `paused` are someone's hand; `disk low` needs disk space freed.
- **A traffic jam: jobs wait while the cores look idle.** Compare `units` and `memory` in `marshal
  status`. If memory is the full one, the queued jobs wait on reservations (RESV in `ls`): a running
  job counts the more of its reservation and what it holds, so one large learned peak can keep
  several small jobs out. If units are full but `cpu` is low, the running jobs weigh more than they
  use; a given `--units` far above use is the usual cause, and the stderr hint says what the runs
  used. A job stuck `behind N` would delay job N at the head of the queue; once N has waited
  `drain_after`, the machine drains for it.
- **A settling benchmark is overdue.** Something outside marshal keeps the load up. Its log names the
  five busiest processes outside marshal (`marshal grep <id> "marshal exclusive"`): stop the one that
  is yours, or ask its owner; else `marshal kill <id>` and resubmit later. Pausing marshal does not
  help: the load is not marshal's.
- **A job ran out of time.** The result line says `timed out after … (deadline …)` and names the
  stack sample (`jobs/<id>.sample.txt`). If the run was healthy but slow, give `--deadline`; the
  command's next deadline is at least 1.5 times how long the stopped run ran anyway.
- **Processes left over after a job.** When a job's main process ends, what is left of its process
  tree (its process groups and every descendant marshal found in them) is sent TERM; `kill` and a
  deadline reach the same tree. A process that left the tree between two samples (one that moved to
  a session of its own, `setsid`, and lost its parent within the same second) is outside it: check
  with `ps -o pid,ppid,pgid,etime,command` and stop only what is provably yours.
- **The daemon was restarted or upgraded.** `marshal restart` keeps every job running, queued, held,
  paused and settling, and `wait`s reconnect by themselves. A daemon that died records the jobs it
  left as `lost` (exit 125); resubmit them with `marshal rerun <id>`.
- **"Too many open files" in a job.** A job's `ulimit -n` is the daemon's soft limit, raised at start
  (`status` ends with `open files N`). Set `nofile` in `config.json` and `marshal restart` for
  another.
- **The daemon will not start.** The command prints the end of `~/.marshal/daemon.log`; an
  unreadable `config.json` (an unknown key, a bad `polite_schedule`) is the usual cause.
- **Which marshal is running?** `marshal version` prints this marshal's version and the daemon's,
  without starting one; `marshal restart` after an upgrade makes the daemon the installed one.

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
