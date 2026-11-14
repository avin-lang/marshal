# Decisions

Each choice the brief left open, with why, and what else was weighed. All are **settled on the user's
delegation 2026-11-06** (branch `stage1`). Review with the user: the landing lane ignoring both
budgets, and a job's leftover processes being sent TERM when its main process ends.

## The scheduler

- **Backfill: a later job starts ahead of a blocked head only if it fits now AND it is expected to
  end no later than the head could start.** The head's start is found by walking the running jobs
  in order of their expected end and freeing their units and memory until the head fits. A running
  job past its expected end is expected to end now, which stops all backfill behind it.
  Why: the head is never delayed by a job that overtook it, so a test needing 4 units cannot be
  starved by a stream of builds, while idle units are still used. Alternatives: strict FIFO (simple,
  wastes units whenever the head is large); any job that fits (starves large jobs); reserving units
  for the head (equivalent in effect, more state). Only the head is protected: jobs between the head
  and a backfilled one may wait longer than strict FIFO would give them.
- **Expected duration** is the median of the kind's history, or half the default deadline while
  fewer than `learn_min_runs` runs are known, and never more than the job's deadline. Why: the
  deadline is meant as a bound, the median as the typical run.
- **The landing lane holds one job, outside the unit budget, and its memory counts against
  development jobs.** Why: take-slot's `land.lock` is one reserved slot that nothing slows; counting
  its memory makes development jobs wait for it rather than risk swapping it. (It was first outside
  the memory budget too; see the next entry.)
- **A landing job starts only when its memory fits beside what runs, and while it waits for memory
  it drains the machine.** (Settled on the user's delegation 2026-11-09; the design is the user's.) It waits with the reason `draining`; every development job
  waits `behind` it (no backfill past it, even for a job that fits and would end at once), a second
  landing job waits `behind` it, and the daemon's take-slot ticket becomes the landing job's, dated
  just ahead of take-slot's earliest waiter, so take-slot admits none of its runs either. Why: a
  landing job started regardless of memory overcommitted the machine (a 36G landing beside 50G of
  development jobs in a 56G budget), swapping the one run everyone waits for; draining keeps the
  lane's promise — it goes next — without the overcommit. Alternatives: start it anyway (the old
  rule, the bug); wait for memory but let development jobs backfill (a stream of small jobs could
  keep it out for ever); kill or pause development jobs to make room (loses their work; pausing
  still holds their memory). The ticket's date moves ahead of take-slot's waiters rather than
  staying at the landing job's arrival because a waiter that arrived earlier would otherwise still
  be admitted ahead of it.
- **A landing job whose memory alone exceeds the budget is accepted, and starts when nothing else
  of marshal's runs.** (Settled on the user's delegation 2026-11-09. Review with the user.) It drains the machine as any landing job short of memory does,
  and starts once the running jobs have all ended. Why: the lane is for the job that must run, the
  budget is set below the machine's memory (8G less by default), and a reservation can be declared
  generously; refusing it at submit would turn a cautious `--mem` into a failed landing, and a
  budget lowered across a restart could not refuse a job already queued anyway. Alternative:
  refuse it at submit like a development job (consistent with the development lane, but strands
  queued jobs on a budget change and fails the run everyone is waiting for). Revisit if landing jobs
  are routinely declared larger than the budget: that would mean the budget is wrong.
- **A job whose units or memory exceed the budget is refused at submit**, rather than queued for
  ever or clamped. A job weighs at least 1 unit.

## Jobs

- **Default kind**: `test` when a word of the command is exactly `test`, otherwise `build` (as
  take-slot weighs a command with a `test` word). The kind can always be given.
- **A job's environment is the caller's**, sent with the request and set on the command over the
  daemon's own. Variables the daemon has and the caller does not are inherited by the job; Avin's
  `Command` has no way to start from an empty environment. Review: a `withoutEnv` or
  `clearEnv` in `avin.process` would make it exact.
- **`--deadline` takes minutes when bare, and `s`, `m`, `h` suffixes**, so tests can give seconds
  and the take-slot habit of minutes keeps working.
- **When a job's main process ends, a TERM goes to its process group**, so what it left running in
  the background does not hold the machine outside the budget. A job that means to leave a
  process behind starts it in a session of its own.
- **Exit statuses**: the code; 128 + signal; 124 timeout (take-slot's); 143 for a job cancelled while
  queued (as if TERMed); 125 for a lost job; 2 for marshal's own failures. Alternative for lost:
  reusing 124 (would read as a timeout).
- **A program that cannot be started exits 127**, with the reason in the job's log, whether it was
  started through `nice` or directly.

## Deadlines

- Learned from runs that **exited 0** only: a failure that stops early, a timeout or a kill says
  nothing about how long the work takes.
- Window 20, at least 3 runs, factor 2, floor 5 minutes; all but the factor are settings.
- A landing run of a kind has its own history (`<kind>+landing`), since a landing run usually does
  more than a development run of the same command.

## The daemon

- **One thread owns all state** and reads one channel of messages; client connections, process
  waiters, deadline sleepers and the TERM watcher each run on a thread of their own and only send
  messages. No locks, and nothing polls: a `wait` is answered from the message that the job ended.
- **Each running job has a thread sleeping until its deadline**, rather than a timer ticking:
  a sleeping lightweight thread costs a page, and the deadline is exact.
- **Auto-start lock**: the command that creates the directory `starting` (atomic) launches the
  daemon, writing its pid inside; others wait for the socket. A `starting` whose pid is dead is
  stale and replaced. The daemon removes it once it listens. Why: two commands started together,
  with a stale socket left behind, would otherwise start two daemons and one could unlink the
  other's socket.
- **SIGTERM is `stop --force`**: running jobs are killed, queued ones cancelled, all recorded, the
  socket removed. Alternative: leaving jobs running (they would be recorded as lost by the next
  daemon and run outside any budget).
- **`stop` without options is refused while jobs run or wait**; `--wait` drains (no new jobs, exits
  when the last ends); `--force` kills. The socket is removed before `stop` is answered, so a new
  daemon can start the moment the command returns.
- **Lost jobs are recorded, not killed**: the next daemon writes a `lost` event for each job the log
  left open, saying whether its process group is still alive. Killing it would risk a process
  group id the system has since reused.
- **A `wait` for a job an earlier daemon ran is answered from the event log.** Job ids continue from
  the highest id in the log.
- The event log carries the whole job in every event, so any one line describes its job.

## Sharing take-slot.zsh's directory (branch `take-slot-interop`)

Each of these is **settled on the user's delegation 2026-11-06**, made for the transition while
sysl's scripts move to marshal.

- **take-slot's waiters join marshal's queue by arrival time, under marshal's backfill rule.** A
  waiter that fits is counted as holding its units (take-slot will admit it within its next look); a
  blocked one is never overtaken by a job that could delay it; one behind a blocked head takes
  nothing, as take-slot will not admit it either. Why: take-slot is strict first come first served,
  and its waiters must not be starved by marshal's stream of jobs. Alternatives: strict FIFO against
  every take-slot waiter (simpler, and wastes units marshal's backfill now uses); ignoring waiters
  (starves take-slot's tests).
- **take-slot's holders are expected to end at once.** Their files say nothing about when they
  started or how long they run, so a head waiting on them has its start "now" and nothing backfills
  behind it. Alternative: estimating from the file's age and take-slot's deadlines (more guessing,
  for a few weeks of use).
- **The reverse needs no change to take-slot: marshal posts one ticket**, named as take-slot names
  one with the arrival of its first waiting development job and the daemon's pid, holding the units
  and a second line `marshal` (take-slot never reads a ticket). take-slot admits only its earliest
  ticket, so its later runs wait behind marshal's head; the ticket goes when the job starts or the
  daemon stops. Why one ticket and not one per job: take-slot only ever looks at the earliest.
- **Decisions and registrations are made under take-slot's mutex**, as take-slot makes its own, so
  neither side can admit into units the other has just taken. The mutex holder is the daemon; its
  stale rule (a dead holder's mutex is removed) is take-slot's.
- **A job is registered by its own pid** (the process group leader `nice` becomes), so take-slot's
  `kill -0` sees it live exactly while it runs, even if the daemon dies.
- **A 3-second look while jobs wait**: take-slot's runs end without telling marshal. The daemon reads
  nothing while its queue is empty. Alternative: watching the directory with kqueue (Avin has no file
  watching).
- **A daemon after one that died removes its lost jobs' registrations and landing lock, alive or
  not**, and its tickets (only those marked `marshal`, so a take-slot run since given the same pid
  keeps its own). Why: the next daemon no longer counts those jobs, and a pid reused by an unrelated
  process would otherwise hold units for ever. Alternative: keeping a lost job's file while its pid
  lives (it may still be running and using the machine). Review with the user.
- **Where**: `take_slot` in `config.json`, `""` for none, and `MARSHAL_TAKE_SLOT_DIR` over it; with
  neither, the sysl repository's `.git` when it exists. The brief named the key `takeSlot`; it is
  `take_slot` to match every other key of the file. A named directory that does not exist stops the
  daemon from starting, rather than silently sharing nothing.
- **take-slot's units are clamped to marshal's budget** when they ask for more, as take-slot clamps
  to its own; each side measures against its own budget, so the two must be set equal.
- **`status --json`** is one object: the budget fields of the protocol's status reply, `take_slot`,
  and `running` and `queued` arrays of jobs as the protocol writes them.

## Help and the module prefix

- **A bare `marshal` prints the usage to standard error and exits 2**: it is a command line that
  names no command, and a script that ran it by mistake must not read the usage as output. `--help`,
  `-h`, `help` and `<command> --help` are asked for, so they print to standard output and exit 0.
- **`submit` and `run` read `--help` only among their options**, up to `--` or the command's first
  word, so `marshal run -- prog --help` and `marshal run prog --help` run `prog`; an option's value
  is never help (`run --kind --help` is a kind, then no command). The other commands take `--help` or
  `-h` anywhere before a `--`.
- **The modules are `dev.avinlang.marshal`, `.cli` and `.daemon`**, laid out under
  `dev/avinlang/marshal/` as the package's directories require; the package is still named `marshal`.

## marshal top (branch `marshal-top`)

**Settled on the user's delegation 2026-11-06**; each says what else was weighed. Review with the
user: tui pinned by commit until it has a tag, and `top` never starting a daemon by itself.

- **One `snapshot` request** answers everything the view draws: the budget, uptime, running,
  queued and recent jobs, and each queued job's place and reason. Why: one reply is one consistent
  moment, where `status` then `ls` could disagree; `status` and `ls` keep their replies, so older
  clients are untouched. Alternatives: adding the fields to `status --json` (it is a script's
  interface, and the reasons are not a script's business) or to `ls`.
- **The reasons are computed by the scheduler's own walk** (`waits`, beside `schedule`, over one
  shared `decide`), so a reason can never contradict what the scheduler does; a test holds the
  jobs said to be `starting` equal to the jobs `schedule` starts. A job short of units only because
  of take-slot's runs or its admitted waiters is `take-slot`, not `units`.
- **`recent` includes jobs earlier daemons ended**, the lost ones among them, read from the event log
  at start; that is the only way `lost` ever shows. `ls` still lists only this daemon's.
- **top never starts a daemon by itself.** It shows "no daemon", looks again every second, and `s`
  starts one. Why: a viewer opened to see whether marshal is up should not change the answer, and
  a wrong `MARSHAL_HOME` would otherwise start a stray daemon silently. Alternative: starting one as
  every other command does.
- **The log pane reads the job's log file**, as `marshal tail` does, once a second and after each
  key: the log is a file the daemon does not hold open for clients, and routing it through the
  daemon's one thread would make a busy log slow everyone's requests. Everything else comes from
  the socket; nothing reads `events.jsonl` or take-slot's directory.
- **Keys with the log open**: Up and Down still select (the pane follows the selection); PgUp, PgDn,
  Home and End scroll the log, and End follows its end again. Alternative: a focused pane taking
  the arrows (one more mode to know).
- **tui is a git dependency pinned to a commit** (`rev`), since tui has no release yet; a path
  dependency cannot build from the brew formula's checkout. Review: pin to tui's first tag once it
  has one.
- **Colours**: running green, queued yellow, exit 0 green, a failure red, a timeout red reversed,
  killed magenta, lost magenta reversed, cancelled grey; time left yellow under a quarter or five
  minutes, red under a tenth or one minute.

## Measured memory (branch `top-columns`)

**Settled on the user's delegation 2026-11-07**; each says what else was weighed. Listing a group's
members with `pgrep -g` was temporary, until avin bound Sysl's `group_members`; it now does (see
"Avin 0.0.13 calls replace the workarounds", last section).

- **A job's tree is its process group**, listed by `pgrep -g` (the same listing the deadline's
  stack sampler already used) and each member's `residentBytes` summed; a member gone since it was
  listed counts 0. Why: every job runs in a group of its own that its programs join, the group is
  what `kill` stops, and avin has no call that lists a group's or a process's children. Review:
  replace `groupMembers` with avin's own listing once it has one; a program that leaves the group
  (`setsid`) is not counted, as it is not killed. Alternatives: the job's main process alone (a
  `sysl test` holds little itself; its workers hold the memory); walking parent ids from `ps`.
- **Measured every second on a thread of its own**, which sends the sizes back to the daemon's
  thread; one measurement at a time, and nothing measured while nothing runs. Why: a `pgrep` and a
  call per process cost little, a second is what top refreshes at, and the daemon's thread never
  waits on a child. Alternatives: measuring on each `snapshot` or `status` (no peak between
  requests, and the request waits); a configurable period (no one has needed one).
- **RSS is shown only while a job runs, PEAK always**: an ended job holds nothing; its peak is what
  a kind's memory can be learned from, so every event carries `peak_rss` and an ending event's is
  final. Sizes there are rounded (`812M`, `9.4G`), where RESV keeps the exact form `--mem` takes.
  Alternatives: one `RSS/PEAK` column (narrower, harder to read); keeping the last measurement of an
  ended job as its RSS.
- **`ls` calls the declared memory RESV too**, as top does, so one word means one thing.
- **The header's memory line adds `rss` and `machine`** after the reservation and budget, the
  machine's memory left out where it is unknown; its bar stays the reservation against the budget,
  since that is what the scheduler decides by.

## Restart (branch `exec-upgrade`)

**Settled on the user's delegation 2026-11-07**; each says why and what else was weighed. Review
with the user: the restart taking the program at the daemon's own path (so an install must replace
that file, built to `.new` and moved over it), and the test-only `$MARSHAL_TEST_VERSION`.

- **A restart replaces the daemon's program in place (`process.exec`), keeping its process.** Its
  jobs stay its children, so the new program waits for them by pid and gets their real exit status.
  Why: only a parent can learn how its child ended; a new process could only watch the old jobs'
  pids and would record each as lost. Alternatives: `stop --wait` then start (waits out every
  job, perhaps an hour of tests); a separate long-lived supervisor owning the jobs (a second
  daemon to install and upgrade).
- **Jobs are detached as they start and always waited for by pid**, in either program, so nothing
  about waiting for a job depends on which image started it.
- **The state goes through `<home>/state.json`, its path given as `daemon --resume <file>`.** The
  new program reads it, checks it was written by its own pid, and removes it. Why: a file can be
  read back and inspected when a restart goes wrong; Avin closes every descriptor on exec, so a pipe
  cannot be carried across. Alternatives: rebuilding from `events.jsonl` (has no deadline left,
  kill mark, queue order or take-slot ticket); the state in an environment variable (size-limited,
  and visible to the jobs started later).
- **Saved times are on the wall clock**, converted from the monotonic clock on save and back on
  load, so the file means the same to any reader. A clock step during the instant of a restart
  shifts deadlines by that step. Alternative: monotonic times (the process keeps its clock across
  exec, but a value in a file would then mean nothing outside it).
