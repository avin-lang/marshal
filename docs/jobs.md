# Job types: the `.job` file

A job type is a kind of work written as data: the parameters it takes, the lane, units, memory and
deadline its runs get, and the steps it runs. `marshal run-type <type> [parameters]` runs one as a
single job; `marshal train …` is `marshal run-type train …`.

## Where types are found

`marshal run-type <name>` looks, in order, for

1. `.marshal/types/<name>.job` in the job's directory (`--dir`, or the current one): the project's
   own types, which can be kept in its repository;
2. `<marshal home>/types/<name>.job` (`~/.marshal/types`, or `$MARSHAL_HOME/types`): yours;
3. `types/<name>.job` among marshal's own (`$MARSHAL_STOCK`, or `share/marshal` beside the
   directory that holds the marshal executable): `train`.

A name holding a `/` or ending with `.job` is a file, relative to the job's directory. A type is
named after its file.

## The file

A `.job` file is one JSON object. A line whose first characters, past spaces, are `//` is a comment.
Every field but `steps` may be left out; a field marshal does not know is refused, since it is most
often a misspelling.

| Field | Meaning |
| --- | --- |
| `about` | One sentence for `--help`. |
| `kind` | The job's kind, for learning its deadline. Default: the type's name. |
| `lane` | `"dev"` (the default): a development job, in the unit budget, niced; `"landing"`: the landing lane. |
| `units` | Its weight in units (default 1). |
| `mem` | The memory it needs: `"29G"`, or a number of bytes (default 0). |
| `deadline` | How long the whole run may take: `"90s"`, `"30m"`, `"2h"`. Default: learned for its kind. |
| `params` | Its parameters, an object by name (below). |
| `steps` | The gate: the steps a run runs in order (below). Not empty. |
| `land` | The steps a gate that ends with `land` goes on to. The first of them is the one that lands. |
| `fail_map` | One step run after a red gate, to name the branch behind each failure. |
| `cleanup` | The steps that end every pass, whatever came of it. |
| `bisect` | The repeatable parameter whose values a red gate is bisected over. |

`--dir`, `--deadline`, `--units` and `--mem` on the command line override the type's own.
`--quiet-timeout <t>` stops the run, sampled and with the outcome `quiet`, once its log (every
step's output) has had no new output for `t`; a type has no quiet timeout of its own.

### Parameters

```json
"params": {
  "branch": {"repeat": true, "required": true, "positional": true, "about": "a branch to batch"},
  "remote": {"default": "origin"},
  "jobs":   {"type": "int", "default": 4},
  "quick":  {"type": "bool"},
  "on-red": {"default": "report", "choices": ["report", "bisect"]}
}
```

| Field | Meaning |
| --- | --- |
| `type` | `"string"` (the default), `"int"` or `"bool"`. |
| `default` | The value when none is given; for a repeatable parameter, a list. A parameter that is neither required nor repeatable has one. A `bool` is `false` unless given. |
| `required` | It must be given. Not with `default`, and never for a `bool`. |
| `repeat` | It takes any number of values: `--branch a --branch b`. |
| `positional` | It also takes the words that are not options: `marshal train a b`. At most one per type; not a `bool`. |
| `choices` | The only values allowed (strings only). |
| `about` | One line for `--help`. |

A name is a lowercase letter, then lowercase letters, digits, `-` and `_`. It may not be one of
run-type's own options (`dir`, `deadline`, `quiet-timeout`, `units`, `mem`, `label`, `help`,
`submit`) or one of the names
marshal gives every step (below).

On the command line a parameter is `--name value` or `--name=value`, and a `bool` is `--name` (or
`--name=false`). A value spelt like one of run-type's own options is written `--name=value`. After
`--`, every word is a positional value.

### Steps

```json
{"name": "test", "run": ["sh", "-c", "${test}"], "dir": "${work}/tree",
 "env": {"VERBOSE": "1"}, "when": "${test}", "exit": [0, 5], "result": false,
 "deadline": "1h", "on_success": "land", "on_failure": "${on-red}"}
```

| Field | Meaning |
| --- | --- |
| `name` | Unique within the type; named in the log and the report. |
| `run` | The program and its arguments, a list of text. The first word is a program on the `PATH`, a path, `stock:<name>` (one of marshal's own steps) or `avin:<path>` (an Avin program, a file or a package directory, relative to the type's file). The last two are compiled the first time and cached by the hash of their source and the compiler's version, in `<marshal home>/steps`. |
| `dir` | Where it runs. Default: the job's directory. Relative to it. |
| `env` | Variables set for it, besides the ones marshal sets. |
| `when` | The step is skipped where this comes to nothing, `false` or `0`. |
| `exit` | The exit codes that pass: a code, a list, or `"any"`. Default `0`. |
| `result` | When true, the step passes only where the last `=== RESULT` it said is `green`. |
| `deadline` | How long it may run; past it, its process group is stopped and the step fails. |
| `on_success` | What follows when it passes. Default `next`. |
| `on_failure` | What follows when it fails. Default `stop`. |

