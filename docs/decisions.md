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
- **The landing lane holds one job, outside the unit budget and outside the memory budget, but its
  memory counts against development jobs.** Why: take-slot's `land.lock` is one reserved slot that
  nothing slows; counting its memory makes development jobs wait for it rather than risk swapping
  it. Alternative: landing held to the memory budget (it could then wait behind development runs,
  which is what the lane exists to prevent).
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
members with `pgrep -g` is temporary, until avin binds Sysl's `group_members`.

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
- **The program is the one at the daemon's own path** (`process.executable()`), so `brew upgrade`
  followed by `marshal restart` runs the new one; `$MARSHAL_RESTART_PROGRAM`, in the daemon's
  environment, names another (the tests use it). Alternative: the path of the `restart` command's
  own program, sent in the request (a client from another install could swap the daemon for it).
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
- `avin.fs` has no rename, so `state.json` is written in place rather than written aside and
  renamed. Only the program the daemon becomes reads it, after the write has finished, so this
  matters only to a daemon killed mid-write, which leaves a partial file that nothing reads.

## Holds, retries and rerun (branch `depends`)

**Proposed**; each says why and what else was weighed.

- **A dependency may name only a job that already exists, so holds cannot form a cycle.** A job's
  id is given when it is submitted, after the jobs it names, so every hold points to an older job.
  An id that is no job, or the id the job itself would get, is refused; no cycle check is needed.
  Alternative: allowing ids of jobs not yet submitted (a cycle check, and a job that may wait for
  ever on a mistyped id).
- **`--after` means `--after-ok`; one job is held one way, not both.** The ids of repeated options
  of the same way are joined. Alternative: a mode per id (`--after-ok 3 --after-any 4`): more to
  explain, for a case no one asked for.
- **A failed dependency cancels the held job at once**, even while its other dependencies still
  run, with the outcome `dependency-failed` naming the job that failed; the cancel ends that job,
  so it cascades to what is held for it. "Failed" is anything but exit 0: a nonzero exit, a signal,
  a timeout, a kill, a cancel, a loss. Alternative: waiting for every dependency before deciding
  (holds the queue's view of a job that can no longer run).
- **`dependency-failed` exits 126**, apart from a plain cancel's 143, so a script can tell "it
  never ran because something before it failed" from "it was cancelled". Alternatives: 143, as
  for every cancel; or a code above 128 (those read as signals).
- **A job released by its holds arrives in the queue when it is released**, not when it was
  submitted: it was not runnable before, and jumping ahead of jobs that were would be unfair to
  them. Alternative: its submission time (it would start ahead of jobs that queued while it was
  held).
- **A job held for one that already ended is decided at submit**: it queues at once, or is
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
- **Held jobs and jobs waiting to retry are carried across `marshal restart`** in the state's
  `held` list. A held job's remaining holds are not saved but worked out again from its `after`,
  so a dependency that ended during the hand-over releases it; a retry's time is saved on the wall
  clock like the other times.
- **`stop` counts held jobs as busy**: plain `stop` is refused while any is held, `--wait` waits
  for them, and `--force` cancels them first, before the queue, so none is released into a queue
  that is being cancelled.
- **`rerun <id>` submits the ended job's spec again — command, directory, environment, kind,
  units, memory, lane, deadline (as given, or learned again) and retries — but not its holds**,
  which have all ended. It is refused for a job not yet ended. A job that is no longer in the
  daemon's memory is found in the event log, whose `submitted` event now carries the whole spec;
  a job logged before that has none, and is refused. Alternatives: a spec file per job under
  `jobs/` (another file per job to clean up); carrying the holds (they have ended, so the rerun
  would be decided at once by the old outcomes).