- **The program is the one the `restart` command was run from** (superseded the daemon's own path;
  see the end of this section). `$MARSHAL_RESTART_PROGRAM`, in the daemon's environment, names
  another (the tests use it).
- **While it hands over, the daemon carries out nothing new**: it starts no job, writes every reply
  it has given, records every job that has ended, and holds requests unanswered; their connections
  close at exec and their clients connect again for up to 30 seconds and ask again. Why: a client
  that saw no reply then knows its request was not carried out, so asking again never submits a
  job twice. Alternative: answering "restarting" and having clients retry on that (one more reply
  every client must know, and a `wait` would still need to reconnect).
- **A restart that cannot exec leaves the daemon as it was**: the state file is removed, held
  requests are carried out, and `restart` exits 2 saying why. A TERM arriving during the hand-over
  stops the daemon as TERM always does, instead of restarting.
- **`restart` is refused while the daemon is stopping or draining**; with no daemon it prints so
  and exits 0, starting none. `version` never starts a daemon either.
- **A job being killed or timed out when the daemon restarts is sent TERM again by the new program**,
  whose grace period then starts afresh, since the thread that would send the KILL went with the
  old image. So its KILL can come up to 5 seconds later than it would have.
- **`$MARSHAL_TEST_VERSION` sets the version the daemon reports and saves**, so the tests can
  restart into a "newer" marshal and check that `version` and `restart` report the change.
  Alternative: building a second marshal with another version inside the test (a minute of build
  per run, and a second copy of the build's rules in the test).
- **The test of a daemon killed outright now runs**: Avin closes descriptors on exec, so a killed
  daemon's socket no longer stays open in its jobs, and the next daemon records them as `lost`.

Known gaps in Avin, left for it to fix rather than worked around here:

- A job that ends in the milliseconds between the daemon's last look and its exec is reaped by the
  old image, so the new one cannot learn how it ended and records it `lost` (exit 125).
- (Closed: `state.json` is now written aside and renamed, see "Atomic writes and the step-cache
  digest".)

- **The client sends its own executable path in the restart request** (branch
  `restart-after-upgrade`; settled on the user's delegation 2026-11-08; review with the user: the
  accepted risk of a client from another install). The daemon
  restarts into, in order, `$MARSHAL_RESTART_PROGRAM`, the request's optional `program`, then its
  own `process.executable()`, after checking the file exists and is executable (otherwise it says
  so, exits the request with an error and carries on, as for any failed restart). The client's path
  is `process.executable()`, which resolves symbolic links, so under Homebrew it names the current
  Cellar directory. Why: after `brew upgrade` the daemon's own file is gone (cleanup removes the old
  Cellar directory) or is the old version, so restarting into it fails or defeats the upgrade; the
  command the user just ran is by definition the marshal installed now. An older client omits the
  field and keeps the old behaviour. Alternatives: resolving, in the daemon, the symlink the daemon
  was started as (`/opt/homebrew/bin/marshal`; needs the daemon to know that path, which it does not
  once started through the resolved one, and says nothing where there is no link); a fixed
  well-known install path (names a layout marshal must not assume). Risk accepted: a client from
  another install swaps the daemon for its own program; whoever can reach the socket can already stop
  the daemon and run jobs as its owner.

## Accounting: `history` and `stats` (branch `history`)

**Settled on the user's delegation 2026-11-07.** Review with the user: a bare number refused, and
`--limit` defaulting to 20. (Times and `--since` dates are local; see the last section.)

- **both commands read `events.jsonl` in the client, streamed line by line, and never ask
  the daemon.** Why: the log is the record, they work with no daemon (and after a crash), and a huge
  log never goes through the socket or into memory whole; only one small record per ended job is
  kept. Alternative: a daemon request (needs a running, new-enough daemon and a new reply shape).
- **a job that has several ending events is listed once, as its last one**, as the
  restart recovery does.
- **outcomes are listed as `ok`, `failed`, `signal`, `killed`, `timeout`, `cancelled`,
  `lost`; `--failed` means "did not exit 0", so a kill, a timeout, a cancel and a loss all count.**
  Why: one rule with no judgement about whose fault an end was, and it matches what learning
  counts as a success. Alternative: only `failed`, `signal` and `timeout`.
- **percentiles are nearest-rank** (the value at rank ceil(p*n/100)). Why: it always
  names a run that happened, and is defined for one sample (every percentile) and two (p50 is the
  lesser, p90 the greater). Alternative: interpolation, which invents durations.
- **durations in `stats` cover every job that started** (cancelled jobs have none);
  the success rate is over all of a kind's jobs, and `stats` rows are per history key, so landing
  runs are a separate `kind+landing` row. The deadline shown is the one the daemon would give the
  next job, learned from the whole log whatever `--kind`/`--since` select.
- **`--since` takes a length back from now (`s m h d w`) or a date or date and minute.** A bare
  number is refused, as it is ambiguous (the `--deadline` option reads it as minutes). How dates and
  printed times are read is in the last section.
- **`history` lists 20 jobs unless `--limit` says otherwise**; `--limit 0` is refused.
  `--json` is one object on one line, like `status --json`, not a line per job.
- **peak memory is read from `peak_rss` on ending events when it is present and above
  zero; otherwise `-` (null in JSON).** `history` does not show it.
- **lines that are not events (or ending events that do not describe a job) are
  skipped, counted in `unreadable`, and reported on standard error; the exit status stays 0.**

## Pausing jobs, holding and ordering the queue (branch `pause-resume`)

**Settled on the user's delegation 2026-11-07.** Review with the user: a paused job keeping its
units (freeing them is the alternative, for jobs that declare no memory). Pausing a job-types run
stops only the runner's group until avin can list a process's descendants.

- **`marshal pause <id>` sends STOP to a running job's whole process group, and `resume <id>`
  sends CONT** (`avin.signal.Stop` and `Continue`, numbered per platform). The group, not the main
  process, so a test runner's workers stop with it. Alternatives: the main process only (its
  children go on using the machine); TSTP (a program may catch it and refuse to stop).
- **A paused job keeps its units and its memory.** Why: a stopped process still holds its memory,
  so giving its share to another job could overcommit the machine, and it may be resumed at any
  moment. Alternative: freeing its units while it is paused and making `resume` wait until they
  fit again (lets other work use the processors, at the risk of memory pressure and of a resumed
  job queued behind what started meanwhile); worth revisiting for jobs that declare no memory.
- **A paused job's deadline clock stops**: the job keeps `pausedMs` (its earlier pauses) and
  `pausedAt` (when its current one began), its run time is its wall time less those, and the
  deadline counts run time. Its `elapsed_ms`, its run time in the event log and the history its
  kind's deadline is learned from leave pauses out too. The deadline's sleeper is re-armed on each
  resume, and one armed before a pause is made stale by a generation number rather than
  cancelled. Alternative: wall time (a long pause would end the job at its resume).
- **`kill` of a paused job, `stop --force` and a TERM to the daemon send CONT before TERM**, so
  the job can act on the TERM instead of waiting for the KILL 5 seconds later; the pause ends there.
  When a paused job's main process ends, whatever is left of its group gets TERM then CONT.
- **A paused job stays paused across `marshal restart`**, its processes stopped and its clock with
  them: `paused_ms` and `paused_at` (wall clock) are in `state.json`.
- **`pause` of a job that is queued, ended, being stopped or already paused, and `resume` of one
  not paused, are refused** (exit 2). `stop --wait` is refused while a job is paused, as while one
  is held: it would wait for ever.
- **`pause` and `resume` with an id act on that job, and without one on the queue.** Alternative:
  separate commands for the queue (two words for two kinds of the same act).

- **`marshal pause` and `resume` with no id hold and release the whole queue, both lanes.** Running
  jobs go on; nothing new starts, landing jobs included, until `resume`. Why: holding the machine
  for a moment (a benchmark, a hand-run release step) means nothing new at all, and the landing
  job is the heaviest. Alternatives: holding the development lane only (a landing job would still
  start under someone who asked for quiet); a separate `hold-queue` command (the words `pause` and
  `resume` are freed for one job by giving it an id).
- **A held queue keeps no take-slot ticket**, so take-slot's runs are not kept waiting behind jobs
  that cannot start. The queue's jobs keep their arrival times and take their places again on
  `resume`. Alternative: keeping the ticket (take-slot would wait on marshal for as long as the
  queue is held).
- **`pause` of a held queue and `resume` of one not held are refused** (exit 2), as are `hold` of a
  held job and `release` of one not held. Why: a script learns its view of the daemon was wrong.
  Alternative: both idempotent and silent (two people holding the queue would not learn that the
  first `resume` released it for both).
- **A held job keeps its place in the queue and the scheduler does not see it**: the jobs behind it
  start as if it were not there, and none waits behind it as the head. Alternative: a held job
  stays the head and blocks its lane (that is `pause`).
- **Holding and priority are for queued jobs only**; a running or ended job is refused, naming its
  state. `kill` cancels a held job like any other queued one.
- **Priority is an int, 0 by default; higher goes first in its lane, equal ones by arrival.** The
  queue is kept in that order, so `ls`, `top` and `status --json` list it as it will run. Why: a
  number covers "this one first" and "this one last" alike and is easy to script. Alternatives:
  moving a job to a position (positions shift as jobs start, so a script cannot name one reliably);
  a few named classes (no room between them).
