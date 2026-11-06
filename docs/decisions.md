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

## Sharing take-slot.zsh's directory (Proposed, branch `take-slot-interop`)

Each of these is **Proposed**: made for the transition while sysl's scripts move to marshal, for the
user to settle.

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
