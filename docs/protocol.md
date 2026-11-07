# The protocol

The command line talks to the daemon over the Unix socket `sock` in marshal's home. Each message is
one JSON object on one line, ended by a line feed. A client writes a request and reads its reply; it
may send another request on the same connection afterwards. The daemon serves each connection on a
thread of its own, so a client blocked in `wait` holds up nobody else.

## Requests

| `op` | Fields | Reply |
| --- | --- | --- |
| `submit` | `kind` (string), `units` (int), `mem` (bytes), `landing` (bool, default false), `dir` (absolute path), `deadline_ms` (number or null: learned), `cmd` (array of strings, not empty), `env` (object of strings, default `{}`), `urgent` (bool, default false: the back of the lane's urgent band) | `{"ok":true,"id":N,"log":"<path>"}` |
| `wait` | `id` | `{"ok":true,"job":JOB}` once the job has ended; at once for a job already ended, including one an earlier daemon ran |
| `kill` | `id` | `{"ok":true}`; the job's end is what `wait` answers |
| `ls` | | `{"ok":true,"jobs":[JOB...]}`: running, then queued, then the last ten ended |
| `status` | | `{"ok":true,"units":U,"unit_budget":B,"mem":M,"mem_budget":MB,"rss":RSS,"machine_mem":MM,"running":R,"queued":Q,"landing":id or null,"take_slot":{"dir":D,"units":TU,"waiting":TW,"landing":bool} or null,"queue_held":bool}`; a reply without `queue_held` (an older daemon's) reads as false |
| `snapshot` | | `{"ok":true,"snapshot":{...}}`: the fields of the `status` reply but `running` and `queued`, then `uptime_ms` (how long the daemon has run), `running` (jobs), `queued` (jobs in queue order, each with `position` and `waits`, below) and `recent` (the last ten jobs that ended, earlier daemons' included, the latest first) |
| `stop` | `force` (bool), `wait` (bool) | `{"ok":true}` once the daemon has removed its socket; refused while jobs run unless one of the two is true |
| `version` | | `{"ok":true,"version":"<marshal's version>","pid":P}`, the daemon's process |
| `pause` | (no `id`) | `{"ok":true}`; the queue is held: nothing new starts in either lane. Refused when it is already held or the daemon is stopping |
| `resume` | (no `id`) | `{"ok":true}`; the queue is released and what fits starts. Refused when it is not held |
| `pause` | `id` | `{"ok":true}`; the running job's process group is sent STOP: it keeps its units, and its deadline's clock stops. Refused for a job that is queued, has ended, is being stopped or is already paused |
| `resume` | `id` | `{"ok":true}`; the paused job's group is sent CONT and its deadline's clock runs again. Refused for a job that is not paused |
| `hold` | `id` | `{"ok":true}`; the queued job is kept from starting and keeps its place. Refused for a job that runs or has ended, or is already held, or while the daemon drains |
| `release` | `id` | `{"ok":true}`; the held job may start again. Refused for a job that is not held |
| `priority` | `id`, `priority` (an int, or `"urgent"`) | `{"ok":true}`; the queued job is placed in its lane. A number takes it out of the urgent band and places it among the jobs not urgent: higher first, equal ones by arrival. `"urgent"` moves it to the back of the lane's urgent band, which goes ahead of every job not urgent and keeps its jobs in the order they joined it. Refused for a job that runs or has ended |
| `restart` | | no reply when the daemon restarts: the connection closes as it replaces its program, and the client connects again and asks `version`, whose `pid` is the same; `{"ok":false,"error":...}` when it could not, and it goes on as it was |

| `watch` | `cond` (string, the grammar below), `mode` (`once`, `past` or `follow`), `since` (milliseconds since 1970 or null), `since_id` (job id or null) | a stream: see below |

Any request may be refused: `{"ok":false,"error":"<a sentence>"}`, for a request that is not JSON,
lacks a field or has one of the wrong type, names no job, or asks for a job that can never fit.

## A job

```json
{"id":7,"kind":"test","units":4,"mem":0,"landing":false,"dir":"/work","cmd":["sysl","test","."],
 "state":"done","outcome":{"how":"exit","code":0},"killed":false,"queued_ms":12,
 "elapsed_ms":4200,"deadline_ms":2700000,"log":"/home/.marshal/jobs/7.log","sample":null,
 "rss":0,"peak_rss":1879048192,"started_at":1762521060000,"held":false,"priority":0,"urgent":false,
 "paused":false}
```

`state` is `queued`, `running` or `done`. `outcome` is null until the job ends, then one of
`{"how":"exit","code":C}`, `{"how":"signal","signal":S}`, `{"how":"timeout"}`, `{"how":"cancelled"}`
and `{"how":"lost"}`. `elapsed_ms` is the time queued for a queued job and the time run otherwise;
`killed` says `marshal kill` or a forced stop ended it; `sample` names the stack sample of a job
stopped at its deadline. `rss` is the bytes the job's whole process tree (its process group) held
in RAM at the daemon's last measurement, made every second, and 0 unless it runs; `peak_rss` the
most any measurement found, kept once it ends; `started_at` when it started, in milliseconds since
1970, 0 while it waits. The three are absent from what older daemons wrote and read as 0. In
`status` and `snapshot`, `rss` is the running jobs' sum and `machine_mem` the machine's memory, 0
where it is not known. `held` says a queued job is kept from starting, `priority` places it among
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
| `take-slot` | it waits for what take-slot holds: its runs' units or landing lock, or a take-slot run that arrived before it |
| `behind` | it fits, but starting it would delay the job at the head of the queue, whose id is `behind` |
| `starting` | it starts at the daemon's next look |
| `held` | it is held (`hold`) |
| `queue-held` | the whole queue is held (`pause`) |

**Across a restart.** The daemon writes every reply it has given before it restarts, and carries
out no request that arrives while it hands over: those connections close unanswered. So a
connection that closes before its reply means the request was not carried out, and the client
connects again and asks again; marshal's command line does so for up to 30 seconds. A `wait` goes on
waiting across a restart that way, and is answered by the new program.

A client asks for a snapshot without knowing the daemon's age: a daemon older than the request
refuses it with `no such request: `snapshot``.

## The event log

`events.jsonl` holds one line per step, the job object above preceded by `ts` (milliseconds since
1970) and `event`: `submitted`, `held`, `released` and `prioritized` (a queued job's), `paused` and `resumed` (a running job's), `started` (adds `pgid` and `pid`, the job's main process), and one ending, `finished`, `timeout`,
`killed` or `lost`, which adds `run_ms` and `exit`, the status `wait` exits with. `lost` also adds
`pgid` and `group_alive`, whether the job's processes were still running when the new daemon looked.

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

where `<name>` is `ended` (any ending event: `finished`, `timeout`, `killed`, `lost`), `failed`
(an ending whose outcome is not `ok`), `landing-done` (an ending of a landing job), `started`,
`submitted` or `any`, and a `<filter>` is `kind=<k>` or `outcome=<o>`, each at most once. An event's
outcome is `ok` for `finished` with `exit` 0, `failed` for `finished` with any other `exit`, and the
event's name for `timeout`, `killed` and `lost`; other events have none. `idle` and `job=` are
conditions of state and so only for `once`: `idle` is met when nothing runs and nothing is queued,
at once when it already is, and answered with `{"ts":T,"event":"idle","running":0,"queued":0}`;
`job=` when every job has ended, at once when all have, and answered with the ending event of the
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
null) and `queue_held` (false when absent). Each job holds `id`, `spec` (the fields of a `submit` request but `op`), `state`,
`submitted_at`, `arrived` (microseconds, take-slot's order), `started_at`, `ended_at`, `deadline_ms`,
`expected_ms`, `log`, `pid`, `pgid`, `outcome`, `killed`, `timed_out`, `sample`, `rss` (bytes the job's processes hold as last measured),
`peak_rss` (the most it has held), `held`, `priority` and `urgent_at` (when it joined the urgent
band, in microseconds since 1970, which orders the band; 0 outside it), `paused_ms` (how long the
job's earlier pauses lasted) and `paused_at` (when its current pause began, 0 while it is not
paused; a job saved with one stays paused); state written without `rss` or `peak_rss` reads them
as 0, so the measured memory of a running job carries across a restart, and without `held`,
`priority`, `urgent_at`, `paused_ms` or `paused_at` as false and 0. Times are
milliseconds since 1970, and a time that has not come yet is 0. A file written by another process
than the one reading it is not taken over.