- **Urgent is a band, not a priority number.** Settled on the user's delegation 2026-11-07. Each
  lane's queue begins with its urgent band, ahead of every job not urgent whatever its priority,
  and the band is first come, first served: a job joins it at the back, behind every urgent job
  already queued (held ones included), and is never in front of an earlier one. `submit --urgent`
  and `run --urgent` (as take-slot's `-u`) queue a job there; `priority <id> --urgent` moves a
  queued job to the back of the band, even from within it; `priority <id> <n>` takes a job out of
  the band and places it by `n`. It is still the normal queue: landing jobs have a lane of their
  own, which always goes first and has its own band. The band is kept as each job's mark of when
  it joined (`urgent_at`, wall-clock microseconds, 0 outside it; a mark is always later than every
  mark queued, so a clock stepping back cannot reorder the band), sorted before priority, and the
  mark is in `state.json`, so the band keeps its order across a restart. Why the mark over a
  reserved priority level: a level would need arrival order inside it, which arrival cannot give
  for a job moved into the band later, and it would take a range of priorities away from users.
  Alternatives: max + 1 over the priorities queued (the shape first built: a later urgent job went
  in front of an earlier one, and it ran out at the highest int); a fixed urgent level (two urgent
  jobs tie, and the tie falls back to arrival, not to when they became urgent).
- **Priority orders marshal's own jobs; take-slot's waiters keep their places by arrival.** An
  urgent job does not pass a take-slot run that arrived before it, and marshal's ticket in
  take-slot's directory is its first eligible job's arrival. Why: take-slot orders its waiters by
  arrival alone and cannot be told of a priority. Alternative: the ticket taking the earliest
  arrival of any queued job (take-slot's later runs would wait behind a job that is not first).
- **`stop --wait` is refused while the queue, or a queued job, is held** and anything is queued,
  since it would wait for ever; `--force` still stops. Holding a job while the daemon drains is
  refused for the same reason.
- **The held queue, held jobs and priorities go into `state.json`** (`queue_held`, and `held` and
  `priority` on each job), so a restart keeps them; a state from before reads as nothing held,
  every priority 0. Jobs carry `held`, `priority` and `urgent` in the protocol and the event log, and the
  log records `held`, `released` and `prioritized`. Holding the queue is not a job's event, and
  goes to the daemon's log.

## Job types and the train (branch `job-types`)

**Settled on the user's delegation 2026-11-07**; each says why and what else was weighed. Review
with the user: take-slot sharing off unless configured; a type's run being one job; a diverged
local target branch left with a warning. The user approved the design (types as
data, steps as any program, a line protocol, marshal core without git, stock steps in Avin) on
2026-11-07; these are the choices it left open. Review with the user: the take-slot default
(first), a type's run being one job, and the local target branch left behind as a warning.

- **Sharing take-slot's directory is off unless configured.** The default was the sysl
  repository's `.git` on this machine; marshal names no path of any machine now. A machine that
  shares it sets `"take_slot": "<dir>"` in `config.json` (or `$MARSHAL_TAKE_SLOT_DIR`). Why: the
  brief's "nothing names a path from this machine" and "off unless configured". Alternative: keep
  the default where the directory exists (a stranger's machine never has it, but the code would
  still name it).
- **A `.job` file is JSON, with `//` comment lines.** Why: a step's `run` is an exact argument
  list with no quoting rules to learn, marshal already reads and writes JSON, and a misspelt field
  is refused by name. Alternatives: HOCON (Avin has no reader for it), a line format of our own
  (quoting rules for arguments), TOML (no reader either). Comment lines read as empty lines so a
  parse error's line number is still the file's.
- **A type's run is one job, whose command is marshal's own `run-steps`**; the steps run inside it,
  one at a time, each in a process group of its own. Why: the lane, units and deadline hold for the
  whole run, so a train keeps the landing lane from merge to teardown; the daemon stays as it was,
  with no step state, no git and nothing new in `state.json` (a restart does not touch a running
  type: the runner is just a job's process). Alternatives: the daemon runs the steps itself (its
  state, and `state.json`, would carry every run's place in its steps and bisection); the command
  line submits each step as a job (the lane is let go between steps, and the run dies with the
  command line). So no job field was added, and the restart state is unchanged.
- **Every job gets `MARSHAL_JOB` and `MARSHAL_HOME`** in its environment, so a run keeps its files in
  `<home>/runs/<id>`, where `run-type` finds its report.
- **A step's group is its own, so the runner forwards a stop**: on TERM it sends TERM to the step's
  group, KILL 4 seconds later, and exits 143, inside the daemon's 5-second grace. A runner killed
  outright with KILL leaves the step's group running; `process.groupMembers`, coming in Avin, would
  let the daemon stop a job's whole tree, groups of its own included.
- **Fetching the base is the train's first step, not marshal's.** The brief lists "fetching the
  base at job start" among marshal's machinery, but fetching is git, and marshal core knows none;
  `stock:git merge` fetches as it starts. Alternative: a generic "run this before the job" hook (a
  second way to say what a step says).
- **Transitions:** `next` goes on (after a failure, the failure is let go); `land` is allowed only
  on success and only in the gate; `bisect` only on failure and only in the gate; `report` ends the
  steps as the step came out; `stop` ends the run. Defaults: `next` on success, `stop` on failure.
  A transition written as a reference is checked once the parameters are bound, before anything
  runs. Alternative: one more word for "fail but go on" (what `next` on failure already says).
- **The success test:** the exit code `exit` allows (`0` by default, a list, or `"any"`), no
  `RESULT red`, and a last `RESULT green` where `result` is set. `=== EXIT` overrides the process's
  code, the last one counting, for wrappers whose own status means nothing.
- **A malformed line of a kind marshal knows is not read, and the log says why; a kind it does not
  know is the step's own output.** Why: `=== RUN TestX` (a common test runner's) or a ruler of
  `=====` must not fail a step. Alternative: failing the step on a malformed line (stricter, but a
  step's output is not marshal's to police).
- **Bisection halves the values**, searches each half that fails alone, and blames a set whose
  halves both pass alone as failing together. Failures that all name a value blame those without
  bisecting; one that names none means a bisection. Then one last pass over the rest, which lands
  them; the run is red, since not everything landed. The bisection's passes never land. Why: few
  passes for the common case of one bad branch (four extra passes for three branches, one bad).
  Alternatives: each branch alone (N passes, and misses failures that need two branches); leaving
  each one out in turn (N passes of nearly the whole batch).
- **The first `land` step is the one that lands**: where a later land step fails (a teardown that
  keeps a branch), the run is red at that step but reports the values as landed. Alternative: a
  protocol line saying "landed" (one more kind for something the order already says).
- **`run-type`'s own options** (`--dir`, `--deadline`, `--units`, `--mem`, `--submit`, `--help`)
  may stand anywhere before `--`, so `marshal train --dir x …` works; a type's parameters may not
  take those names.
- **Types are looked for in the project's `.marshal/types`, then `<home>/types`, then marshal's
  own**, so a project overrides the stock train by copying it under the same name. marshal's own
  are `$MARSHAL_STOCK`, or `share/marshal` beside the executable's directory, as an install lays
  them out.
- **A stock step is an Avin package** (`stock/steps/git`, with its own `avin.hocon`), not a file:
  inside marshal's package, a lone `.avin` file is taken for one of marshal's modules. One program
  holds `merge`, `land`, `teardown` and `cleanup`, so they share their git helpers and compile once.
- **Compiled steps are cached at `<home>/steps/<name>-<hash>`**, the hash of the compiler's
  `--version` and the source (every file of a package, by path), so a new compiler or a changed
  source compiles again and old builds stay for runs that want them. Concurrent runs compile once:
  the one that makes `<program>.lock` (holding its pid) compiles; a lock whose pid is dead is taken
  over, with any half-built file. The hash is SHA-256, shortened (see "Atomic writes and the
  step-cache digest").
- **The train merges the remote's copy of each branch**, as pushed, never the local one: what was
  pushed is what lands, and a commit not pushed never lands. A branch that does not merge is
  blamed by name (`=== FAIL merge <branch>`): the later of the two that conflict.
- **The integration tree is a worktree in the pass's directory**, removed by `cleanup` by deleting
  the directory and `git worktree prune`, not `git worktree remove --force`: it is the run's own
  scratch, made by `merge`, and holds nobody's work; a user's worktree is never forced. Alternative:
  a shared clone (no worktree record in the repository, but its branches would have to be fetched
  across).
- **`land`** fetches the target, refuses unless the merged commit contains the remote's target as it
  is now (a fast-forward), pushes that very commit (`<sha>:refs/heads/<target>`), and checks with
  `ls-remote` that the remote has it. It then moves the repository's own target branch on, a
  fast-forward only (`merge --ff-only` in the worktree that has it checked out, `push .` where none
  does). **A local target that has diverged is left where it is, with a warning, and the land step
  passes**: the remote landed, and the teardown's checks do not depend on the local branch.
  Alternative: failing the land step (the run would then not tear down branches that did land).
- **`teardown`** fetches with `--prune` first, then for each branch: removes its worktree without
  `--force` (one with changes keeps the branch, remote copy and all); deletes the remote's copy only
  where the landed commit contains it (`merge-base --is-ancestor`), and that push must succeed;
  deletes the branch with `-d`. What it keeps it names (`=== FAIL teardown <branch>`), and the step
  fails. A branch pushed again between the fetch and the delete is the window this leaves;
  `--force-with-lease` on the delete would close it, and was left out because the rule is "never
  force" and a lease reads as one. Review with the user if that window matters.
- **Portable calls**: the machine's memory comes from `process.totalMemory()` rather than `sysctl
  hw.memsize`. What is left macOS-only is the stack sample of a job at its deadline (`sample`): where
  the program is missing the job is stopped unsampled. `pgrep -g` and `ps -o pid=,time=` are POSIX.

Gaps in Avin met here, left for Avin to close:

- (Closed: the library now has `avin.crypto` and `fs.rename`; the step cache and the files other
  processes read use them.)
- A process's descendants in groups of their own cannot be listed (`process.groupMembers`, coming):
  a runner killed outright leaves its step's group behind.

## Waiting on events (branch `wait-until`)

All **settled on the user's delegation 2026-11-07**. Review with the user: `--since` on `wait`
(added beyond the request), and `job=a,b` answering with one event rather than an aggregate. The
50 ms connection poll is an avin gap (no wait on a channel and a socket together).

- **the daemon subscribes, on its own thread; a client never tails the log.** A `watch`
  request is handled in the daemon's message loop, which is also the only code that appends to
  `events.jsonl`: it reads what the log holds (for `--since`) and registers the watcher with no
  append between, so an event is neither missed nor seen twice. Alternatives: tailing the file from
  the client (misses events written between a stat and the open; polls); an event id the client
  resumes from (needs ids on every line and a ring buffer in the daemon).
- **each watcher has a bounded stream (256 replies), and a reader that fills it is dropped.**
  The daemon uses `trySend`, never `send`: it must not block on a client. The dropped watcher's oldest
  reply is removed to make room for a last reply saying events were dropped, and its stream closes;
  the command prints that on standard error and exits 1, and `--since` recovers what was missed.
  Alternatives: an unbounded buffer (a stopped reader grows the daemon without limit); blocking the
  daemon (one stopped `events --follow` would freeze every job). `$MARSHAL_TEST_WATCH_BUFFER` sets the
  size so a test can make a reader fall behind with a handful of events.
- **a wait for an event condition sees only events after it asks, unless `--since` looks
  back.** `ended` means "the next job to end", while `job=<id>` and `idle` are about state and are met
  at once when already true. Why: otherwise `wait --until ended` would return immediately whenever
  anything had ever ended. Alternative: replaying the last event by default (answers a different
  question each time, depending on history).
- **`job=<id>,<id>` answers with the ending event of the job that ended last**, one line like
  the others, rather than an aggregate object. For jobs all ended before the wait, that is the latest
  of their ending events in the log. Unknown ids are refused (exit 2): a wait for a job that was never
  numbered would otherwise never end.
- **`idle` is answered with a synthetic event** `{"ts":...,"event":"idle","running":0,"queued":0}`,
  since no logged event says it. The daemon looks again after each job ends, once the scheduler has
  started whatever could start, so a job ending as the next starts does not answer it.
- **the outcome words** are `ok` (finished with exit 0), `failed` (finished with any other
  exit status, or by a signal that was not `kill`), `timeout`, `killed` and `lost`, as the event names
  say; `failed` as a condition is every ending but `ok`. `outcome=ok` with `failed` is refused as a
  contradiction, and an outcome filter on `started` or `submitted` is refused, since only an ending
  has an outcome.
- **a restart is survived by asking again with `since`.** The connection closes without a
  final reply when the daemon execs; the client connects again (never starting a daemon, unlike
  `wait <id>`: a watch has nothing to ask of a daemon that was stopped) and asks with `since` set to
  when the wait began, or to the time of the last event printed for `events --follow`, where a line
  already printed at that time is not printed twice. Alternatives: the daemon carrying watchers in
  `state.json` (a socket cannot be handed to the next image; the client has to reconnect anyway).
- **exit statuses of `wait --until`**: 0 met, 124 timeout, 2 for a bad condition or an
  unknown job, 1 for no daemon, a daemon that stopped, or a dropped reader. 124 is take-slot's and the
  job timeout's too, which reads the same for a caller: the wait gave up.
- **the stream's end of life is noticed by polling the connection.** A connection belongs
  to one thread, so the thread writing a watch's replies cannot also wait for the client to leave;
  it reads with a 50 ms timeout between writes, and a read that finds the end ends the watch. An
  event therefore reaches a client up to 50 ms after it is logged. Alternative: a second thread
  reading the connection, which Avin does not allow (see below).

Known gap in Avin, left for it to fix rather than worked around here:

- A thread cannot wait for a channel and a socket at once, and a connection cannot be read on one
  thread while another writes it, so a daemon cannot be told promptly that a streaming client has
  gone, nor can it sleep until either an event or that. `Channel` has no receive with a timeout and
  `UnixStream` no poll; a `select` over both would remove the 50 ms wakeups.

## A job's start time across a restart (branch `started-at-restart`)

**Settled on the user's delegation 2026-11-07.**

- **A job's wall-clock start (`started_at`) is stored once, when it starts, and saved and restored
  as that exact number.** The daemon used to save `wall(startedMs)`, re-deriving the wall time from
  its monotonic clock and an offset sampled at save time, so the value read back could differ by a
  millisecond from the one reported before the restart. Now the saved value is the stored one, and
  the monotonic `startedMs` (used only for elapsed time and the scheduler) is derived from it on
  restore. A job cancelled while queued has no start time (0), and restores its `startedMs` from its
  end. Why: a reported timestamp must not change because the daemon restarted. Alternatives: round
  the derived value to the second (hides the drift, still wrong); keep only the monotonic clock and
  report offsets (a restart loses the wall time).

## The STARTED column (branch `started-column`)

**Settled on the user's delegation 2026-11-07.** Review with the user: the year left out of
STARTED.

- **`top` and `ls` show a STARTED column, `MM-DD hh:mm` in the caller's local zone, between RESV (`ls`)
  or PEAK (`top`) and ELAPSED.** The zone is read once per rendering (`TZ`, else the system's), and
  the time comes from the job's recorded `started_at`; a job with none (queued, or cancelled before it
  ran) shows `-`. The year is left out, so a job from a year ago reads like one from today; the
  JSON has the full instant. Alternatives: an ISO date with the year (16 cells, too wide for top);
  a relative age (`3h ago`, which ELAPSED already half says and which changes every frame).
- **`top` leaves PEAK out under 90 columns, and always shows STARTED.** (Settled on the user's
  delegation 2026-11-07, replacing the first proposal, which dropped STARTED.) The user asked for
  STARTED, so it must show at 80. The fixed columns with everything take 85 cells; without PEAK
  they leave the command 1 cell, too little, so under 90 cells STARTED also narrows (the coordinator's
  fallback): a job that started today shows just `hh:mm`, any other day keeps `MM-DD hh:mm`, and the
  column is 7 wide (its heading) unless a shown job started on another day, when it is 11. At 80 the
  command then has 5 cells (the heading reads `COMM…`) against 7 before STARTED existed. PEAK is
  the column given up because the most a job held stays in the JSON, and RSS, the live figure,
  stays. Alternatives: drop STARTED (what was asked for); drop RSS and PEAK (a second column for no
  gain); shrink every column by a cell (the memory sizes need theirs).

## Waiting for other jobs, retries and rerun (branch `depends`)

**Settled on the user's delegation 2026-11-07**; each says why and what else was weighed. Review
with the user: `dependency-failed` exiting 126, and a failed dependency cancelling at once.

- **A dependency may name only a job that already exists, so waits cannot form a cycle.** A job's
  id is given when it is submitted, after the jobs it names, so every wait points to an older job.
  An id that is no job, or the id the job itself would get, is refused; no cycle check is needed.
  Alternative: allowing ids of jobs not yet submitted (a cycle check, and a job that may wait for
  ever on a mistyped id).
- **`--after` means `--after-ok`; one job waits one way, not both.** The ids of repeated options
  of the same way are joined. Alternative: a mode per id (`--after-ok 3 --after-any 4`): more to
  explain, for a case no one asked for.
- **A failed dependency cancels the waiting job at once**, even while its other dependencies still
  run, with the outcome `dependency-failed` naming the job that failed; the cancel ends that job,
  so it cascades to what waits for it. "Failed" is anything but exit 0: a nonzero exit, a signal,
  a timeout, a kill, a cancel, a loss. Alternative: waiting for every dependency before deciding
  (keeps in view a job that can no longer run).
- **`dependency-failed` exits 126**, apart from a plain cancel's 143, so a script can tell "it
  never ran because something before it failed" from "it was cancelled". Alternatives: 143, as
  for every cancel; or a code above 128 (those read as signals).
- **A job whose dependencies have ended arrives in the queue when it is ready**, not when it was
  submitted: it was not runnable before, and jumping ahead of jobs that were would be unfair to
  them. Alternative: its submission time (it would start ahead of jobs that queued while it
  waited).
- **A job waiting for one that already ended is decided at submit**: it queues at once, or is
  cancelled at once, and still gets an id, so a script's `marshal wait` works the same either way.
  A dependency an earlier daemon ended is read from the event log. Alternative: refusing the
  submit when a dependency already failed (a script would need two paths).
- **A retried job keeps its id.** Each attempt starts with the whole deadline, appends its output
  to the job's log after a `marshal: attempt N of M` line, and is recorded in the event log, its
  ending followed by `retry`; `wait` answers when the last attempt ends. Retried: a nonzero exit, a
  signal not sent by `kill`, a timeout, a command that could not start. Never retried: a kill, a
  cancel, a loss, or any attempt while the daemon stops with `--force` or TERM. Alternatives: a
  new job id per attempt (a `wait` on the first id would end at the first failure); one deadline
  across all attempts (a retry after a timeout would have no time left).
- **No backoff by default; `--retry-delay` is one fixed delay before each retry**, shown as
  `retrying` (`retry N` in `ls` and `top`). A job waiting out its delay holds no units. Alternative:
  exponential backoff (one more option to explain; a fixed delay covers waiting out a flaky
  resource).
- **Waiting jobs and jobs waiting to retry are carried across `marshal restart`** in the state's
  `waiting` list. A waiting job's remaining dependencies are not saved but worked out again from its `after`,
  so a dependency that ended during the hand-over makes it ready; a retry's time is saved on the wall
  clock like the other times.
- **`stop` counts waiting jobs as busy**: plain `stop` is refused while any waits, `--wait` waits
  for them, and `--force` cancels them first, before the queue, so none joins a queue that is being
  cancelled.
- **`rerun <id>` submits the ended job's spec again — command, directory, environment, kind,
  units, memory, lane, deadline (as given, or learned again) and retries — but not its dependencies**,
  which have all ended. It is refused for a job not yet ended. A job that is no longer in the
  daemon's memory is found in the event log, whose `submitted` event now carries the whole spec;
  a job logged before that has none, and is refused. Alternatives: a spec file per job under
  `jobs/` (another file per job to clean up); carrying the dependencies (they have ended, so the rerun
  would be decided at once by the old outcomes). A rerun keeps `--urgent`.

## Waiting for other jobs beside holding, pausing and the urgent band (merge of `depends` and `pause-resume`)

**Settled on the user's delegation 2026-11-07**; each says why and what else was weighed. Review
with the user: hold applying to waiting jobs, and priority staying for queued jobs only.

- **"Held" means held by hand and nothing else.** A job waiting for its dependencies has the state
  `waiting` and shows as `after 3,4` in `ls` and `top`; the state's and the snapshot's list of such
  jobs is `waiting`; the event of one joining the queue is `ready`; a job's pending dependencies
  are its `after` field. Why: the two branches each used "held" and "released" for a different
  thing, and a `released` event that meant either a hold lifted or a dependency ended could not be
  filtered on. Alternative: keeping `held` for dependencies and naming the hand hold otherwise (the
  hand hold is the one people type: `marshal hold`).
- **A waiting job, or one waiting to retry, can be held**, and keeps the hold when it joins the
  queue, so it starts only once it is released. `ls` shows it as `held after 3,4`. Why: holding a
  job is "do not start this yet", which applies just as much before its dependencies end.
  Alternative: refusing `hold` until it queues (a script would have to wait for `ready` to hold
  it, and could miss its start). Priority stays for queued jobs only.
- **An urgent job that waits joins the back of the urgent band when it becomes ready**, and a
  retry joins the back of the band again if its last attempt was urgent (a `priority` that took it
  out of the band is kept). Why: the band is first come, first served by when a job became
  runnable, as the queue is. Alternative: keeping its first place in the band (a job that waited
  an hour would jump every urgent job queued meanwhile).
- **A retry resets the pause bookkeeping**: each attempt's run time leaves out its own pauses, and
  a pause ends with the attempt.
- **The ending event of an attempt that will be retried adds `"retrying": true`**, and `job=`
  waits, `wait`, `history` and the lookups in the event log skip it: a job has ended only when its
  last attempt has. `ended` and `failed` still see every attempt's ending; `retry` follows it.
  Alternative: no ending event for an attempt that is retried (the log would not show how each
  attempt ended).
- **`idle` means nothing runs, is queued, waits for dependencies or waits to retry**, since any of
  those will run. `stop --wait` is refused while a waiting job is held, as for a held queued job.
- **`events` and `wait --until` take each new event name as a filter of its own**: `ready`,
  `retry`, `held`, `released`, `paused`, `resumed`, `prioritized`; and `cancelled` is an ending and
  an outcome.

## Local time in `history` and `stats` (branch `local-history`)

**Settled on the user's delegation 2026-11-07.** Review with the user: the fold and gap conventions.

- **`history` prints ENDED in the caller's local zone and `--since` dates are read
  there, the zone being `TZ`, else the host's, as the STARTED column does.** The heading is `ENDED`
  (it was `ENDED (UTC)`); the format is still `YYYY-MM-DD hh:mm:ss`. `--json` is unchanged: `ended_at`
  is an instant in milliseconds. Why: a person reading `ls`, `top` and `history` side by side should
  see one clock, and avin now has zones. Alternatives: keep UTC (the first proposal: the same text on
  every machine, but a different clock from `ls`); print an offset on every row (wide, and still
  two clocks).
- **a `--since` date without an offset is local; a date and minute ending in `Z` or
  `+hh:mm`/`-hh:mm` is taken as that instant.** Why: bare is what a person types, and an explicit
  offset is how a script or a pasted log timestamp stays exact whatever `TZ` is. A date-only form
  takes no offset (`2026-11-07Z` is refused): its offset would be ambiguous with the date's dashes.
  Alternatives: a `Z` for UTC only; no offsets at all.
- **a local reading that occurs twice (clocks going back) is the first occurrence, and one
  that never occurs (clocks going forward) is read with the offset in force before the change,
  so it falls just after the gap.** Why: a `--since` bound must be one instant, and these are the
  usual conventions. Alternative: refuse the date.

## Atomic writes and the step-cache digest (branch `step-cache-sha`)

**Settled on the user's delegation 2026-11-07.** Review with the user: the cache key's length (32 hex digits).

- **A file another process reads is written to a temporary name beside it and renamed into place**
  (`writeAtomic`, `atomic.avin`), so a reader sees the old file or the new one, never half. The
  temporary name is `<file>.tmp-<pid>`, removed if the write or the rename fails. Applied to:
  `state.json` (the restart handover), the pid files inside lock directories (`starting`, the
  take-slot mutex, `land.lock`, a step's build lock), take-slot's units registrations and the
  daemon's ticket. Why those: a reader that gets a torn pid can take it for a dead process and
  remove a live lock, and a torn ticket reads as a one-unit request. Registrations and tickets sit
  in directories whose every entry is a record, so their temporary file lives one level up
  (`.units-<pid>.tmp`, `.ticket-<pid>.tmp`). Alternative: leaving them, since the window is a few
  microseconds (a lock taken over wrongly corrupts a build, and nothing would say why).
- **Left as they are, because no reader can race them**: `report.json` and `report.txt` (written
  by the run's own process at its very end; `marshal report` reads them after the job has ended),
  the failure text in a job's log (the log is a stream readers follow, appended to, never
  replaced), and `config.json` (marshal never writes it; the user does).
- **A compiled step is built as `<name>.building` and renamed to `<name>`**, so the cache name
  holds a whole executable or nothing. A run killed while compiling leaves `.building`, its log
  and the lock; the next one to find the holder dead removes all three. The old takeover removed
  a possibly half-written executable at the cache name; there is none to remove now, and a
  complete one is kept. Alternative: compiling straight to the cache name under the lock (readers
  outside the lock protocol could run a half-written file).
- **The cache key is the first 32 hexadecimal digits (128 bits) of the SHA-256 of the compiler's
  `--version`, a newline and the source text** (`stepKey`), replacing 64-bit FNV-1a. A prefix keeps
  names short; 128 bits of a cryptographic digest do not collide by chance, which 64 bits of a
  non-cryptographic hash were never promised to. Alternatives: the full 64 digits (long names in
  every log line), the first 16 (the old width, with a birthday bound near four billion builds).
  Existing cache entries are simply not found again and rebuilt.

## `top` hides the selection highlight when idle (branch `top-idle-highlight`)

**Settled on the user's delegation 2026-11-07.** Review with the user: the 5 s delay, and the first key only revealing.

- **the selected row's highlight hides after 5 seconds without a key** (`IdleHideMs`),
  and `top` starts with it hidden. Why: `top` is mostly glanced at for progress, and the highlighted
  row reads as something to look at; it matters only when someone is about to act on a job.
  Alternatives: a longer or configurable delay (a knob to document for a cosmetic detail; the
  constant is one line to change), leaving it always on (the request this answers), dimming the
  row instead of hiding it (still draws the eye).
- **the selected job is kept while hidden, and the first selecting key (Up, Down, PgUp,
  PgDn, Home, End, Enter, `l`) only shows the highlight again, without moving or opening.**
  Why: the selection stays where the person left it, and a key pressed blind never moves to a job
  or opens a log they cannot see. Other keys (`q`, `h`, `f`, `k`, `s`, Esc) act at once and count as
  activity: they do not depend on seeing the row. Alternatives: every key only reveals (a `q` that
  needs two presses), the first key also moving (the highlight would reappear on a job the person
  did not choose).
- **the highlight never hides while the log pane, the kill confirmation or the help is
  showing.** Why: there the selection is the subject of what is on screen. When one closes, the
  delay counts from that key. A resize or a snapshot is not activity.
- **the clock is passed in** (`handle(e, now)`, `draw(g, since, now)`, milliseconds) so
  the state can be tested with no sleeps; `MARSHAL_TEST_TOP_IDLE_MS` sets the delay for the
  pseudo-terminal test and is not documented for users. The loop redraws at least once a second,
  so the highlight hides within a second after the delay.

## Retention and `marshal clean` (branch `clean-retention`)

**Settled on the user's delegation 2026-11-07.** Review with the user: the defaults (30d logs, 1000 jobs,
365d events, 30d steps), and that `clean` drops events by the configured age.

- **Only jobs that ended for good are cleaned.** A job counts as ended when its last event in the
  log is an ending that is not a retried attempt, and the daemon holds it as not active. Running,
  queued, waiting, paused and retrying jobs are never touched, whatever the rule. Alternative:
  trusting the daemon's memory alone (a job lost across a crash would never be cleaned).
- **`clean [--older-than <t>] [--keep <n>] [--dry-run]`: a job goes when it is older than `t` and
  not among the `n` newest ended jobs; with neither option, every ended job.** Why: `pueue clean`
  removes all finished jobs, and `--keep` is the safety most users want. Ages need a unit
  (`s m h d w`; a bare number is refused, since `--deadline`'s bare number means minutes and an age
  of "7" would be ambiguous). Options given twice, unknown options and arguments are errors.
  Alternatives: `--keep` and `--older-than` as alternatives (union: surprising, `--keep 5
  --older-than 30d` would remove a young job), a `--all` flag.
- **Removing a job removes `jobs/<id>.log`, `jobs/<id>.sample.txt` and `runs/<id>`, and the daemon
  forgets it** (it leaves `ls` and `top`). Later `wait`, `rerun` and dependency lookups answer from
  the event log, exactly as for a job an earlier daemon ran. No new job field: the end time is read
  from the event log, so the restart handover (`state.json`) is unchanged.
- **Run directories**: removed with their job, or when no job of the log has them and no active job
  does; a directory not named by a job id is left alone.
- **Compiled steps** record when they were last used in `<step>.used` (written atomically at every
  use); one unused for the age goes. Why a sidecar: avin's `fs` had no modification time, and
  access times are unreliable on many mounts. A step with no record (cached before this) is
  stamped by the first clean that sees it, so it ages from then. The age is `--older-than` when
  given, else `keep_steps`. A step being built (its lock exists) stays. **Superseded** by the
  executable's own modification time (see "Avin 0.0.13 calls replace the workarounds").
- **`events.jsonl` is trimmed, not rotated**: every event of an ended job whose ending is older than
  `keep_events` is dropped, rewritten with `writeAtomic` by the daemon (the only appender, so no
  append is lost). The job with the highest id is always kept so ids are never reused. Why: readers
  (`history`, `stats`, `rerun`, dependencies, recovery) keep reading one file and need no change;
  learning reads only each kind's last runs, so a year of history is ample. `rerun` of a job whose
  events are gone is refused ("its command is not in the event log"). Lines that are not events stay.
  Alternatives: rotating to `events.1.jsonl` (every reader must read both and the archive still
  grows), trimming by count. `clean` applies the configured `keep_events`; it has no option for it.
- **Automatic retention** runs in the daemon when it starts (also after `restart`) and every hour
  (`MARSHAL_TEST_SWEEP_MS` shortens it for the tests). Defaults: `keep_logs` 30 days, `keep_jobs`
  1000, `keep_events` 365 days, `keep_steps` 30 days; `"never"` turns one off. Why: a month of logs
  and a year of history are a useful record and small; the default must never surprise by deleting
  what a person looked at this week. Here a job goes when it is older than `keep_logs` OR beyond the
  newest `keep_jobs`. Alternatives: sweeping when each job ends (a rewrite of the log on the hot
  path), no automatic retention (the home grows for ever).

## Avin 0.0.13 calls replace the workarounds (branch `use-avin-0013`)

**Settled on the user's delegation 2026-11-07.** Review with the user: a `touch` or restore of a step
counts as a use. Avin 0.0.13 added `process.groupMembers`, `fs.metadata`/`size`/`modified` and
`fs.setModified`; each replaces something marshal did without them.

- **A job's process group is listed by `process.groupMembers(pgid)`, not `pgrep -g`.** An
  `Err` (or a `pgid` of zero or less) reads as no members, as `pgrep` failing did; a group nobody is
  in is `Ok([])`. Why: no subprocess per second per job, and no dependence on `pgrep`. Alternative:
  keeping `pgrep` (a process spawn for each measurement).
- **The `ps -o pid=,time=` query that picks the busiest process for the deadline's stack
  sample stays.** No avin call gives a process's processor time; the call is only made at a deadline.
  The test helper that reads each process's state letters (`ps -o stat=`, to see `T` for stopped)
  stays for the same reason. Revisit when avin can report either.
- **(Replaces "Compiled steps ... `<step>.used`" above.) A compiled step's use is the
  modification time of its executable.** Compiling sets it (the file is new); every later use calls
  `fs.setModified(program, now)`; a clean ages a step by `fs.modified`. No sidecar file is written or
  read. A `.used` file left by an older marshal is removed by the next clean (and the daemon's
  sweep), whatever the age setting, and is not reported. A step that cannot be stamped or read (it
  vanished, or a dangling link) is skipped. Why: one file instead of two, no atomic write on the
  hot path of every run, and nothing to keep in step with the executable. Alternatives: access
  time (unreliable on `noatime` mounts, and reading a file would change it), keeping the sidecar.
  Cost: anything else that rewrites the executable's mtime (a backup restore, `touch`) looks like a use.
- **`clean` reports the bytes it freed, and `--dry-run` the bytes it would free.** The
  sum of `fs.size` of what goes: job logs and samples, every file under a run directory, a step and
  its build log, plus how much the event log shrank when events were trimmed. Printed as
  `marshal: freed 1.5M` (or `would free`), `roundSize`'s units like the memory columns, `N bytes` under
  1K; the reply and the JSON carry the exact number as `bytes`, which an older daemon's reply omits
  (read as 0). Why: the point of cleaning is the space. Alternatives: only a count of files (says
  nothing about space), `du` of the home before and after (counts what other processes wrote meanwhile).

## The log pane's header (branch `top-log-header`)

**Settled on the user's delegation 2026-11-08**; each says why and what else was weighed. Review
with the user: character wrapping rather than word wrapping, and the header dropped in a pane under
four rows.

- **The log pane in `marshal top` opens with a fixed header of the job's kind and its whole
  command line.** Two labelled lines, `kind` and `command` (labels bold, values dim), then a rule across
  the pane in the pane's colour; the log's lines scroll below the rule and the header stays where it
  is. Why: the table elides both, and a job's log says nothing about what ran. The header's look (bold
  labels, dim values, a rule) differs from a log line's plain text, so it cannot be mistaken for
  something the job printed. Alternatives: the kind and command in the box's title (too long for a
  title, and cut off), printing them as the log's first lines (would scroll away and look like output),
  a separate pane (takes rows from the table).
- **A long command wraps by characters at the pane's width, not at spaces.** The wrapped
  lines have no label and sit under the first, and joined they are the command exactly, which can be
  copied back. Alternative: wrapping at spaces (reads better but a long word still needs a hard cut,
  and the lines no longer join to the original).
- **The header never takes the whole pane.** One row is always kept for the log, so in a
  short pane the command shows as many lines as fit and the last ends in `…`; in a pane too small for
  kind, a command row, rule and a log row (under four rows inside the box) there is no header. The rows the log
  has, and so how many lines top asks the daemon for, are the pane's rows less the header's.
  Alternative: always showing the whole command and letting the log vanish in a small terminal.

## Learned memory reservations and admission by measured memory (branch `mem-admission`)

**Settled on the user's delegation 2026-11-08**; each says why and what else was weighed. Review
with the user: the maximum of the last 10 peaks plus 10% rather than a percentile, and two measured
runs as the least history. The memory budget did nothing in practice: admission counted only `--mem`, nobody
passes it, and two builds peaking at 25–35G each were admitted together on a 64G machine.

- **A job without `--mem` reserves its kind's learned peak: the most of its history key's last 10
  measured peaks, plus 10%, rounded up to a mebibyte.** The history key is the deadline's (kind,
  `+landing` for landing jobs). Why the maximum: memory is not like time, running short costs an
  out-of-memory kill or swapping for every job on the machine, while reserving a little too much
  only delays a start; builds of one kind peak within a narrow band, so the maximum is close to the
  typical case anyway. The 10% covers a peak between two once-a-second measurements. Alternatives:
  the median or p90 (under-reserves on the run that matters), p90 plus a larger margin (needs more
  history to mean anything), an exponentially weighted mean (slow to follow a kind that grew).
- **Every job that ran and was measured is history, whatever its outcome.** A failed or killed
  build held the memory it held; unlike a duration, a failure does not make the figure wrong. A peak
  of 0 (never measured) is not history. Alternative: successful runs only, as deadlines learn
  (would leave a kind that keeps failing unreserved, the very jobs most likely to be rerun at once).
- **Two measured peaks before it applies; none, 0 as before.** One run may be atypical, and two
  costs little when the daemon measures every job. Alternatives: one (learns sooner, but one
  cold-cache or cancelled run sets the reservation), three like deadlines (slower for no gain,
  since the statistic is a maximum).
- **`--mem 0` opts out.** The command line now says whether `--mem` was given (`mem_given` in the
  submit request), and a given memory, 0 among them, is the reservation. A `mem` above 0 counts as
  given whatever the flag says, so an older client's `--mem 29G` keeps its meaning; an older client's
  `--mem 0` reads as not given and learns. Alternatives: a separate `--no-learn` flag (one more
  option for what `--mem 0` already says), a negative size meaning "learn" (a sentinel on the wire).
- **A learned reservation above the whole budget is held to the budget.** It then fits only when
  nothing else holds memory, so the job starts once the machine is free of other jobs and runs
  alone, never waiting for ever and never refused (a given `--mem` above the budget is still
  refused at submit, as before, since the user asked for what cannot be had). Alternatives: refusing
  it (a kind that once peaked high could never run again), ignoring memory for it (runs beside
  others and swaps).
- **A running job counts as holding max(its reservation, its last measured RSS).** Admission adds
  that, per running job, to the waiting job's reservation and compares with the budget. A job that
  holds more than it reserved (no history yet, or `--mem` too small) is counted for what it really
  holds; one holding less keeps its reservation, for the peak it has not reached yet. Alternatives:
  the sum of reservations plus the sum of RSS (counts the same bytes twice), reservations alone (the
  bug), RSS alone (admits a second build before the first has grown).
- **The reservation is fixed at submit and handed over by restart.** Like the deadline, it is
  computed when the job is submitted (state.json carries `reserved` and `reserved_learned`; state
  saved without them is learned again from the event log's peaks). Alternative: recomputing at
  every schedule (a queued job's reservation would move under it as other jobs end).
- **Shown as RESV with `~`** (`~29G`) in `ls` and `top` where learned, and as `resv` /
  `resv_learned` in the JSON beside the declared `mem`; `status`'s `mem` is the reserved total and
  the new `mem_held` the admission figure.
- **The meter in `top` draws reserved memory in cyan and what the running jobs hold beyond it in
  blue**, the text unchanged; with nothing held beyond the reservations it is drawn exactly as
  before. Alternatives: a second bar (costs a header row), RSS alone (hides what is promised).

## Memory reservations learned per kind and directory (branch `mem-per-dir`)

**Settled on the user's delegation 2026-11-10.** Found when a small `sysl test .` suite (kind `test`) sat `queued (no memory)` with a
learned 27.8G, because kind `test` also covers a compiler's full suite peaking near 26G: 34.1G held
plus 27.8G came to more than the 60.1G budget while 20.9G was actually resident.

- **The learned peak is keyed by kind (with `+landing`) and the job's working directory, and falls
  back to the kind's peaks, every directory's, while the directory has fewer than two.** The
  estimate is unchanged: the most of the last 10 peaks plus 10%, rounded up to a mebibyte; `--mem`
  overrides both. Why: the directory is what tells two suites of one kind apart without asking the
  user for a finer kind, and the kind's history is still the best guess for a directory not yet
  seen. Alternatives: the command line as part of the key (`sysl test .` and `sysl test . --fast`
  would learn apart, and an argument that changes every run would never learn); asking users to use
  finer kinds (every caller would have to know; the kind also keys deadlines and `stats`); the
  smaller of the two estimates (under-reserves a big directory's first run after a small one's).
- **Old history still teaches.** Ending events already record `dir`, so a log written before this
  change yields per-directory peaks at once; an event without `dir` teaches its kind only.
- **`status --json` (and every job listing) carries `resv_from`**: `given`, `kind+dir`, `kind` or
  `none`; state.json carries it as `reserved_from`, and state saved without it reads a learned
  reservation as `kind`. Why a word rather than a bool: four cases, and a script can tell `--mem`
  from nothing learned. Alternatives: `memFrom` (the protocol's names are snake case), a
  `resv_dir` bool (cannot say `given` from `none`).
- **`stats` stays per kind.** Its PEAK columns describe the kind across every directory; a row per
  directory would multiply its rows and split its duration statistics, which deadlines still learn
  per kind. Alternative: a `--by-dir` option (left for when someone needs it).

## Every action on a run reaches its step (branch `steps-pause-kill`)

**Settled on the user's delegation 2026-11-08.** Review with the user: the remaining race, in which a
step started but not yet recorded misses one STOP.

- **The runner records the running step's process group in `runs/<job>/step.pgid`, and the daemon
  signals and measures the job's group and that one.** A run-type job's step runs in a group of its
  own (so the runner can stop it on a deadline), which left it outside every signal the daemon sent
  the job's group: `pause` and `resume` did not reach it, `kill` and a deadline relied on the runner
  forwarding TERM (and nothing reached a runner that was itself killed), the KILL after the grace
  period went to the runner's group only, and the memory measurement and the deadline's stack sample
  never saw the step. The file is written whole (`writeAtomic`) when the step starts and removed when
  it ends; the daemon reads it at every signal and at every measurement. Alternatives: the runner
  forwards TERM/STOP/CONT (a stopped runner cannot forward anything, KILL cannot be forwarded, and
  the daemon would still not see the step's memory); the runner reports the pgid over the socket
  (a new request and state in the daemon for what a file says as well); steps kept in the job's group
  (the runner could no longer stop one step without itself, and a step's leftovers would be found by
  the job's TERM at the end only).
- **A file, not a job field.** The record lives under the run directory, so a daemon that took the
  job over in `marshal restart` reads it as the old one did, and `state.json` needs nothing new.
  Alternative: a `step_pgid` job field (needs the handover round trip and a message from the runner).
- **The step group is read at every signal, KILL after the grace period included.** A step started
  after a TERM is still reached by the KILL. TERM of a stop goes to the runner alone, whose handler
  stops its step: a step ended under the runner by the daemon's TERM could be read as a failed step
  (exit 1) before the runner knew it was being stopped. A runner killed hard leaves its record, so the daemon's TERM when the job ends
  (the leftovers rule) ends the step as well.
- **Residual race.** A step the runner has started but not yet recorded when STOP arrives is not
  stopped by that STOP (it is by the next signal, and by every TERM and KILL). Alternative: the
  runner blocks signals around the start and the record (not expressible in avin's process API
  today).
- **The stack sample takes the busiest process of all the job's groups**, so a run's sample is of
  the step's busy process, not of the idle runner.

## Job labels (branch `job-labels`)

**Settled on the user's delegation 2026-11-08.** Review with the user: the 80-character limit and the LABEL column's cap in `top`.

- **A label is free text of 1 to 80 characters, and a longer one is refused, not truncated.** The
  message says the length it had. Why: a silently cut label would no longer be the text the
  submitter chose to find the job by, and `history --label` could not find it again. Alternatives:
  truncate (loses text unseen), no limit (a screenful in one `ls` row).
- **Allowed characters: any printable text, Unicode included; control characters (newline, tab,
  escape, DEL and the C1 range) are refused, and so is a space at either end; an empty label is
  refused.** Why: a label is one line in every listing and a terminal escape in it would act on the
  reader's screen; an empty `--label ""` is more likely a shell mistake than a request for none (a
  job with no label simply omits the option). Alternatives: trim spaces silently, accept empty as
  none.
- **The label is part of the job's spec**, so it rides in `submitted`'s `spec`, every event's job
  fields (hence the ending event `history` reads), the saved state and `rerun`. In JSON the member is
  left out for no label, so nothing written for an unlabelled job differs from before and an old
  reader or file means no label. A label already in the log is read as found, whatever the limits are
  now. Alternative: always write `"label":""` (changes every line of every log).
- **`history --label` and `events` `label=` match a part of the label, case as written.** Why: labels
  are written as `train 209`, `release 0.2.4`, and the useful question is "every train"; an exact
  match would need the whole text. Alternatives: exact match, case-insensitive match (a label's case
  can carry meaning; a user can add a second filter). In an `events` filter `label=` takes the rest of
  the filter text, commas included, so it is written last; otherwise a label with a comma could not
  be searched for.
- **`ls` and `history` get a LABEL column only when some listed job has a label**, so listings of
  unlabelled jobs are byte for byte as before. In `ls` it stands before COMMAND (which is free text
  too and stays last); in `history` it is last. Neither elides: plain output is for reading and for
  pipes. Alternative: a column always (changes every existing listing).
- **`top` draws LABEL before COMMAND only when a shown job has a label and the screen leaves COMMAND
  at least 20 cells**; it is as wide as the longest shown label, at least 5 cells and at most 24, and
  a longer label ends in an ellipsis there. It is dropped on a narrower screen. The log pane's header
  shows the whole label after the kind on the kind's line (`kind    build   label  train 209`), wrapped
  under where it began, never elided, since the column often elides it; the line is the one there
  always was for a job without a label. Alternatives: a fixed column (costs every screen the cells),
  eliding in the header (hides what the column already hides).

## Quiet timeouts (branch `quiet-timeout`)

**Settled on the user's delegation 2026-11-09.** Review with the user: whether a learned per-kind
default is wanted, and whether `stats` should count quiet stops in TIMEOUTS.

- **Log growth is measured by the log file's size, not its mtime.** Any change of size, either way,
  is output and starts the clock again. Why: the size changes exactly when the job writes, and it
  is read with the same `stat` an mtime would be; an mtime has a coarse resolution on some
  filesystems (a second or more), can move without output (`touch`, a backup tool, an editor opening
  the file), and is wall-clock time, which jumps when the clock is set, while the quiet clock is the
  daemon's monotonic one. A job's log is only appended to (a retry appends after the earlier
  attempts), so a write never leaves the size as it was. Alternatives: mtime (above); reading the
  tail of the log for new lines (more I/O for the same answer).
- **The daemon looks once a second, on the tick that already measures memory (`Sample`), not with a
  sleeper per job as the deadline has.** Why: output moves the moment a quiet timeout is due, so a
  sleeper would have to be re-armed on every write, which the daemon only learns of by looking; one
  `stat` per job a second costs nothing. The cost is that a quiet job is stopped up to a second
  after its timeout. Alternatives: a sleeper per job woken to look (the same looking with more
  threads); kqueue/inotify on each log (platform code for a second's precision).
- **The kill is the deadline's: the same sample of the busiest process across the job's and its
  step's groups, then TERM to the job's group and KILL to both after the grace period** (`outOfTime`,
  shared by both). The job's `timedOut` mark is set as for a deadline, so everything that treats a
  job being stopped (kill and pause refused, the deadline's sleeper disarmed, a restart stopping it
  again) does so for both; `quietStopped` says which.
- **The outcome is its own, `{"how":"quiet","after_ms":Q}`, with the ending event `quiet`**, not
  `timeout` with a flag. Why: history, `ls`, `top`, `wait`'s line and events filters
  (`outcome=quiet`) then tell the two apart with no reader needing a second field, and a reader of
  the outcome alone knows the timeout. It exits 124 like a deadline (it is a timeout), and it is
  retried like one under `--retries`. `stats`' TIMEOUTS column still counts deadlines only.
  Alternatives: `timeout` plus `"quiet":true` (every existing reader would read a quiet stop as a
  deadline); exit 125 or another code (125 is a lost job; a script testing for 124 wants both).
- **The job's log ends with `marshal: killed after 10m00s without output (quiet timeout); stack
  sample in …`**, appended when the job's process has ended, so it follows everything the job and
  the runner wrote. The deadline's stop writes nothing into the log, as before.
- **A pause is not quiet: a paused job is not looked at, and `resume` starts its clock again** (from
  the log as it is then), rather than carrying the quiet before the pause over. Why: the job could
  not write while it was stopped, and what it does next after a long pause deserves a whole timeout.
  Alternative: subtract the pause, as the deadline does (lets a job that was nearly quiet when paused
  be stopped a moment after resuming).
- **`marshal restart` starts every running job's clock again; the clock is not saved.** The quiet
  timeout is in the spec, so it rides in the state's `spec` (`quiet_ms`, absent for none), and a stop
  under way is `quiet_stopped` beside `timed_out`, so the new image ends it as `quiet`. Why: the
  new image cannot know whether the job wrote during the handover except by its size, which it reads
  fresh; at worst a hung job lives one quiet timeout longer per restart. Alternatives: save the
  last size and its time on the wall clock (one more pair of fields for a second's accuracy).
- **No quiet timeout by default, and none in a job type's file; `run-type` and `train` take the
  option.** Why: some honest jobs are silent for a long time (a linker, a large compile), so a
  default would kill working jobs. A type's `quiet_timeout` key is a natural follow-up.
- **Considered, not built: a learned quiet timeout per kind**, as deadlines are learned (a multiple
  of the longest silence seen in the kind's successful runs). Why not now: learning it needs the
  longest gap between writes of every successful run, which the daemon would have to record per job
  in the event log first; and a learned quiet timeout would apply to jobs that never asked for one,
  the default this item avoids. Recording `max_quiet_ms` on each ending event is the first step,
  after which `stats` can show it and a learned default can be weighed against real numbers.
- **A parameter may not be named `quiet-timeout` or `label`**, run-type's own options. `label` was
  missing from that list, so a type with a `label` parameter had `--label` taken by run-type itself.

## `marshal grep` (branch `marshal-grep`)

**Settled on the user's delegation 2026-11-09.** Review with the user: the option set. A pattern
that backtracks past the regex budget traps today. That is avin's regex library trapping, and it is
fixed there: the budget becomes a failure the caller sees, and then `grep` exits 2.

- **`grep` reads the log file itself, as `tail` does, and asks the daemon nothing.** Why: a waiting
  agent wants the failures out of a log without reading it all; going through the daemon would add
  a request, a reply size limit and a need for a daemon, for a file the command line can already
  read. It works wherever `tail` does, running and ended jobs alike, and across `restart`.
  Alternatives: a daemon request that searches (the daemon's threads spent on a client's scan; the
  whole result in one reply); piping `tail -n 100000` into the system `grep` (needs the log read
  whole by `tail`, and no system `grep` option knows a job id).
- **The log is streamed a line at a time; only leading context is kept.** The state held is the
  last `-B` lines, never the log, so a log of gigabytes is searched in the same small space, and
  `-m` stops reading at once. Alternative: `readText` and split (simple, but holds the whole log).
- **The set is `-i -v -n -c -F -m -A -B -C --last`, and nothing more.** Short options are not
  combined (`-in` is not `-i -n`), `-e` and `-f` do not exist (one pattern, given after the id) and
  `-r` is meaningless for one file. Why: each is one word to read and to test; combining adds a
  parsing mode for a few keystrokes. `--` ends the options so a pattern may begin with `-`.
  Alternative: grep's full set (a long tail nobody waiting on a job uses).
- **Exit codes are grep's: 0 a line matched, 1 none did, 2 an error.** Why: `marshal grep id x &&
  …` reads as grep does. Marshal's own failures already exit 2 (`Trouble`), so nothing new is
  borrowed; a job's status is not involved. `-c` exits by the count too: 1 for a count of 0.
  An unknown job and a job with no log yet are the same error, `job N has no log`, because without
  a daemon the log's absence is all that is known; a queued job that has not started has none.
- **`-i` is `(?iu)`: Unicode's simple case mapping, not ASCII only.** Why: a log may hold any
  text, and `-i` that folds `e` but not `é` surprises. Alternative: plain `(?i)` (ASCII only, per
  the regex spec).
- **`-F` quotes the pattern with `Regex.quote` and goes through the same matcher**, so `-F -i`
  works and there is one code path. Alternative: a substring search (a second matcher for `-i`).
- **A pattern is found anywhere in the line** (an unanchored search), as grep does, not
  anchored to the whole line as `Regex.matches` is.
- **`-m N` still prints the trailing context of the last match**, as grep does; a line inside it
  that would match is context there and is not counted. `-m 0` reads nothing and exits 1.
  `-c` with `-m` counts up to the limit.
- **With `-c`, context options are accepted and have no effect.** `-n` also does nothing with `-c`.
  Alternative: refuse the combination (an error where grep prints a count).
- **`--last N` is two passes: one counts the lines, the second skips to the last N, so `-n` still
  gives the log's own line numbers.** Why: numbers that restart at 1 would not point into the log
  (`tail -n` and `grep -n` side by side would disagree). Cost: the file is read twice, still in
  constant space; for a running job lines written between the passes are searched too. Alternative:
  reading the end with `readTailLines` (one pass, but it holds N lines and cannot number them).
  Context before the first line searched is not printed: it is outside the window.
- **A final line with no newline is a line, as is a half-written one in a running job's log; a
  `\r` before the `\n` is dropped; bytes that are not UTF-8 read as U+FFFD.** All as the library's
  `readLine` does.
- **A pattern that exhausts the regex library's step budget is an error, exit 2** (superseded the
  earlier trap; see "Regex budget" below).

## The landing job's units on top's units line (branch `top-tui020`)

**Settled on the user's delegation 2026-11-09** (the request was the user's).

- **While a landing job runs, top's units line ends with `   landing N`, its units, in the landing
  job's cyan.** `0 + take-slot 0 / 12   landing 1`, or `0 / 12   landing 1` with nothing shared. Why:
  the landing lane sits outside the unit budget, so a landing job's units are in neither the bar nor
  the count, and a machine busy with one landing job read as idle on that line. They stay outside the
  `/ 12` and off the bar, which both describe the budget. Alternatives: counting them into the bar in a
  third colour (would read as part of the budget, and could overfill it), or only the header's
  `landing: job 7 (1 unit)` (already there, but on another line from the units it explains).
- **Nothing is added while no landing job runs**: a lane held by take-slot holds units take-slot
  already reports, and a lane whose job is not among the running ones has no units to show.
- **Where the whole of `   landing N` does not fit on the screen it is left out**, not cut. Why: a cut
  `landi…` or a bare `landing` without the number says less than nothing, and the header's first
  line still names the landing job. Alternative: cutting with `…`.

## `ls` and `status --json` say why a queued job waits

**Settled on the user's delegation 2026-11-09** (the request was the user's). Review with the user:
the reason in the state cell rather than a column.

- **In `ls` the reason follows `queued` in the state cell** (`queued (draining)`,
  `queued (behind 405)`), in the words `top` uses; running and ended rows are unchanged. Why: no new
  column, so nothing moves for listings without queued jobs. Alternatives: a WHY column (shifts every
  row's alignment whenever one job is queued, as LABEL does), or `top`'s `#position reason` (the
  position is not in `ls`'s order).
- **A job held by hand shows plain `held`, with no reason after it.** Why: the cell already
  says it. In `status --json` its `why` is `held`.
- **`status --json` adds `why` (the protocol word) and, for `behind`, `behind` (the id) to
  each queued job**, the encoding `snapshot` uses, minus `position`. Why: scripts can reuse the
  protocol's words. Alternative: `position` and `waits` as the snapshot has them (a second name for
  the same thing).
- **The command line reads the reasons with a second request, `snapshot`, only when some
  listed job is queued.** The reasons come from the one scheduler function `top` uses. Why: `ls` keeps
  its reply and its recent-jobs window. A job that starts between the two requests has no reason and
  lists as it is. Alternative: `ls` reply carrying the reasons (one atomic reply, but a new reply
  shape for every client of `ls`).

## `top`'s LABEL column is sized by display width

**Settled by the user 2026-11-09.**

- **`top` draws LABEL as a tui `Column` with `fit`, `min` 5 (its heading), `max` 24, with COMMAND
  `keep` 20, and the table sizes and cuts it, with `…`.** The width is measured in display cells, so a
  double-width character counts 2; the longest label drawn sets the column, and a screen that would
  leave COMMAND under 20 cells, or where no drawn job has a label, leaves it out. Why: the
  hand-rolled sizing counted characters, so a wide-character label overran its column and shifted
  the ones after it. Alternative: keeping `labelWidth` and counting display width by hand (a second
  copy of what the table already does).

## A pause that holds, and a restart that keeps its socket (branch `restart-flakes`)

**Settled on the user's delegation 2026-11-10.**

- **A paused job's groups are stopped again 10, 50 and 200 ms after the pause, at every sample
  (each second) while it stays paused, and at once by a restarted image.** Why: on macOS a STOP sent
  to a group misses a process that is between fork and exec as it arrives, so a job paused just
  after it started, or while its shell starts a command, ran on with `pause` having answered that it
  was paused. Sending STOP again does nothing to a stopped process and stops one that was missed or
  continued by hand. Alternatives: checking each member's state after the STOP (no portable call
  answers it, and `ps` per pause is a process per check), or refusing a pause until the job has run
  a moment (a job's shell forks for the whole of its life, so it narrows the window without closing
  it).
- **A restarted image takes over its socket's path, removing whatever is there, rather than asking
  whether a listener answers.** Why: a child the old image was starting, forked but not yet running
  its program, holds a copy of the old listener until it does, so under load the new image found
  the path answered, took it for another daemon, and exited, losing its jobs. The image that
  restarts is the daemon: the `starting` lock and its pid keep any other from starting meanwhile.
  Alternative: waiting in the old image for no start to be in flight before it execs (a start can
  be begun by any thread, and a missed one still loses everything).
- **`restart` asks the restarted daemon again when a connection closes unanswered,** until the
  usual 30 s. Why: a connection made in the same moment reaches the old listener's copy and is
  closed when that child's program starts; every other command already asks again this way.

## The LABEL column always shows

**Settled by the user 2026-11-10.** Replaces "only when some listed job has a label" in the label
entries above, and the clause of the entry just above that leaves the column out where no drawn job
has a label.

- **`ls`, `history` and `top`'s job table always have the LABEL column, with an empty cell for a job
  without a label.** Its place, heading and width and cut rules are unchanged (`ls` before COMMAND,
  `history` last, `top` as a fit column of 5 to 24 cells that a screen too narrow to leave COMMAND 20
  cells still drops). Why: a column that comes and goes shifts every other column the moment the
  first labelled job appears, and a reader cannot tell "no label" from "no such column". In `top` the
  column keeps its heading's width when every cell is empty (tui 0.2.2). `status --json` and the events are unchanged:
  they still leave `label` out for a job without one. Alternative: the old rule (listings of
  unlabelled jobs stayed byte for byte as before).

## ELAPSED counts from the start

**Settled by the user 2026-11-10.** Replaces "the time queued for a waiting or queued job" in the
ELAPSED entries above.

- **ELAPSED (`ls`, `top`) and `elapsed_ms` count from when the job started, and are `-` (0 in
  JSON) for a job that has not started: queued, held, waiting for `--after` jobs, or waiting to
  retry.** A running job's is its run time with its pauses left out, a paused job's stands still and
  an ended job's is its run time, all as before. Why: a queue wait ticking in the column that
  otherwise means "how long has it been going" made a long-queued job look long-running.
- **Settled on the user's delegation 2026-11-10: the wait is not lost.** It stays in the job's `queued_ms` (which already carried it, and
  stays in `ls --json`/`status --json`), and the STATE cell already says why it waits. `ls` and `top`
  show no wait time of their own. Alternative: a WAITED column or a figure in the STATE text (more
  width on every row for a number most jobs have no use for).

## Regex budget in `marshal grep` (branch `grep-exit2`)

**Settled on the user's delegation 2026-11-10.**

- **A line on which the pattern spends the regex step budget ends the whole search with exit 2.**
  The message on stderr is `marshal: grep: line N: pattern `P` backtracked too far …`; lines already
  printed stand, `-c` prints no count, and no later line is read. Why: a count or a match list
  that silently skipped a line would be wrong in a way the caller cannot see, and GNU grep ends a
  search the same way when its matcher gives up. Alternatives: skip the line, say so, and go on
  to exit 2 at the end (more output, still a partial answer); treat the line as not matching
  (a wrong answer with exit 0 or 1).
- **The test is avin's `tryMatches`**, so the budget is a value the search sees, not a trap.

## Jobs whose work runs outside their processes (branch `external-mem`)

**Settled on the user's delegation 2026-11-10.** Found running Linux checks in Docker under marshal: `docker run` leaves only the
small docker client in the job's tree, and the work runs in Docker Desktop's VM, under another
account, so marshal learned a near-zero peak and reserved almost nothing.

- **`--external` declares that a job's work runs outside its own process tree.** Such a job
  reserves exactly its `--mem`, is held at that by admission whatever its tree measures, and its
  peak is never learned: the daemon does not remember it, and a daemon recovering from the event
  log skips an ending event marked `"external": true` (`stats` leaves its peak out too). Its run
  time still teaches its kind's deadline, since how long it took is real. Why: a measurement of the
  wrong processes is worse than none; one external run would otherwise pull its kind's learned
  reservation down for every later job of the kind. Alternatives: `--mem-only` or `--unmeasured`
  (name the mechanism rather than the reason; `--external` says what the submitter knows);
  excluding the job's peak only when it looks small (a guess); reading the Docker VM's RSS (out of
  scope: the VM's memory is reserved up front for the whole VM and is not per job, so it says
  nothing about one container).
- **`--external` without `--mem` is refused**, by the command line and by the daemon (a raw
  `submit` with `"external": true` and no `mem_given`/`mem`), with a message saying the work runs
  outside the job's processes so marshal can neither measure nor learn it. `--mem 0` is accepted:
  it is an explicit choice to reserve nothing. Why: an external job has no other source for its
  reservation. Alternative: defaulting to the kind's learned peak (learned from other, non-external
  jobs of the kind, or from nothing).
