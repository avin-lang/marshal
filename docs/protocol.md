# The protocol

The command line talks to the daemon over the Unix socket `sock` in marshal's home. Each message is
one JSON object on one line, ended by a line feed. A client writes a request and reads its reply; it
may send another request on the same connection afterwards. The daemon serves each connection on a
thread of its own, so a client blocked in `wait` holds up nobody else.

## Requests

| `op` | Fields | Reply |
| --- | --- | --- |
| `submit` | `kind` (string), `units` (int), `mem` (bytes), `landing` (bool, default false), `dir` (absolute path), `deadline_ms` (number or null: learned), `cmd` (array of strings, not empty), `env` (object of strings, default `{}`) | `{"ok":true,"id":N,"log":"<path>"}` |
| `wait` | `id` | `{"ok":true,"job":JOB}` once the job has ended; at once for a job already ended, including one an earlier daemon ran |
| `kill` | `id` | `{"ok":true}`; the job's end is what `wait` answers |
| `ls` | | `{"ok":true,"jobs":[JOB...]}`: running, then queued, then the last ten ended |
| `status` | | `{"ok":true,"units":U,"unit_budget":B,"mem":M,"mem_budget":MB,"rss":RSS,"machine_mem":MM,"running":R,"queued":Q,"landing":id or null,"take_slot":{"dir":D,"units":TU,"waiting":TW,"landing":bool} or null}` |
| `snapshot` | | `{"ok":true,"snapshot":{...}}`: the fields of the `status` reply but `running` and `queued`, then `uptime_ms` (how long the daemon has run), `running` (jobs), `queued` (jobs in queue order, each with `position` and `waits`, below) and `recent` (the last ten jobs that ended, earlier daemons' included, the latest first) |
| `stop` | `force` (bool), `wait` (bool) | `{"ok":true}` once the daemon has removed its socket; refused while jobs run unless one of the two is true |
| `version` | | `{"ok":true,"version":"<marshal's version>","pid":P}`, the daemon's process |
| `restart` | | no reply when the daemon restarts: the connection closes as it replaces its program, and the client connects again and asks `version`, whose `pid` is the same; `{"ok":false,"error":...}` when it could not, and it goes on as it was |

`history` and `stats` are not requests: the command line reads `events.jsonl` itself (below).

Any request may be refused: `{"ok":false,"error":"<a sentence>"}`, for a request that is not JSON,
lacks a field or has one of the wrong type, names no job, or asks for a job that can never fit.

## A job

```json
{"id":7,"kind":"test","units":4,"mem":0,"landing":false,"dir":"/work","cmd":["sysl","test","."],
 "state":"done","outcome":{"how":"exit","code":0},"killed":false,"queued_ms":12,
 "elapsed_ms":4200,"deadline_ms":2700000,"log":"/home/.marshal/jobs/7.log","sample":null,
 "rss":0,"peak_rss":1879048192,"started_at":1762521060000}
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
where it is not known.

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

**Across a restart.** The daemon writes every reply it has given before it restarts, and carries
out no request that arrives while it hands over: those connections close unanswered. So a
connection that closes before its reply means the request was not carried out, and the client
connects again and asks again; marshal's command line does so for up to 30 seconds. A `wait` goes on
waiting across a restart that way, and is answered by the new program.

A client asks for a snapshot without knowing the daemon's age: a daemon older than the request
refuses it with `no such request: `snapshot``.

## The event log

`events.jsonl` holds one line per step, the job object above preceded by `ts` (milliseconds since
1970) and `event`: `submitted`, `started` (adds `pgid` and `pid`, the job's main process), and one ending, `finished`, `timeout`,
`killed` or `lost`, which adds `run_ms` and `exit`, the status `wait` exits with. `lost` also adds
`pgid` and `group_alive`, whether the job's processes were still running when the new daemon looked. An ending event may also carry `peak_rss`, the most memory the job's process tree was
measured holding, in bytes; `stats` reads it where present.

`marshal history --json` prints `{"jobs":[{"id","kind","landing","outcome","exit","duration_ms",
"ended_at","peak_rss"}...],"unreadable":N}`, newest first (`ended_at` is `ts` of the ending event,
`peak_rss` null where unknown, `outcome` one of `ok`, `failed`, `signal`, `killed`, `timeout`,
`cancelled`, `lost`). `marshal stats --json` prints `{"kinds":[{"kind","count","ok","success_pct",
"timeouts","p50_ms","p90_ms","max_ms","deadline_ms","peak_p50","peak_max"}...],"unreadable":N}`;
the percentiles and peaks are null where no job has one. `unreadable` counts the log lines skipped.

## The restart state

`state.json` in marshal's home is what a restarting daemon hands to the program it becomes, which
reads and removes it. It is one JSON object: `version` and `pid` of the daemon that wrote it,
`saved_at`, `began_at` (when the daemon first started), `next_id`, `queue` (in order), `running`,
`ended` (the last ten, oldest first) and `ticket` (its waiting ticket in take-slot's directory, or
null). Each job holds `id`, `spec` (the fields of a `submit` request but `op`), `state`,
`submitted_at`, `arrived` (microseconds, take-slot's order), `started_at`, `ended_at`, `deadline_ms`,
`expected_ms`, `log`, `pid`, `pgid`, `outcome`, `killed`, `timed_out`, `sample`, `rss` (bytes the job's processes hold as last measured) and
`peak_rss` (the most it has held); state written without `rss` or `peak_rss` reads them as 0, so the
measured memory of a running job carries across a restart. Times are
milliseconds since 1970, and a time that has not come yet is 0. A file written by another process
than the one reading it is not taken over.
