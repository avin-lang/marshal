# The protocols

Two protocols: the one between the command line and the daemon, and [the step
protocol](#the-step-protocol), between a job type's steps and marshal.

## The daemon's protocol

The command line talks to the daemon over the Unix socket `sock` in marshal's home. Each message is
one JSON object on one line, ended by a line feed. A client writes a request and reads its reply; it
may send another request on the same connection afterwards. The daemon serves each connection on a
thread of its own, so a client blocked in `wait` holds up nobody else.

## Requests

| `op` | Fields | Reply |
| --- | --- | --- |
| `submit` | `kind` (string), `units` (int), `mem` (bytes), `landing` (bool, default false), `dir` (absolute path), `deadline_ms` (number or null: learned), `cmd` (array of strings, not empty), `env` (object of strings, default `{}`), `urgent` (bool, default false: the back of the lane's urgent band), `after` (array of job ids it waits for, default `[]`), `after_any` (bool, default false: it runs only if each of them exited 0), `retries` (int, default 0), `retry_delay_ms` (number, default 0), `mem_given` (bool, default false: `mem` was given, so a `mem` of 0 reserves nothing rather than the kind's learned peak; a `mem` above 0 is given either way), `label` (string, absent or null for none: one line of 1 to 80 characters, no control characters, no space at either end; a bad one is refused), `quiet_ms` (number above 0, absent or null for none: the job is sampled and stopped, outcome `quiet`, once its log has had no new output for that long, paused time left out), `external` (bool, absent for false: the job's work runs outside its process tree, so it reserves `mem` and holds it whatever its tree measures, and its peak is never learned; refused unless `mem_given` is true or `mem` is above 0) | `{"ok":true,"id":N,"log":"<path>"}`; refused for an `after` id that is no job or is the id this job would get |
| `rerun` | `id` | `{"ok":true,"id":N,"log":"<path>"}`, the new job: the ended job's spec but `after`, submitted again; refused for no such job, one not ended, or one whose `submitted` event holds no spec |
| `clean` | `older_ms` (number >= 1 or null), `keep` (number >= 0 or null), `dry_run` (bool, default false) | `{"ok":true,"cleaned":{"dry_run":bool,"jobs":[ids],"runs":[names],"steps":[names],"events":N,"event_jobs":M,"bytes":B}}`: the jobs whose logs went (none when `dry_run`: what would), the run directories and compiled steps removed, the events and jobs dropped from the event log, and `bytes`, how many bytes all of it held (what a dry run would free); a reply from an older daemon has no `bytes`, read as 0; only ended jobs are touched |
| `wait` | `id` | `{"ok":true,"job":JOB}` once the job has ended (its last attempt); at once for a job already ended, including one an earlier daemon ran |
| `kill` | `id` | `{"ok":true}`; the job's end is what `wait` answers |
| `ls` | | `{"ok":true,"jobs":[JOB...]}`: running, then queued, then waiting (for other jobs or to retry), then the last ten ended |
| `status` | | `{"ok":true,"units":U,"unit_budget":B,"mem":M,"mem_budget":MB,"rss":RSS,"mem_held":H,"machine_mem":MM,"running":R,"queued":Q,"landing":id or null,"take_slot":{"dir":D,"units":TU,"waiting":TW,"landing":bool} or null,"queue_held":bool}`; `mem` is what the running jobs reserve (declared or learned), `mem_held` what admission counts them holding (each job's reservation or its `rss`, whichever is more); a reply without `queue_held` or `mem_held` (an older daemon's) reads as false and 0 |
| `snapshot` | | `{"ok":true,"snapshot":{...}}`: the fields of the `status` reply but `running` and `queued`, then `uptime_ms` (how long the daemon has run), `running` (jobs), `queued` (jobs in queue order, each with `position` and `waits`, below), `recent` (the last ten jobs that ended, earlier daemons' included, the latest first) and `waiting` (jobs waiting for others or waiting to retry, oldest first; a reader takes a missing one as `[]`) |
| `stop` | `force` (bool), `wait` (bool) | `{"ok":true}` once the daemon has removed its socket; refused while jobs run unless one of the two is true |
| `version` | | `{"ok":true,"version":"<marshal's version>","pid":P}`, the daemon's process |
| `pause` | (no `id`) | `{"ok":true}`; the queue is held: nothing new starts in either lane. Refused when it is already held or the daemon is stopping |
| `resume` | (no `id`) | `{"ok":true}`; the queue is released and what fits starts. Refused when it is not held |
| `pause` | `id` | `{"ok":true}`; the running job's process group is sent STOP: it keeps its units, and its deadline's clock stops. Refused for a job that is queued, has ended, is being stopped or is already paused |
| `resume` | `id` | `{"ok":true}`; the paused job's group is sent CONT and its deadline's clock runs again. Refused for a job that is not paused |
| `hold` | `id` | `{"ok":true}`; the queued job is kept from starting and keeps its place; a job waiting for others or waiting to retry keeps the hold when it queues. Refused for a job that runs or has ended, or is already held, or while the daemon drains |
| `release` | `id` | `{"ok":true}`; the held job may start again. Refused for a job that is not held |
| `priority` | `id`, `priority` (an int, or `"urgent"`) | `{"ok":true}`; the queued job is placed in its lane. A number takes it out of the urgent band and places it among the jobs not urgent: higher first, equal ones by arrival. `"urgent"` moves it to the back of the lane's urgent band, which goes ahead of every job not urgent and keeps its jobs in the order they joined it. Refused for a job that runs or has ended |
| `restart` | optional `program`: the path of the executable the command line was run from; an older client sends none | no reply when the daemon restarts (into `$MARSHAL_RESTART_PROGRAM`, else `program`, else its own program): the connection closes as it replaces its program, and the client connects again and asks `version`, whose `pid` is the same; `{"ok":false,"error":...}` when it could not, including a `program` that is not an executable file, and it goes on as it was |
| `watch` | `cond` (string, the grammar below), `mode` (`once`, `past` or `follow`), `since` (milliseconds since 1970 or null), `since_id` (job id or null) | a stream: see below |

`history` and `stats` are not requests: the command line reads `events.jsonl` itself (below).
`grep` is not one either: like `tail` without `-f`, it reads the job's log, `jobs/<id>.log` in marshal's
home, itself, a line at a time, so it works on a running job and an ended one and with no daemon. It
exits 0 when a line matched, 1 when none did, 2 when it could not search (an unknown job or no log,
a pattern that is not a regular expression, a bad option); `-c` prints the number of matching lines
and nothing else. No state, field or message is added.

Any request may be refused: `{"ok":false,"error":"<a sentence>"}`, for a request that is not JSON,
lacks a field or has one of the wrong type, names no job, or asks for a job that can never fit.

## A job

```json
{"id":7,"kind":"test","units":4,"mem":0,"landing":false,"dir":"/work","cmd":["sysl","test","."],
 "state":"done","outcome":{"how":"exit","code":0},"killed":false,"queued_ms":12,
 "elapsed_ms":4200,"deadline_ms":2700000,"log":"/home/.marshal/jobs/7.log","sample":null,
 "rss":0,"peak_rss":1879048192,"started_at":1762521060000,"held":false,"priority":0,"urgent":false,
 "paused":false,"after":[],"attempt":1,"resv":0,"resv_learned":false,"resv_from":"none"}
```

`mem` is the memory the job declared; `resv` the memory the scheduler counts for it, its effective
reservation: `mem`, or with `resv_learned` true its learned peak (the most of the last 10 measured
peaks of its kind in its `dir` plus a tenth, once there are two; while the directory has fewer, the
same of its kind's peaks in every directory; held to the budget). A job without `resv` (from an
older daemon or log) reserves its `mem`, not learned. `resv_from` says where the reservation came
from: `given` (`mem` was given, `0` among them), `kind+dir` (its kind's peaks in its directory),
`kind` (its kind's peaks in every directory) or `none` (nothing learned yet); absent from an older
daemon or log. `external` is present, and true, only for a job submitted with it: its `resv` is its `mem`, admission counts it as holding that whatever its
`rss`, and its ending event's `peak_rss` is never learned from (nor counted by `stats`).

`state` is `waiting` (for the jobs in `after` to end), `queued`, `running`, `retrying` (waiting out
its retry delay) or `done`. `after` is what a waiting job still waits for; `attempt` counts its runs
from 1. `outcome` is null until
the job ends, then one of `{"how":"exit","code":C}`, `{"how":"signal","signal":S}`,
`{"how":"timeout"}` (its deadline), `{"how":"quiet","after_ms":Q}` (stopped because its log had no
new output for `Q` milliseconds, its quiet timeout), `{"how":"cancelled"}`, `{"how":"lost"}` and
`{"how":"dependency-failed","after":D}`, a job cancelled because job `D`, which it waited for, did
not exit 0. `quiet_ms` is the job's quiet timeout, present only for a job that has one. A reader takes a missing `after` as `[]` and a missing `attempt` as 1. `label` is the
text the job was submitted with; it is present only for a labelled job, so an absent one means no
label (an older daemon's replies and events have none). Every event of a job carries it, the
`submitted` event's `spec` too, and a reader of the log takes a label as it finds it, whatever the
limits are now. `elapsed_ms` is
the time run, with pauses left out, and 0 for a job that has not started (waiting, queued, held or
retrying; `queued_ms` is how long it has waited);
`killed` says `marshal kill` or a forced stop ended it; `sample` names the stack sample of a job
stopped at its deadline or its quiet timeout. `rss` is the bytes the job's whole process tree (its process group, and the
group of the step a job type's run is executing) held
in RAM at the daemon's last measurement, made every second, and 0 unless it runs; `peak_rss` the
most any measurement found, kept once it ends; `started_at` when it started, in milliseconds since
1970, 0 while it waits. The three are absent from what older daemons wrote and read as 0. In
`status` and `snapshot`, `rss` is the running jobs' sum and `machine_mem` the machine's memory, 0
where it is not known. `held` says a waiting or queued job is kept from starting by hand, `priority` places it among
its lane's jobs that are not urgent, and `urgent` says it is in the lane's urgent band, ahead of
them all; a job without them (from an older daemon or log) is not held, at priority 0, not urgent.
`paused` says a running job's processes are stopped by `pause`; a running job's `elapsed_ms` is
its run time with its pauses left out, which is what its deadline counts.

A queued job in a snapshot is the job object with two fields more, and a third for one behind
another job: `position`, its place in its lane's queue counted from 1 (landing jobs and development
jobs queue apart), and `waits`, why it has not started:

| `waits` | |
| --- | --- |
| `units` | its units do not fit beside what runs |
| `memory` | its units fit and its memory does not |
| `lane` | a landing job, and another landing job holds the lane |
| `draining` | a landing job whose memory does not fit beside what runs (or, over the whole budget, one that waits for nothing else to run); nothing else starts until the running jobs have freed it |
| `take-slot` | it waits for what take-slot holds: its runs' units or landing lock, or a take-slot run that arrived before it |
| `behind` | it fits, but starting it would delay the job at the head of the queue, whose id is `behind`; or a landing job, whose id is `behind`, is `draining` |
| `starting` | it starts at the daemon's next look |
| `held` | it is held (`hold`) |
| `queue-held` | the whole queue is held (`pause`) |

`marshal status --json` gives a queued job the same reason as `why` (the words in the table, with
`behind` when `why` is `behind`); `ls` and `status --json` read it from a `snapshot` request, and a
job that started in between has none.

**Across a restart.** The daemon writes every reply it has given before it restarts, and carries
out no request that arrives while it hands over: those connections close unanswered. So a
connection that closes before its reply means the request was not carried out, and the client
connects again and asks again; marshal's command line does so for up to 30 seconds. A `wait` goes on
waiting across a restart that way, and is answered by the new program.

A client asks for a snapshot without knowing the daemon's age: a daemon older than the request
refuses it with `no such request: `snapshot``.

## The event log

`events.jsonl` holds one line per step, the job object above preceded by `ts` (milliseconds since
1970) and `event`: `submitted` (adds `spec`, the fields of the `submit` request but `op`, and for a
`rerun` `rerun_of`, the job run again), `ready` (a job that waited for others joins the queue),
`held`, `released` and `prioritized` (a hold by hand begins or ends, a queued job is given a
priority), `paused` and `resumed` (a running job's), `started` (adds `pgid` and `pid`, the job's
main process), and one ending, `finished`, `timeout` (its deadline), `quiet` (its quiet timeout),
`killed`, `cancelled` (a job whose dependency failed) or `lost`, which adds `run_ms` and `exit`, the status `wait` exits with. `lost`
also adds `pgid` and `group_alive`, whether the job's processes were still running when the new
daemon looked. A job that is retried ends each attempt with its ending event, which adds
`"retrying":true`, and then records `retry` (adds `delay_ms`), with `attempt` the attempt to come;
so its last event is an ending only once the job has ended. An ending event may also carry
`peak_rss`, the most memory the job's process tree was measured holding, in bytes; `stats` reads it
where present.

`marshal history --json` prints `{"jobs":[{"id","kind","landing","outcome","exit","duration_ms",
"ended_at","peak_rss"}...],"unreadable":N}`, newest first (`ended_at` is `ts` of the ending event,
an instant in milliseconds whatever the caller's time zone; the table `history` prints shows it in
local time; `peak_rss` null where unknown, `outcome` one of `ok`, `failed`, `signal`, `killed`,
`timeout`, `quiet`, `cancelled`, `lost`). `marshal stats --json` prints `{"kinds":[{"kind","count","ok","success_pct",
"timeouts","p50_ms","p90_ms","max_ms","deadline_ms","peak_p50","peak_max"}...],"unreadable":N}`;
the percentiles and peaks are null where no job has one; `peak_p50` and `peak_max` are bytes
(as are `peak_rss` in `history --json` and `rss` and `peak_rss` in `status --json`), where the table shows them rounded. `unreadable` counts the log lines skipped.

## Watching events

`watch` is the one request answered by a stream: the daemon writes lines until the watch ends and
then closes the connection, which serves nothing else. A line is `{"ok":true,"event":EVENT}` (one
event, as the log holds it), `{"ok":true,"events":[EVENT...]}` (the events already logged that the
request asked for, together), or `{"ok":false,"error":"..."}`, the last line of a stream that ends
badly. `mode` says how it goes:

| `mode` | Answers |
| --- | --- |
| `once` | the first event the condition is met by, one `event` line, then the end; the end of a `since` that finds one at once |
| `past` | one `events` line with every logged event the condition lets through (from `since` and `since_id` on), then the end |
| `follow` | the same `events` line when `since` or `since_id` asks for one, then an `event` line for each matching event as it is logged, until the client leaves |

`since` is inclusive; `since_id` keeps the events of jobs numbered from it on. Without either, `once`
and `follow` see only events logged after the daemon registers them, and `past` all of them.

A condition `cond` is one of

```
idle
job=<id>[,<id>...]
<name>[:<filter>[,<filter>...]]
```

where `<name>` is `ended` (any ending event: `finished`, `timeout`, `quiet`, `killed`, `cancelled`,
`lost`), `failed` (an ending whose outcome is not `ok`), `landing-done` (an ending of a landing
job), `started`, `submitted`, `ready`, `retry`, `held`, `released`, `paused`, `resumed`,
`prioritized` (each the event of that name) or `any`, and a `<filter>` is `kind=<k>`,
`outcome=<o>` (for `ended`, `failed`, `landing-done` and `any`) or `label=<text>` (the job's label
contains `text`; it takes the rest of the filter, commas included, so it is written last), each at
most once. An event's
outcome is `ok` for `finished` with `exit` 0, `failed` for `finished` with any other `exit`, and the
event's name for `timeout`, `quiet`, `killed`, `cancelled` and `lost`; other events have none. `idle` and
`job=` are conditions of state and so only for `once`: `idle` is met when nothing runs, is queued,
waits for other jobs or waits to retry,
at once when it already is, and answered with `{"ts":T,"event":"idle","running":0,"queued":0}`;
`job=` when every job has ended (an attempt that is retried does not end it), at once when all have, and answered with the ending event of the
job that ended last. A job id the daemon has not numbered is refused (`no job N`), and so is a
condition that does not parse (`bad condition: ...`).

The daemon never waits for a reader. Each stream holds 256 replies; a reader that lets it fill is
dropped: its oldest reply is removed, its last line is `{"ok":false,"error":"events were dropped:
..."}` and the connection closes. A daemon that stops ends its streams with `"the daemon stopped"`;
one that restarts closes them without a last line, and the client connects again and asks with `since`
(the time the wait began, or of the last event it saw), which finds what happened while the daemon
handed over.

## The restart state

`state.json` in marshal's home is what a restarting daemon hands to the program it becomes, which
reads and removes it. It is one JSON object: `version` and `pid` of the daemon that wrote it,
`saved_at`, `began_at` (when the daemon first started), `next_id`, `queue` (in order), `running`,
`ended` (the last ten, oldest first), `ticket` (its waiting ticket in take-slot's directory, or
null), `queue_held` (false when absent) and `waiting` (jobs waiting for others or waiting to retry;
missing reads as `[]`). Each job holds `id`, `spec` (the fields of a `submit` request but `op`),
`state`, `submitted_at`, `arrived` (microseconds, take-slot's order), `started_at`, `ended_at`,
`deadline_ms`, `expected_ms`, `log`, `pid`, `pgid`, `outcome`, `killed`, `timed_out`, `sample`,
`rss` (bytes the job's processes hold as last measured), `peak_rss` (the most it has held), `held`,
`priority` and `urgent_at` (when it joined the urgent band, in microseconds since 1970, which
orders the band; 0 outside it), `paused_ms` (how long the job's earlier pauses lasted),
`paused_at` (when its current pause began, 0 while it is not paused; a job saved with one stays
paused), `attempt` and `retry_at` (when a job waiting to retry queues again), `reserved` and
`reserved_learned` (its effective reservation, and whether its kind's peaks taught it; a job saved
without them reads as -1 and false, and the new program learns its reservation again from the
peaks it read in the event log), `reserved_from` (where the reservation came from, as `resv_from`
in a listing; absent or `""` reads as `kind` for a learned one, else `given` or `none`), and `quiet_stopped` (a job being stopped, `timed_out`, is stopped
for its quiet timeout rather than its deadline; false when absent). A job's label is the `label`
member of its saved `spec`, absent for none, so state saved before labels reads with no label; its
quiet timeout is the spec's `quiet_ms` the same way. The quiet clock is not saved: the new program
starts every running job's again, from its log as it finds it. State written
without `rss`, `peak_rss` or `retry_at` reads them as 0, so the measured memory of a running job
carries across a restart; without `held`, `priority`, `urgent_at`, `paused_ms` or `paused_at` as
false and 0; and without `attempt` as 1. A waiting job's pending dependencies are not saved: the
new program looks again at each job in its `after`. Times are
milliseconds since 1970, and a time that has not come yet is 0. A file written by another process
than the one reading it is not taken over.

## The step protocol

A step of a [job type](jobs.md) is any program. Besides its exit status, it tells marshal things by
printing lines on its standard output, each a line of its own that begins `=== `, then a kind in
capitals and its words, separated by spaces:

| Line | Meaning |
| --- | --- |
| `=== STEP <part>` | The step has reached a part of its work (any words). Only for the log. |
| `=== EXIT <code>` | The code the step's success test reads in place of its process's exit code; the last one counts. For a wrapper whose own status means nothing. |
| `=== HEAD <sha>` | The commit this pass built: 4 to 64 lowercase hexadecimal digits. Later steps of the pass see it as `${head}` and `$MARSHAL_HEAD`; the last one counts. |
| `=== FAIL <test> [<branch>]` | A test failed (one word: a name, a path), and where the step knows, the value of the bisected parameter, a branch, to blame. Later steps of the pass see the failing tests in `$MARSHAL_FAILS`. |
| `=== RESULT green` / `=== RESULT red` | The step's verdict. `red` fails the step whatever its code; a step whose `result` is set needs a last `green` to pass. |

A line that does not begin `=== ` followed by one of these kinds is the step's own output and is
left alone, so `=== RUN TestThing` and `==========` mean nothing to marshal. A line of one of these
kinds written wrong (`=== HEAD xyz`, `=== RESULT maybe`, `=== EXIT many`) is not read, and the run's
log says so. A `\r` before the line's end is ignored, and so are spaces around the words.

A program reporting through these lines need not know it runs under marshal: a test runner that
prints `=== FAIL <file>` for each failing file, say, lets a train blame branches by its failures. A
`fail_map` step turns failures that name no branch into ones that do: it runs after a red gate with
the failing tests in `$MARSHAL_FAILS` and prints `=== FAIL <test> <branch>` for those it can place.
