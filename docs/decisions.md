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

## Job types and the train (branch `job-types`)

**Settled on the user's delegation 2026-11-07**; each says why and what else was weighed. Review
with the user: take-slot sharing off unless configured; a type's run being one job; a diverged
local target branch left with a warning. The FNV-1a step-cache digest is temporary, until avin's
library has a content digest. The user approved the design (types as
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
  over, with any half-written program. The hash is FNV-1a, 64 bits: a cache name, not a security
  check. Avin's library has no content digest (a gap, below).
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

- No content digest (SHA-256 or the like) in the library: the step cache hashes with FNV-1a,
  written in marshal.
- `avin.fs` has no rename (coming): a compiled step is written in place under its lock rather than
  built aside and renamed, so a reader must wait for the lock to go.
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

**Proposed.**

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