- **`ls` and `top` show its RESV with `@` before it (`@29G`); `status --json` and every event
  carry `"external": true`, absent for other jobs; `rerun` and `marshal restart` keep it.** Why: one
  character fits `top`'s 6-cell RESV column beside `~` (learned), so no column moves. Alternatives:
  `29G ext` (as the request suggested; does not fit `top`'s column without widening it for every
  job), a separate flag column.
- **A command that plainly runs its work in a container engine, submitted without `--external`,
  gets a warning on stderr, and is submitted all the same.** It is the first word, or the first
  after a leading `sudo`, being `docker` (or a path ending in `/docker`) with `run`, `compose`,
  `build` or `buildx` after it, or `docker-compose`. `dockerize` and `echo docker run` do not count.
  Why: the warning catches the common mistake without second-guessing a submitter who knows better
  (a `docker build` with a tiny context, a remote engine). Alternatives: refusing (blocks legitimate
  uses), marking such jobs external automatically (they still need a `--mem`, so it would turn into
  a refusal), no detection (the mistake is silent until the budget is overcommitted); recognising
  podman, nerdctl and the rest (left until someone needs them).

## Another account's work goes through your own marshal (branch `external-mem`)

**Settled on the user's delegation 2026-11-10.** Another account cannot submit: `~/.marshal/sock` is its owner's, under a home others
cannot enter.

