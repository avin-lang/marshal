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

A client asks for a snapshot without knowing the daemon's age: a daemon older than the request
refuses it with `no such request: `snapshot``.

## The event log

`events.jsonl` holds one line per step, the job object above preceded by `ts` (milliseconds since
1970) and `event`: `submitted`, `started` (adds `pgid` and `pid`, the job's main process), and one ending, `finished`, `timeout`,
`killed` or `lost`, which adds `run_ms` and `exit`, the status `wait` exits with. `lost` also adds
`pgid` and `group_alive`, whether the job's processes were still running when the new daemon looked.