**The success test.** A step passes when its exit code is one `exit` allows, it said no
`=== RESULT red`, and, where `result` is set, the last result it said is `green`. The code read is the
last `=== EXIT` the step said, or else its process's own (128 + the signal for one ended by a
signal, 127 for a program that could not start). A step stopped at its deadline fails.

**Transitions.**

| | |
| --- | --- |
| `next` | Go on to the next step. Past the last, the steps are done: green. After a failure, the failure is let go. |
| `land` | The gate is green: go on to the `land` steps. Only on success, only in `steps`, and only where the type has `land` steps. |
| `report` | End the steps here, green where this one passed and red where it failed. |
| `bisect` | The gate is red: find what to blame (below). Only on failure, only in `steps`, and only where the type names a `bisect` parameter. |
| `stop` | End the run here: green where this one passed, red where it failed. |

The `land`, `fail_map` and `cleanup` steps take `next`, `report` and `stop` only.

A transition may be a reference, such as `"${on-red}"`; once the parameters are bound, what it comes
to is checked before anything runs.

### References

Every text of a step but its name may hold `${name}`, where `name` is a parameter or one of the names
marshal gives every step:

| | |
| --- | --- |
| `${dir}` | the job's directory |
| `${work}` | this pass's own scratch directory, in the run's directory |
| `${run_dir}` | the run's directory, `<marshal home>/runs/<job id>` |
| `${head}` | the last commit a step of this pass said with `=== HEAD` |
| `${pass}` | the pass's number, from 1 |

A word of `run` that is a single reference stands for one argument per value, so `"${branch}"` with
three branches is three arguments, and none with none. Anywhere else, a reference's values are joined
by spaces. `$${` is a literal `${`. A reference to a name that is neither is refused when the file is
read.

### What a step is given

Besides its arguments, every step has in its environment the job's own (the caller's, with
`MARSHAL_JOB` and `MARSHAL_HOME`) and:

| Variable | |
| --- | --- |
| `MARSHAL_PARAM_<NAME>` | each parameter's values, one to a line; the name in capitals, `-` as `_` |
| `MARSHAL_STEP` | the step's name |
| `MARSHAL_PASS` | the pass's number |
| `MARSHAL_WORK` | `${work}` |
| `MARSHAL_RUN_DIR` | `${run_dir}` |
| `MARSHAL_DIR` | `${dir}` |
| `MARSHAL_HEAD` | `${head}` |
| `MARSHAL_FAILS` | the tests this pass's steps said failed so far, one to a line |

A step runs in a process group of its own. Its standard output and error go to its log in the
pass's directory, and from there into the job's log, line by line as they come. What it leaves running
in its group is stopped when it ends; a step past its deadline has its group sent TERM and, 5 seconds
later, KILL; and every action on the job reaches the step that runs and what it started: `kill`, the
daemon's stop and a job deadline TERM it (and KILL it after the grace period), `pause` and `resume`
stop and continue it, and the job's memory counts it. The runner records the step's group in
`<home>/runs/<job>/step.pgid` while the step runs, for the daemon to read.

## A run

A run is one or more **passes**. A pass runs the gate (`steps`) in order. Where the gate is red, the
`fail_map` step runs; where it ended with `land`, the `land` steps run; and then the `cleanup` steps,
whatever came of it. Each pass has its own `${work}`, `pass-1`, `pass-2`, … in the run's directory.

Where the gate is red and asks to `bisect`, marshal finds the values of the `bisect` parameter to
blame. Where every failure the pass's steps said (`=== FAIL <test> <value>`) names one of the values,
those are to blame. Otherwise marshal bisects: it runs the gate (never landing) over each half of the
values, searches each half that fails in turn, and where neither half fails alone, blames the values
together. Then it runs one last pass over the values not blamed, which lands them where it is green.

The run ends green when everything it was given passed and, where the gate asked, landed; red
otherwise. It writes `report.json` and `report.txt` in the run's directory, and `run-type` prints the
latter when the job ends:

```json
{"type": "train", "result": "red", "step": "test", "landed": ["a", "c"], "head": "3f0c…",
 "culprits": ["b"], "together": false, "fails": [{"test": "t1", "branch": "b"}]}
```

`step` is where a red run ended; `landed` the values that landed (where a land step after the first
failed, as a teardown may, they landed all the same); `culprits` the values blamed, which fail only
`together` where a bisection found no smaller set.

## The stock train

[`stock/types/train.job`](../stock/types/train.job) is a type like any other. Its steps are
`stock:git merge`, then the build and test commands by `sh` in the merged tree, then `stock:git land`
and `stock:git teardown`, and `stock:git cleanup` after every pass. A project wanting other defaults
copies it into its own `.marshal/types/` under the same name, which comes first.