- **The socket stays its owner's alone.** Work that must run as another account (a Docker Desktop
  or a Homebrew owned by another user) is submitted to the owner's marshal as
  `marshal run --external --mem <size> -- sudo -n -u <account> -H <command>`, with a sudoers rule
  that names exactly that command; the README says so. Why: an account that can submit to a daemon
  can make it run any command as the daemon's owner, so opening the socket crosses a privilege
  boundary, while a sudoers rule grants one command and nothing more. Alternatives: a group-readable
  socket in a shared directory (the privilege hole above); a second daemon under the other account
  (two budgets, each admitting jobs as if the machine were its own: the overcommitment marshal
  exists to prevent); a daemon that runs jobs as the account that submitted them (needs root).

## `stats` sizes both peak columns with the rounded formatter (branch `stats-units`)

**Settled on the user's delegation 2026-11-10.**

- **PEAK P50 and PEAK MAX in `stats` use `roundSize`, the formatter `top` uses for PEAK.** Why: they
  used `formatSize`, which shows a size in the largest unit that divides it exactly, so a measured
  peak (never a round number) printed as raw kilobytes (`7320688K`) while another in the same row
  printed `9903M`. A measurement is shown rounded, one decimal under ten of a unit (`7.0G`, `756M`).
  `--json` is unchanged: `peak_p50`, `peak_max`, `peak_rss` and `rss` are bytes, now said in
  protocol.md. Alternatives: renaming the JSON keys with a `_bytes` suffix (breaks readers for a
  clearer name); keeping `formatSize` and rounding the peaks to a mebibyte first (a second rounding
  rule beside `roundSize`).

## The quick lane (branch `quick-lane`)

The request was the user's: a 20-second test sat queued for more than five minutes behind
20-minute builds, waiting for units like everything else.

**Settled by the user 2026-11-10:**

- **A quick job waits when its reservation does not fit in the budget's free memory**, as any job
  does (reason `memory`). Why: a quick job must not push the machine into swap; the lane is about
  units, not memory.
- **A running quick job's reservation counts against the memory budget**, so a development job (or
  a landing job) may wait for it. Why: the memory it uses is in use, however briefly.

**Settled on the user's delegation 2026-11-10:**

- **`--quick` on `submit`, `run`, `run-type` and `train`; the job starts outside the unit budget,
  as a landing job does, and is niced like a development job.** The scheduler decides the quick lane
  after the landing lane and before the development jobs, so it never delays a landing job (a
  landing job that drains the machine holds the quick lane as well) and goes ahead of development
  jobs. Take-slot is told it holds 0 units. Why: the delay was all units; a quick job is short by
  definition, so letting it beside the unit budget costs the long jobs little.
- **Two constants in quick.avin: `QuickSlots` 2 and `QuickCapMs` 2 minutes.** A quick job's deadline
  is the cap, or a shorter `--deadline`; a longer one is refused by the daemon with a message saying
  to drop `--quick`. A run-type's own deadline over the cap gives way to the cap. Past it, the job is
  stopped as any job past its deadline (outcome `timeout`). `--quick` with `--landing` is refused.
  Why: the cap is what keeps the lane quick, and two slots bound how far past the unit budget the
  lane can take the machine. Alternative: configurable values in the config (deferred until
  someone needs another number).
- **A third quick job waits in the quick lane (`quick-lane`, shown `quick lane full`), in queue
  order; the first quick job that waits for memory keeps that memory from development jobs, and the
  quick jobs behind it wait behind it.** Why: otherwise a stream of development jobs could take the
  memory a quick job waits for, and it would starve. Alternative: letting development jobs use the
  memory (fairer to them, but a quick job could wait indefinitely).
- **The hint**: when a job is submitted without `--quick` (and not `--landing`) and its kind's last
  `window` successful runs (at least `minRuns`, as learned deadlines use) took under the cap at the
  90th percentile, the daemon puts a one-line hint in the submit reply (`hint`) and the command line
  prints it on stderr. Why: the daemon already holds the durations; the command line would have to
  read the whole event log. Alternative: computing it in the command line from `events.jsonl` (no
  protocol change, but a full read on every submit).
- **Markers**: `ls` and `top` mark a quick job's kind `^` (a landing job's is `*`); `top` says
  `quick` for a running one and `quick: n/2` in its header while one runs; `status` names the lane
  only while one runs; the job JSON carries `"quick":true` only for a quick job, and `status` /
  `snapshot` carry `quick` (running quick jobs), `status --json` also `quick_slots`. Why: nothing
  changes for anyone not using the lane.
- **Alternatives weighed for the lane itself:**
  - *Auto-promotion by learned duration* (a job whose kind is known to be short goes quick on its
    own): rejected for now; a kind's history does not know this run (a test of a large package has
    the same kind), and a wrong promotion is killed at the cap. The hint offers it instead.
  - *A separate small unit pool* (say 2 units reserved for short jobs): reserved units sit idle when
    no short job comes, and a short job still waits when the pool is busy; the lane costs nothing
    while unused.
  - *Preemption* (pausing a long job to run a short one): a paused job keeps its memory, so it frees
    nothing the short job needs but CPU, and pausing a tool mid-write is unsafe for some; niced quick
    jobs beside the budget get the same effect.

## `top` scrolls back through every ended job (branch `top-history`)

The request was the user's: top's job list could not go back past the ten ended jobs the snapshot
carries.

**Settled on the user's delegation 2026-11-11:**

- **Where the earlier jobs come from: top reads `events.jsonl` itself**, as `marshal history` does
  (each job as its last ending event describes it, a retried attempt skipped, ordered by when it
  ended and then by id). Why: top already reads job logs from their files, so it is a client on the
  daemon's machine and home by design; `history` never asks the daemon; the daemon, which serves
  every job, is not made to read a growing log on a viewer's keypress; and there is no protocol
  change, so a top against an older daemon still scrolls back. Alternative: a `history` request with
  `before`/`limit` answered by the daemon (usable by other clients, but the daemon pays the read,
  and a new request an older daemon refuses).
- **Read once, paged from memory**: the first page reads the whole log and keeps its ended jobs;
  later pages are slices of it. Jobs that end after that come in the snapshots, so the pages before
  them never change. The read is synchronous: `marshal history --limit 5000`, which parses the same
  lines the same way, takes 75 ms on this machine's 5.4 MB, 1,057-job log. Alternatives: reading
  the log again per page (75 ms per page and growing), or a reader thread (no visible pause on a
  far larger log, but state shared with the drawing loop for a pause not yet seen).
- **A page is 100 jobs**, loaded when Down or PgDn is pressed on the last line, the selection put on
  the first job loaded (PgDn too, so a page never skips past jobs the user has not seen). A page whose
  jobs are all already listed is followed by the next. Why: a few screens per load, and every line
  is drawn each frame, so loading only what is scrolled to keeps the frame cheap.
- **End loads every page and goes to the very oldest job**, rather than jumping to the oldest page
  and leaving a hole. Why: End means the bottom of the list, and the list stays one contiguous
  sequence. Cost: on a log of tens of thousands of jobs every line is in the table afterwards.
- **The pages stay through every snapshot until the filter changes.** Once a page is loaded, a job
  that drops out of the snapshot's ten joins the loaded jobs, so the list has no hole; the selection
  stays on its job as before. Without pages loaded nothing changes from before. The running and
  queued filters list no ended jobs and load none; changing the filter drops the pages, as the
  request asked. Alternative: keeping pages across filters (cheaper to come back, but the request
  named the filter change as the end).
- **The position on the bottom line**: `jobs 41–60 of 1,234` at the right end, dim, where it fits
  beside the keys (a message is cut before it); shown while the lines overflow the table or earlier
  jobs may be loaded, so a table that fits with nothing more to load looks as before. `+` follows the
  count until the first page says how many are left; after it the count is exact. Alternative: in
  the header beside the filter (the header is full on a narrow screen).
- **The scroll bar** is tui 0.2.3's `Table.scrollbar`, on for the job table; it measures the lines
  loaded, while the position counts the whole history. It is not on for the log pane: the pane is
  given only the last lines it shows plus how far it is scrolled back, not the whole log, so a bar
  there would size its thumb against the lines read rather than the log.
- **An unreadable log** says `cannot read earlier jobs: <why>` on the bottom line, loads nothing,
  and is tried again on the next key.

## `wait <id> --timeout` (branch `wait-timeout`)

**Settled on the user's delegation 2026-11-11:**

- **`wait <id>` takes `--timeout <t>` before or after the id.** The help already listed it. When the
  job has not ended by then the command prints `marshal: timed out after <t> waiting for job <id>` and
  exits 124, as `wait --until` does; the job is left running. A job that ends first gives its own
  status, as before. Why: one exit code for "gave up waiting" across both forms. Alternative: a new
  code for the id form (a script would need to know which form it called).
- **`--since` is refused with an id** (`--since goes with wait --until, not with a job id`) rather than
  ignored. Why: a job id's wait is already answered at once for a job that has ended, so there is no
  past for `--since` to look back into; accepting it silently would suggest it did something.
  Alternative: ignoring it (a typo would pass unnoticed).
- **The timer runs for the whole command**, so a daemon that has to be started counts against it.

## `top` stays at the top as jobs arrive (branch `watch-scroll`)

**Settled on the user's delegation 2026-11-11:**

- **A table whose selection is on the first line keeps it there across snapshots.** Before, the
  selection followed its job's id, so each new job above it pushed the selected row down and the
  table scrolled to keep it visible: left open for hours, the running jobs crept out of view. Now a
  flag is set at the start and whenever a key (Home, Up, a filter change) leaves the selection on the
  first line, and cleared by any key that moves it elsewhere; while set, a snapshot leaves row 0
  selected, so the newest and running rows stay visible. Why: it needs no clock, and idle time alone
  would not tell a user parked on a job from one who never touched it. Alternatives: returning to the
  top once the highlight has hidden (the view would jump under a user who is reading a row); keeping
  the selected job on screen only while the highlight shows.
- **A user who moved the selection down keeps their job**, as before, including a job that ends and
  moves into the ended section and a job in loaded earlier pages. A filter change keeps the selected
  job where the new filter lists it, and follows the top if that is row 0. The look is unchanged.

## Waiting is bounded: the machine drains for a job that has waited too long (branch `no-starve`)

**Settled on the user's delegation 2026-11-11.** The bug: a 12-unit job waited indefinitely, `queued (no units)`, while urgent jobs
submitted after it started one after another; each took a unit or four as others ended, so the
units never all came free at once. The urgent band and priorities put later jobs ahead by design;
the unbounded wait was not.

- **The bound is a time, `drain_after` in `config.json`, 10 minutes by default (`"never"` turns it
  off).** Once the first development job in queue order has waited that long since it queued, it goes
  ahead of every other development job, urgent ones included. If it fits, it starts and nothing else
  changes. If not, the machine drains for it: no other development job starts until it has started,
  except as backfill (the next section). Why time: it is what the user notices, is the same for a 1-unit and a 12-unit
  job, and survives `restart` with no new state (a job's arrival is already kept). Alternatives: a
  count of times passed over (needs a new counter kept across restarts, and "passed" is ill-defined
  when several jobs start in one look); a bound proportional to the job's deadline (a long job would
  wait longer to start, the opposite of what it needs; a learned deadline also moves); dropping
  backfill only (does not help: urgent jobs are not backfill, they are ahead in the queue).
- **Which job: the first in queue order past the bound**, so among several the urgent band and
  priorities still decide, and a job that queued earlier but sits further back (a lower priority)
  is bounded too. Two big jobs past the bound drain one after the other.
- **The wait is counted from when the job last queued** (`arrived`: submitted, ready after its
  `--after` jobs, or a retry). A job held by hand counts the time it was held; once released it may
  drain at once. Alternative: not counting held time (a new field; holding is rare and deliberate).
- **The landing lane and the quick lane go on beside a draining job.** A landing job (a train) takes
  the landing lane, which is outside the unit budget: it never holds the units the draining job waits
  for, so starting it delays nothing, and everyone waits on the train. Quick jobs are outside the
  budget too, at most 2 and 2 minutes each. Both still count memory, so a draining job short of
  memory can be delayed by them; that wait is bounded by the lanes' own limits (one train, two short
  quick jobs at a time). Alternative: holding them too (would stall landings behind a benchmark, and
  a train's reserved lane exists so that it is never stalled by development work).
- **`ls` and `top` say why.** The draining job shows `queued (draining)`, the word a landing job
  short of memory already uses for "nothing else starts until I do"; each development job it holds
  back shows `queued (draining for 1567)`. The protocol word is `draining-for`, with the job's id in
  `draining_for`, as `behind` carries `behind`. A job the drain makes wait for take-slot still says
  `take-slot`. Nothing else in either view changes.
- **Deadlines are untouched: a job's deadline counts from its start**, so an urgent job held by a
  drain loses none of it, however long it waited. The hold is never silent (`draining for N`), and it
  is bounded by the running jobs' own deadlines, since the draining job starts once they end. A
  `marshal wait --timeout` on a held job times out as it would for any queued one.
- **take-slot**: while a job drains, the daemon's ticket is that job's, at its own arrival, so
  take-slot runs that came after it wait; take-slot waiters that came before it keep their place.
  Alternative: the ticket ahead of every take-slot waiter, as a draining landing job takes (would let
  a late development job jump take-slot runs that waited longer).
- **Killing the draining job releases the hold at once**: the next look finds the next job past
  the bound, if any.

## An urgent job's kind is marked `!` (branch `urgent-mark`)

**Settled on the user's delegation 2026-11-11.**

- **Urgency is a kind suffix, not a state**: `test!`, as `*` marks landing and `^` quick. Why:
  urgency is where a job stands in the queue and it stays on the job while it runs and after it
  ends; the STATE column already says where a queued job waits and why, and a job that runs has no
  state left to carry it. Alternative: a state word (`urgent` in place of `queued`), which would
  hide the reason it waits and say nothing once it runs.
- **The marks combine, in a fixed order: the lane's, then `!`** (`test^!`, `test*!`). Why: urgent
  joins the urgent band of the job's own lane, and `submit` refuses only quick with landing, so
  quick+urgent and landing+urgent are both legal jobs; a job is never both quick and landing, so at
  most one lane mark precedes the `!`. Alternative: `!` instead of the lane mark, which would hide
  which lane a job runs in.
- **Everywhere the kind is shown**: `ls`, `top` (live rows and the earlier ones scrolled back to) and
  `history` use one function. `history` reads `urgent` and `quick` from the ended job's event; it did
  not show `^` for a quick job before, and now does, as `ls` and `top` do. The job JSON already
  carries `urgent`; no JSON spells the suffix.
- **A kind too long for `top`'s 8-cell KIND column is cut in its NAME, and the marks stay whole
  after the ellipsis** (`avin-g…*`, `funl-t…!`, `test-s…^!`), where the table's own cut at the right
  edge used to drop them (`avin-ga…`). Only a column narrower than the ellipsis and the marks cuts
  the marks, from the right (`…^!`, `…^`, `…`). `ls` pads its columns to the widest cell and never
  cuts, so its kinds are always whole. Why: the mark says how the job is treated, and the name is
  what can be spared. Alternative: widen the column to the longest marked kind, which moves every
  other column.
- **The mark follows the band**: `priority <id> --urgent` adds `!`; a number removes it; a job
  submitted `--urgent` keeps it to the end.

## A drain backfills (branch `drain-backfill`)

**Settled on the user's delegation 2026-11-11.** The bug (user, on 0.2.10): one 1-unit build ran with most of an hour to its deadline,
a 12-unit job drained for it, and seven 2–4-unit jobs waited `draining for` it on 11 idle units.
"If it's draining, then shouldn't it let queued jobs run if they can".

- **The drained job's expected start** is when enough running jobs are expected to have ended for
  it to fit (units and memory both). Each running job is counted by its kind's **learned** duration
  (the median `expected_ms`), or by its **deadline** when too few runs are known: the guess used
  elsewhere (half the default deadline) is not good enough to promise a drained job anything, and
  a deadline is a bound marshal enforces. Whether the duration was learned is a new job field,
  `duration_learned`, kept across `restart` (absent reads as not learned, the cautious side).
- **A job backfills** when it fits now and either (a) it too is expected to end by then, counted the
  same way, or (b) it takes only units and memory the drained job will leave spare at its expected
  start (0 when it needs the whole machine), whatever its length. Candidates are taken in queue
  order (urgent first), as before; one that may not start does not block those behind it. This is
  EASY backfilling, the rule the queue already uses for a blocked head, now applied to the drain.
- **Overrun is accepted, and bounded.** A learned duration is a median, so a backfilled job will
  sometimes run past it. A running job past its estimate is expected at any moment, so once the
  drain waits on it the expected start is "now", and nothing further backfills: the drained job is
  delayed by at most that one job's overrun, which its own deadline bounds, and delays never stack.
  A job of an unlearned kind is counted by its deadline and so can never overrun into the drain.
  Alternatives: backfilling only with a margin (e.g. twice the median; halves the idle units
  recovered for a risk already bounded by the deadline), only kinds with a learned duration (the
  screenshot's jobs would have run anyway by their deadlines, and the deadline form is exact), or
  only by deadlines (safe, but a learned 5-minute test with a 40-minute deadline would never fit).
  Revisit if drains are seen to run late.
- **Nothing backfills ahead of a drained job that waits for take-slot**, as nothing overtakes a
  job waiting on take-slot's runs elsewhere: they may end at any moment.
- **It says so.** A backfilled job's log begins `marshal: backfilled ahead of <id>`, and its
  `started` event adds `backfilled_ahead_of`. The jobs still held keep `draining for <id>`; `ls` and
  `top` are otherwise unchanged (no new column).

## A job running before the drain counts by its deadline once past its estimate (branch `backfill-live`)

**Settled on the user's delegation 2026-11-11.** The bug (user, live on 0.2.11): 4 of 12 units free, a 12-unit job draining, and a
1-unit 40-minute build and a 4-unit 30-minute test waiting `draining for` it while the one job
holding the drain had two hours to its deadline. Cause: that job, an avin gate, had run past its
learned median (13 minutes), and the other running job, a test backfilled earlier, past its own (25
seconds). "A running job past its estimate is expected at any moment" made the drain's expected
start *now*, and nothing backfills ahead of a drain expected now. A median is passed by half of all
runs, so this stopped backfill on most drains, not only after an overrun. take-slot was idle and
not the cause.

- **A job that was already running when the drain began** (the job waited past `drain_after`) and
  has passed its estimate is counted by its **deadline** (with time paused added), the latest it can
  end: past the median nothing learned predicts it any more, and the deadline is the bound used for
  a kind with nothing learned. A deadline already passed counts as now (the job is being stopped).
- **A job started since the drain began** (one backfilled ahead of it, or a landing or quick job)
  and past its estimate is still expected at any moment, so the overrun rule keeps its purpose: an
  overrun delays the drain by at most that job's own deadline, and delays never stack, since the
  window for more backfill is fixed by deadlines of jobs older than the drain.
- **The cost**: when the old job ends early, the drained job may wait for jobs backfilled into a
  window as long as the old job's deadline. That is what backfill trades in every case; jobs that
  end as expected leave the drain starting no later than the old job's deadline.
- Alternatives: keep "past its estimate is expected now" (the bug); count an overdue job by twice
  its elapsed time or some quantile (no basis in what marshal enforces, and a promise to the drained
  job it cannot keep); mark backfilled jobs in the job's state (needs a persisted field; the start
  time against the drain's start says the same, stateless, and a restart keeps both).
- **The blocked head's rule before the bound is unchanged**: a running job past its estimate still
  stops backfill behind an ordinary head, since that head is not promised a start; once it has
  waited `drain_after`, the drain's rule above applies to it.
- **The daemon decides again every 3 seconds whatever take-slot is.** The ticker ran only where a
  take-slot directory was shared, so without one nothing reconsidered the queue as time passed (a job
  passing its estimate or its wait bound) until some job came or went.
- **`expected_ms`, `duration_learned`** are now on every job in `status --json`, the snapshot and
  events, and **`expected_start_at`** (wall-clock ms) on the job the machine drains for, so a drain
  can be read from outside. `ls`'s why-line is unchanged: a time would change its look.

## A typed job runs from its own copy of marshal and its type (branch `stable-step-path`)

**Settled on the user's delegation 2026-11-11.**

- **`run-type` copies what the run reads into `<home>/typed/<name>` and submits the job against the copy.** The job's command was marshal's own resolved path and the type file's, and `run-steps` resolves `stock:` steps from its own executable's directory at each step, so an upgrade that removes an installation (Homebrew deletes the old Cellar version) failed a running job at its next stock step and a queued job at its start. The copy holds `bin/marshal` (a hard link of the executable: no space, and the job runs the marshal it was submitted with), `share/marshal/steps` (marshal's stock steps, as an installation lays them out, so `MARSHAL_STOCK` for the job names it), and `type/<type>.job` with each literal `avin:<path>` step it names at its relative path. A queued job submitted before an upgrade starts correctly after it, and runs the type as it was submitted.
- **Where the copy cannot be made** (a step path with `..`, a `${}` reference or a missing source; no free disk) the job is submitted as before, from the installed files, with a note on stderr. Where only the hard link fails (another file system) the job runs the installed program through its stable path: Homebrew's `<prefix>/opt/<name>` for a path in `<prefix>/Cellar/<name>/<version>`, else the path itself, so a development build works unchanged.
- **The copy stays until the retention sweep**, which removes `typed/*` older than the step age (30 days by default, or `clean --older-than`), because `rerun` submits the same command. It is reported with the run directories. A copy cannot be tied to the job's run directory: the job id is not known when the command is built.
- Alternatives: only a stable path (Homebrew's `opt/marshal`; fixes brew but not other installs, and a queued job would run a newer marshal and type than it was submitted with); the runner moving the copy into the run directory at start (breaks `rerun`, and the executable's path then names the old place); copying the executable (35 MB a job); `avin:` steps that reach outside the type file's directory (cannot be placed relative to a copy without rewriting the file).

## Exclusive jobs, for benchmarks (branch `exclusive`)

**Settled by the user 2026-11-12** (the design): `marshal run --exclusive` starts a job only when no
marshal job runs in any lane, and nothing else starts while it runs; it never pauses or kills a
running job; `--quiet-load <n>` also waits for the one-minute load average to stay below `n` for a
minute; while it runs its log gets the load and the busiest processes outside marshal at intervals;
a landing job queued before the exclusive one starts goes first, and one arriving while it runs
waits; `--deadline` still applies.

**Settled on the user's delegation 2026-11-12** (choices the design left open). Reviewed with the user 2026-11-12 and kept:
an urgent job submitted later still starts ahead of a queued exclusive job.

- **What an exclusive job holds back while it waits (once its load has settled; see "An exclusive
  job waiting for the load reserves nothing" below): every job queued behind it, in queue order —
  development jobs, quick jobs and later exclusive jobs — but never a landing job.** The jobs ahead
  of it (and take-slot's waiters that arrived before it) are decided as if it and the jobs behind it
  were not there; it starts once nothing runs or starts, nothing ahead of it waits, and take-slot
  holds nothing. Why: without it a stream of short jobs (two quick slots refilling every few seconds,
  development backfill) could keep the machine from ever emptying; holding back from the moment it
  queues, not only once it heads the queue, bounds its wait by the jobs already ahead of it.
  Alternatives: hold back only once it is the queue's head (a stream of jobs ahead of it in the
  urgent band could still delay it, and the jobs between could start, then run long); let quick jobs
  through (the quick lane alone can keep the machine busy). An urgent job submitted later still goes
  ahead of it in the queue, since that is what `--urgent` means — the user may want to revisit this.
- **A waiting exclusive job never holds the landing lane; only a running one does.** A landing job
  queued at any time before the exclusive job starts goes first, even while other jobs still run.
  Why: a benchmark must never delay a release train, and the landing lane is outside the unit budget
  anyway. Alternative: holding landing jobs that arrive after the exclusive job queued (a train
  would wait for the machine to empty and a benchmark to run).
- **An exclusive job weighs the whole unit budget.** The daemon sets its units to the budget at
  submit, whatever `--units` said (no refusal: a script passing `--units` everywhere keeps working),
  and records that spec; `ls` and `status` show the budget in use, and take-slot is told it holds
  every unit, so take-slot's runs wait for it. Its memory is not limited by the budget, as a landing
  job's is not: it runs alone. Alternatives: refusing `--units` with `--exclusive`; keeping its own
  units (misleading `status`, and take-slot would start runs beside it).
- **Not niced**, as a landing job is not: a benchmark measures the machine, and nothing of marshal's
  runs beside it. Alternative: niced like a development job (it would lose to background work
  outside marshal, which is what it measures against).
- **`--quiet-load`: the load is read once a second** (on the daemon's existing one-second tick,
  `sysctl -n vm.loadavg`, the first figure), for every exclusive job waiting with one — queued, or
  still waiting for others or to retry, so its clock is never stale. The clock starts when a reading
  falls below `n` and stops at any reading at or above it; the job may start once it has run for the
  window (60 s). A reading is taken at submit, so the first decision has one. The clock is not
  carried across `marshal restart` (the window starts again, as the quiet-timeout clock does). A
  load that cannot be read holds nothing back. Why: the one-minute average is already smoothed, so a
  second's resolution loses nothing; a missing `sysctl` must not hold a job for ever. `ls` shows
  `queued (load 7.9 ≥ 4)` while it is at or above, and `queued (load 3.5 < 4 for 20.0s)` while the
  window runs; `emptying` comes first while jobs still run. Alternatives: sampling on the 3-second
  scheduling tick (coarser `ls`), or counting the window only once the machine has emptied (a load
  that is low while marshal's jobs drain counts toward it here, which is what was asked: the load,
  whoever makes it).
- **The sample line: `marshal exclusive: load <1m> <5m> <15m>; busiest outside marshal: <name>
  <pid> <cpu>%, …`**, written as the job starts (before its own output) and then every 30 s (looked
  at on the one-second tick), naming the 5 busiest processes with any processor use. The job's log is
  opened for appending, so the lines and the job's output interleave whole. Why: the `marshal
  exclusive:` prefix is what a result-reading script greps; the load figures and the process names
  are enough to tell a disturbed run from a quiet one; 30 s is often enough for a multi-minute
  benchmark and adds nothing measurable. Alternatives: a separate `<id>.samples` file (one more file
  to find and clean), or `top`-style per-second sampling (noise in the log).
- **"Outside marshal" is every process except the daemon, its descendants (every job's tree), and
  the members of the job's own process groups** (its step group among them, which catches a process
  the job started that left its parent). `ps -A -o pid=,ppid=,pgid=,%cpu=,comm=` is read once a
  sample; descent is followed by parent pid. Why: jobs are the daemon's children, so descent covers
  marshal's own work; the group check covers a daemonised child. Take-slot's runs are outside
  marshal and do show. Alternatives: excluding by process group alone (misses a job that makes new
  groups); naming every process (unreadable).
- **`--exclusive` with `--landing` or `--quick` is refused**, and so is `--quiet-load` without
  `--exclusive` or not above 0. `ls` and `top` mark an exclusive job's kind `#` (before the urgent
  `!`; `history` does not, as the event log's ended jobs do not carry it); `top` says `exclusive` for it running; `status` adds `; exclusive job N owns the
  machine: nothing else starts`; the job JSON has `"exclusive":true` and `quiet_load`, `status` and
  the snapshot `exclusive` (the running one's id, or null). New reasons to wait: `emptying`, `load`
  (with `load`, `load_limit`, `calm_ms`) and `exclusive` (with `exclusive_id`), shown `emptying`,
  `load …` and `exclusive N`. The quick hint is never given to an exclusive job.
- **The test hooks**: `$MARSHAL_TEST_LOAD_FILE` (the load read from a file), `$MARSHAL_TEST_PS_FILE`
  (the process table from a file), `$MARSHAL_TEST_QUIET_LOAD_MS` (the window) and
  `$MARSHAL_TEST_EXCLUSIVE_SAMPLE_MS` (the interval), as the existing `$MARSHAL_TEST_*` hooks.

## `history` marks an exclusive job's kind `#` (branch `exclusive-mark`)

- **`history` and `top`'s history view mark an exclusive job's kind `#`, as `ls` and `top` do**, `!`
  after it for an urgent one (`bench#!`), and `top`'s help lists `#` beside `^`, `*` and `!`.
  Why: a job's kind reads the same wherever it is listed. Alternative: leaving ended jobs unmarked,
  which hides after the fact that a result was measured on an owned machine.

## An exclusive job waiting for the load reserves nothing (branch `exclusive-wait`)

**The stall it fixes** (seen 2026-11-13): job 2991, `--exclusive --quiet-load 2`, sat `queued (load
2.13 ≥ 2)` with no marshal job running, the load held at 2–2.5 by desktop apps (a container
runtime's renderer, an IDE, the terminal), and ten jobs behind it, 1–4 unit tests among them, sat
`queued (exclusive 2991)`. Two causes: a waiting exclusive job held the queue while it waited for a
load that marshal's own work was not making, and nothing bounded that wait.

- **An exclusive job reserves the machine only once its load has settled.** While `--quiet-load`
  still holds it (`unsettled`), it holds nothing back: every job but the later exclusive ones is
  decided as if it were not there, take-slot's waiters included, and take-slot's ticket is never at
  it; `ls` says `load …` for it, not `emptying`. Once the load has stayed below the limit for the
  window, it reserves exactly as before (what is behind it waits, the running jobs drain, it starts
  with nothing beside it). Should the load rise again before it starts, it stops reserving until the
  load settles again. Why: exclusivity exists so that no marshal job runs during the timing run;
  holding the queue before the load is right serves nothing, since the jobs it holds are not what
  keeps the load up. Reserving once the load settles keeps the old guarantee — no stream of small
  jobs can keep the machine from emptying once it is ready to go. Alternatives: reserving only once
  the exclusive job is next and the machine idle (the same in effect, but a job let through at that
  moment can run long, so the reservation has to start earlier anyway, which is what the settled
  load gives); draining for a bounded time (a fixed drain window either wastes the machine or cuts
  a benchmark's turn short, and needs its own clock beside the load's).
- **The wait for the load is bounded: config.json's `load_wait`, 15 minutes by default, `"never"`
  for none.** It is clocked from the first time the load holds the queued job back, on the
  daemon's clock; once it has passed the job counts its load as settled, reserves the machine, and
  starts once the machine empties. Its log then begins `marshal exclusive: started after waiting
  15m00s for the load to fall below 2; the load was 2.13`, before the usual sample line, so a result
  can be read for what it is. The clock is not carried across `marshal restart` (as the quiet-load
  window is not) and starts afresh for a retry. Why: without a bound the reserve-on-settle rule can
  starve the exclusive job, since the jobs it lets through raise the load it waits on; with one, its
  wait is at most `load_wait` and then one drain. 15 minutes is long enough for a passing burst (a
  build outside marshal, an update) to end and short enough for a benchmark to run in the same
  sitting. Alternatives: a per-job `--load-wait` option (a protocol field for a setting nobody has
  needed per job); refusing to start and failing the job (the user asked for the run, and the log
  line says how quiet the machine was).
- **`--quiet-load auto` is a quarter of the processors (`sysctl -n hw.ncpu`), at least 1**, resolved
  by the client at submit, so the job records the number (4.5 on an 18-core Mac). Where the count
  cannot be read, `auto` is refused and a number asked for. A number given is kept as given. Why:
  a fixed 2 is below an idle many-core desktop's ordinary load; a quarter of the cores is above it
  and still well below a machine doing real work. Alternatives: scaling every given number by the
  core count (a number would no longer mean what `uptime` shows); making `auto` the default for
  every exclusive job (a benchmark that never asked for a quiet load would start to wait for one).
  `$MARSHAL_TEST_NCPU` stands in for the count in the tests.

## Memory learned per command, adapting, and kept in memory.json (branch `mem-learning`)

**The user's direction, 2026-11-13**, given in three steps while this was built: *"the amount of
memory that a job needs should be tied more specifically to which kind of job it is. it can't be
something generic like 'test'"*; *"it should also be able to adapt to changes in memory
requirements"*; *"the information shouldn't just be stored in memory. it needs to be persisted"*.
Found when the machine ran one job at a time: nearly every queued job reserved about 37G of a 56G
budget. Kind `build` covered compiler gates and trains peaking at 33G, run from a fresh scratch or
worktree directory each time, so almost every job fell back from its (empty) directory to the kind's
history, and the kind's maximum was the heaviest gate anyone had run lately. A 1-unit build and a
plugin build each inherited it. This replaces the per-kind and per-directory rules of `mem-per-dir`
and `mem-admission` where they differ; the margin, the hold to the budget, `--mem` and admission by
max(reservation, measured) are unchanged.

- **Learned memory is keyed by what the job runs: kind, lane and command signature, refined by
  directory.** The signature is the program's basename, then its subcommand and its target (the
  first two later words that are not options or numbers, each as its last path component):
  `sysl test compiler` and `sysl test .` are different work, and worktrees of one repository share.
  A shell is its script's name (`zsh gate.zsh`), without arguments, which in a train are branch
  names that change every run. A `-c` is the command it runs, past `cd`/`export` steps. Wrappers
  (`env`, `nice`, `caffeinate`, `nohup`, `time`, `timeout`, `sudo`, `exec`, `command`) and
  `NAME=value` settings are passed over. Lookup: the signature in the job's directory (`cmd+dir`)
  once it has a run there, else the signature anywhere (`cmd`), else nothing. Why: the user's
  first direction, and the data. The heavy jobs were declared as 1 unit (shell scripts that run a
  suite at `--jobs 4` inside), so the per-unit scaling the director first proposed would have given
  a 1-unit build 33.8G per unit: still poisoned. The kind stays in the key so a landing gate learns
  apart from a development run of the same command, and two kinds that happen to share a command
  (`avin-gate`, `test`) never teach each other. Alternatives: the whole command line (an argument
  that changes every run, such as a branch or a file list, would never learn); the kind with
  per-unit scaling (above); finer kinds (every caller has to choose well, and kinds also key
  deadlines and `stats`).
- **No fallback to the kind, and a command never seen reserves 0.** The user's direction. Admission
  counts a running job at max(reservation, measured RSS), so a first run that grows holds back every
  later start as soon as it is measured (once a second). What that does not cover is several new
  heavy commands admitted in the same moment, before any of them is measured. A small fixed default
  was weighed for this and rejected: a default small enough not to recreate the collapse (2–4G)
  does not stop two 33G gates starting together, and one large enough to (16G+) is the collapse
  again. The remedy is the caller's, and the README's "Using marshal well" now says it: give `--mem`
  on the first run of new heavy work, and keep recurring script names stable. One run is enough to
  learn from (`minRuns` 1, was 2): with a specific key one run says what the work needs, and waiting
  for a second would leave the second run unreserved too.
- **The estimate is the most of the last 5 peaks plus 10% (window 10 before).** This is the user's
  second direction: it must follow the work up and down. Up at once: the newest peak is always in
  the window, so the next reservation is at least that peak plus the margin. When a peak is learned,
  every job still queued or waiting reserves again, so queued jobs of that command take the higher
  figure before they start (the reservation was fixed at submit before). Down steadily: once the
  work needs less, the old peaks leave the window one run at a time and the reservation reaches the
  new level on the 5th run; one spike is forgotten the same way. No thrashing: work that varies
  run to run reserves the top of its last 5 runs, which covers its range and changes only when that
  top leaves the window. In a test of fifteen peaks wandering between 8G and 10G, the reservation
  changes once. A job running above its reservation is still counted at what it measures.
  Alternatives: a decaying maximum (est = max(peak, est × d)) moves on every run while the peaks
  are noisy, which is the thrashing the user ruled out; the second-highest of a longer window
  forgets a spike sooner but follows a real step down more slowly, and is harder to explain; an
  exponentially weighted mean or percentile under-reserves the run that matters, and memory, unlike
  time, costs every job on the machine when it runs short.
- **The learned peaks are kept in `<home>/memory.json`, written after every job that ends.** This is
  the user's third direction. Format: `{"version": 1, "peaks": {"<key>": [bytes...]}}`, the last 20
  peaks of each key, oldest first (more than the window, so a later wider window has history). The
  write goes to a temporary file whose name holds the pid and a per-process counter, then a rename,
  so two writers never share a temporary file, and a reader sees one whole write or another, never
  a mixture. The daemon writes from its own loop, so its writes are also in order. At startup the
  daemon reads it. A missing, unreadable or other-version file (older or newer) is set aside with a
  line on stderr, and the peaks are learned again from `events.jsonl` and written at once. Why a
  file of its own: the event log is trimmed by `marshal clean` and the daemon's sweep (`keep_events`,
  365 days by default), so a command run only now and then would lose what it taught. Replaying a
  large log also costs time at every start, and the log's peaks are keyed by whatever the code of
  the day derives. Alternatives: only the event log (the trimming); keeping the model in
  `state.json` (that file is only for handing over across `restart` and is removed after);
  rewriting the file on a timer (a crash would lose the last few jobs' peaks for no saving that
  matters, since a job ends at most a few times a minute).
- **Old events still teach.** Every ending event already records `cmd` and `dir`, so the signature
  of a log written before this change is derived from the recorded command. An event without a
  command, which no marshal ever wrote, teaches nothing; one without a directory teaches its
  command only.
- **`resv_from` says `cmd+dir`, `cmd`, `given` or `none`**, and `ls`/`top` keep `~` for a learned
  reservation. A state saved by an earlier daemon, mid-restart, keeps the `kind+dir` or `kind` it
  recorded until its job ends, so readers accept both old words.
