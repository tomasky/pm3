# pm3

`pm3` is a small, language-agnostic process manager with **built-in log
rotation**, written in [MoonBit](https://www.moonbitlang.com/). It is inspired
by [PM2](https://pm2.keymetrics.io/) and by the
[`pm2-logrotate`](https://github.com/keymetrics/pm2-logrotate) module, but it
manages *any* background service — a shell script, a Python worker, a Go
daemon, a Node app — not just JavaScript runtimes.

```
pm3 start ./worker.sh --name worker
pm3 start ./worker.py --interpreter python3 --name py-worker --cwd /srv/app
pm3 list
pm3 logs worker --follow
pm3 stop worker
```

## Highlights

- **Any executable.** `pm3` supervises an arbitrary command line, and resolves
  interpreters the way PM2 does — `.js` through node, `.py` through python,
  binaries directly — with `--interpreter` and `--interpreter-args` to pin
  either. See [Interpreters](#interpreters).
- **Crash recovery.** Automatic restarts with `min_uptime` / unstable-restart
  tracking, restart budgets, restart delays, `stop_exit_codes` and
  `max_memory_restart`.
- **PM2's look.** `list`, `describe` and `logs` use PM2's colors, table
  borders, log prefixes and `--help` layout, so the two tools read the same —
  see [Terminal colors](#terminal-colors).
- **Built-in, optimized log rotation.** No external module, no `logrotate`
  cron job. Rotation is an O(1) `rename` + reopen performed by the daemon that
  owns the file descriptors — see [Log rotation](#log-rotation).
- **Background gzip.** Rotated files are compressed asynchronously, so a
  multi-gigabyte log never blocks a worker.
- **A real daemon.** The CLI talks to a detached supervisor over a loopback
  socket; the daemon owns child stdout/stderr pipes and keeps running after the
  terminal closes.
- **Single static binary.** One executable provides both the client and the
  daemon (`pm3 daemon` is the internal entry point).

## Install

```sh
# npm, pnpm, yarn or bun. The launcher downloads the native binary for this
# platform on first run; nothing is downloaded at install time.
npm install -g @tomasko/pm3

# Install script, no Node.js required.
curl -LsSf https://raw.githubusercontent.com/tomasky/pm3/master/install.sh | bash

# Or build from source, see below.
```

The Linux builds are linked **statically against musl**, so one binary runs on
any distribution regardless of its glibc version.

| Platform | Release asset |
| --- | --- |
| Linux x86-64 | `pm3-linux-x86_64` (static) |
| Linux arm64 | `pm3-linux-aarch64` (static) |
| macOS Apple silicon | `pm3-darwin-aarch64` |

The npm package ships a launcher rather than the binary, and deliberately
**declares no `postinstall`**. Since npm 12 dependency install scripts are
blocked unless the user opts in, and pnpm 12 fails a *project* install outright
with `ERR_PNPM_IGNORED_BUILDS` when a dependency declares one:

```console
$ pnpm add @tomasko/pm3
Error: ERR_PNPM_IGNORED_BUILDS
  × adding a new package
  ╰─▶ Ignored build scripts: @tomasko/pm3@0.1.1
```

Downloading lazily from the launcher works under npm, pnpm, yarn, bun, `npx`
and `--ignore-scripts`, because it is an ordinary command rather than an
install hook. See [`npmjs/README.md`](npmjs/README.md) for the environment
variables that redirect the download (`PM3_DOWNLOAD_BASE`, `PM3_BINARY`, …).

The install script takes `--version`, `--install-dir` and `--no-verify`, and
verifies the published SHA-256 before installing.

## Build

```sh
moon build --target native --release
# the binary is at _build/native/release/build/cmd/main/main.exe
```

Copy it somewhere on `$PATH` as `pm3`. During development the debug build
works too:

```sh
moon build --target native
./_build/native/debug/build/cmd/main/main.exe list
```

### Static Linux build

`scripts/build-linux-static.sh` produces a fully static binary with musl, which
is what the release workflow publishes. A glibc build records the build
machine's symbol versions, so a binary built on a new runner refuses to start
on an older distribution (`GLIBC_2.38 not found`); linking against musl
statically removes that entire class of problem.

```sh
sudo apt-get install musl-tools
./scripts/build-linux-static.sh dist/pm3-linux-x86_64
```

Run the unit tests with:

```sh
moon test --target native
```

## Releases

`.github/workflows/release.yml` builds one binary per target on its own runner
(MoonBit's native backend compiles through the system C compiler, so it is not
cross-compiled), smoke-tests it, and attaches the binary plus a `.sha256` to a
GitHub Release — two assets per target, no archive, because both installers
fetch the bare binary and set the mode themselves. It then publishes
`@tomasko/pm3` to npm, after the release exists, so the asset is there for the
first user to pull. Pushing a tag is the whole trigger:

```sh
git tag v0.1.1 && git push origin v0.1.1
```

The npm job is skipped when `NPM_TOKEN` is not configured, so a fork can still
cut releases.

## Quick start

```sh
# Start a service. The name defaults to the script's basename ("worker").
pm3 start ./worker.sh

# Run a non-executable script through an interpreter.
pm3 start ./jobs/digest.py --interpreter python3 --name digest

# The extension already picks the interpreter (.js -> node); arguments for
# the interpreter itself go before the script, as PM2 places them.
pm3 start ./app.js --interpreter-args "--trace-warnings --max-old-space-size=512"

# Pass arguments to the managed process after `--`.
pm3 start ./server --name api -- --port 8080

# Environment variables.
pm3 start ./server --name api -e PORT=8080 -e LOG_LEVEL=info

# Inspect it. The columns are PM2's — id, name, namespace, version, mode, pid,
# uptime, restarts (↺), status, cpu, mem, user, watching — and the footer
# totals the running processes.
pm3 list
# ┌────┬────────┬───────────┬─────────┬──────┬──────┬────────┬───┬────────┬───────┬────────┬──────┬──────────┐
# │ id │ name   │ namespace │ version │ mode │ pid  │ uptime │ ↺ │ status │ cpu   │ mem    │ user │ watching │
# ├────┼────────┼───────────┼─────────┼──────┼──────┼────────┼───┼────────┼───────┼────────┼──────┼──────────┤
# │ 0  │ digest │ default   │ N/A     │ fork │ 4242 │ 6s     │ 0 │ online │ 86.9% │ 11.3mb │ root │ disabled │
# │ 1  │ worker │ default   │ 2.5.1   │ fork │ 4243 │ 6s     │ 0 │ online │ 0%    │ 2.0mb  │ root │ disabled │
# └────┴────────┴───────────┴─────────┴──────┴──────┴────────┴───┴────────┴───────┴────────┴──────┴──────────┘
#
# 2/2 online   total cpu 86.9%   total mem 13.3mb

pm3 describe api
#  Describing process with id 0 - name digest
# ┌────────────────────┬───────────────────────────────────┐
# │ pm_id              │ 0                                 │
# │ name               │ digest                            │
# │ status             │ online                            │
# │ pid                │ 21557                             │
# │ command            │ python3 ./digest.py               │
# │ cwd                │ <inherited>                       │
# │ out log            │ /root/.pm3/logs/digest-out.log    │
# │ memory             │ 11.3mb                            │
# │ cpu                │ 86.9%                             │
# └────────────────────┴───────────────────────────────────┘

pm3 logs digest --follow

# Stop it, remove it.
pm3 stop api
pm3 delete api
```

Or declare the services in a `pm3.toml` and bring them all up at once —
see [Application config](#application-config).

```sh
pm3 start                 # reads ./pm3.toml
pm3 config apps           # show what that would start
```

## Configuration

pm3 reads **TOML and JSON only**. Anything else — YAML, INI, a `.js` file —
is refused with an error rather than ignored.

There are two things to configure, and they live in the same file format:

| | What it describes | Where pm3 looks |
| --- | --- | --- |
| **Applications** | Which processes to run, and how | `$PM3_CONFIG`, then `./pm3.toml`, `./pm3.json`, then the global file |
| **Log rotation** | The rotation policy, shared by every process | the global file only |

The global file is `$PM3_HOME/config.toml` (or `config.json`) — by default
`~/.pm3/config.toml`. It is global because the daemon is: one supervisor owns
every process on the machine, so one rotation policy applies to all of them.
A legacy `~/.pm3/logrotate.json` is still read.

`pm3 config` prints the global file and its contents, `pm3 config init toml`
(or `json`) creates one seeded with the current policy, and `pm3 config apps`
prints the app list pm3 would start.

### Application config

This is the pm3 equivalent of PM2's `ecosystem.config.js`: a project checks in
`pm3.toml`, and `pm3 start` brings the whole thing up.

```toml
# pm3.toml
[defaults]                    # optional, applied to every app below
max_restarts = 16
max_memory_restart = "200M"

[[app]]
name = "worker"
script = "./worker.py"
interpreter = "python3"
args = ["--verbose"]
env = { PORT = "8080", LOG_LEVEL = "info" }

[[app]]
name = "api"
script = "./bin/server"
max_memory_restart = "1G"        # overrides the default for this app only
stop_exit_codes = [0, 2]
```

The same document in JSON:

```json
{
  "defaults": { "max_restarts": 16 },
  "app": [
    { "name": "worker", "script": "./worker.py", "interpreter": "python3" }
  ]
}
```

Every `start` option has a config key of the same name:

| Key | Type |
| --- | --- |
| `name` | string (default: the script's basename without its extension) |
| `script` | string, required |
| `namespace` | string (default `default`); `pm3 stop\|restart\|delete <namespace>` acts on all of its apps |
| `args` | array of strings |
| `interpreter` | string (`exec_interpreter` is accepted as PM2's alias) |
| `interpreter_args` | string (split on whitespace) or array; PM2's `node_args` and `interpreterArgs` are accepted too |
| `cwd` | string (default: the config file's directory) |
| `env` | table of scalars |
| `autorestart` | bool |
| `max_restarts`, `restart_delay`, `min_uptime`, `kill_timeout` | integer |
| `max_memory_restart` | size (`"200M"`, `"1G"`, or bytes) |
| `kill_signal` | string |
| `stop_exit_codes` | array of integers |
| `merge_logs` | bool |
| `out_log`, `err_log` | string |
| `log_date_format` | string |

An unknown key is an error, not a shrug — a misspelled `max_memory_restart`
fails immediately instead of silently leaving the limit off.

**Paths are resolved against the config file, not the working directory.**
A checked-in `pm3.toml` therefore behaves the same whether pm3 is run from the
repository root, a subdirectory, or a cron job. `cwd` defaults to the config
file's directory for the same reason.

A `script` with a slash in it, or one that names a file next to the config, is
a path. A bare name that is not a file — `sh`, `python3`, `go` — is left alone
and looked up on `PATH`, exactly as `pm3 start sh` would.

```sh
pm3 start                  # ./pm3.toml, or the global file
pm3 start --config prod.toml
pm3 start pm3.json         # a positional .toml/.json is a config file
pm3 config apps            # show what that would start, and validate the file
```

Apps that are already online are left running, so re-running `pm3 start` after
adding one app to the file is not disruptive; everything else is started, and
a failure in one app does not abort the rest of the file.

> `pm3 start <script> ...` is unchanged: a single script is still started
directly, and options after the script are passed to the program, so
`pm3 start sh -c 'echo hi'` works. Use `--config` when the ambiguity matters.

A single script is resolved against the directory the command was run in, the
way PM2 resolves it in the CLI — the daemon's working directory is never
consulted. `pm3 start app.js` therefore records `/here/app.js` and runs in
`/here` whether or not the daemon happens to live there, and the saved record
keeps working after `pm3 update` restarts the daemon from somewhere else.
A bare name that is no file at all is still left for the daemon: it may be a
managed process (`pm3 start worker`) or a command looked up on `PATH`.

## Interpreters

PM2 never runs a script naked unless the file is a real executable, and pm3
makes the same decisions:

1. An explicit `--interpreter <cmd>` (or `interpreter = "..."` in a config
   file) wins.
2. Otherwise the extension picks the interpreter, from PM2's map: `.js` →
   node, `.py` → python, `.sh` → bash, `.rb` → ruby, `.php` → php, `.pl` →
   perl, `.coffee` → coffee, `.ls` → lsc, `.ts` / `.tsx` → bun.
3. Otherwise a **binary** runs directly (shown as `<none>` in
   `pm3 describe`), and any other file — a text file with no extension — is
   handed to `node`, the way PM2 falls back to its own runtime.

A missing interpreter fails the way PM2 reports it, rather than crashing:

```console
$ pm3 start ./worker.rb
Interpreter ruby is NOT AVAILABLE in PATH. (type 'which ruby' to double check.)
```

Arguments meant for the interpreter itself are passed with
`--interpreter-args` (`--node-args` is PM2's alias; both are accepted in
config files, under `interpreter_args`, `node_args` or `interpreterArgs`):

```sh
pm3 start ./app.js --interpreter-args "--trace-warnings --max-old-space-size=512"
```

```toml
interpreter_args = "--trace-warnings --max-old-space-size=512"   # split like a shell
interpreter_args = ["--trace-warnings", "--max-old-space-size=512"]
```

The string form is split on whitespace, with single and double quotes grouping
a run of spaces into one argument; the array form is taken as is. The arguments
are placed before the script — `node --trace-warnings app.js` — so they reach
`process.execArgv`. `pm3 describe` shows them in the command it prints.

Python interpreters additionally get `PYTHONUNBUFFERED=1`, so their output
appears in the logs as it is written instead of at exit, and a machine whose
`python` does not exist falls back to `python3`. PM2's `exec_interpreter` is
accepted as an alias of `interpreter`.

`pm3 start <name>` for a process that is already known brings it back up from
its **saved launch specification**, the way `pm2 start <name>` does: the
interpreter and arguments it was created with are reused, rather than `name`
being taken as a script path. `pm3 start all` does the same for every process
in the list, the way `pm2 start all` does.

## Commands

| Command | Description |
| --- | --- |
| `pm3 start <script> [options] [-- args...]` | Start and supervise a process |
| `pm3 start [--config <file>]` | Start every app a config file declares |
| `pm3 list` (aliases `ls`, `ps`, `status`) | Table of managed processes with PM2's columns, plus running/total counts and total CPU and memory |
| `pm3 describe <name\|id>` (aliases `desc`, `info`, `show`) | Full configuration and runtime state |
| `pm3 stop [name\|id\|namespace\|all]` | Stop one process, a whole namespace, or all when `all` (or no name) is given |
| `pm3 restart [name\|id\|namespace\|all]` | Restart one process, a whole namespace, or all (resets the restart counter) |
| `pm3 delete [name\|id\|namespace\|all]` (alias `del`) | Stop and remove processes; a namespace name removes all of its apps |
| `pm3 logs [name] [--lines N] [--follow] [--out] [--err] [--raw] [--nostream]` | Show (and follow) logs |
| `pm3 flush [name]` | Truncate the live log(s) |
| `pm3 reloadLogs` | Rotate every managed log now |
| `pm3 logrotate` | Show the rotation policy |
| `pm3 set logrotate:<key> <value>` | Change the rotation policy |
| `pm3 config` | Show the active config file and its contents |
| `pm3 config init [toml\|json] [--force]` | Create a config file |
| `pm3 config apps [--config <file>] [--json]` | Show what `pm3 start` would start, without starting it |
| `pm3 save` | Persist the process list to `dump.json` |
| `pm3 resurrect` | Start the processes that were desired online |
| `pm3 update` | Restart the daemon with this build, then resurrect what was online |
| `pm3 kill` | Stop the daemon (and its processes) |
| `pm3 version` | Print the version |

### `start` options

| Option | Meaning |
| --- | --- |
| `--config <file>` | Read the app list from a `pm3.toml` / `pm3.json` instead |
| `-n`, `--name <name>` | Process name (default: script basename) |
| `--namespace <ns>` | Start the app within the given namespace (default `default`) |
| `-i`, `--interpreter <cmd>` | Run `<script>` as an argument to `<cmd>` |
| `--interpreter-args <arguments>` | Arguments for the interpreter, before the script (`--node-args` is PM2's alias) |
| `--cwd <dir>` | Working directory |
| `--merge-logs` | Send stderr into the stdout log |
| `--out-file <path>` | stdout log path |
| `--err-file <path>` | stderr log path |
| `--no-autorestart` | Do not restart the process when it exits |
| `--max-restarts <n>` | Restart budget (`0` = unlimited) |
| `--restart-delay <ms>` | Delay before each restart |
| `--min-uptime <ms>` | Runs shorter than this count as "unstable" |
| `--max-memory-restart <size>` | Restart when RSS exceeds `<size>` |
| `--kill-timeout <ms>` | Grace period before `SIGKILL` |
| `--kill-signal <signal>` | Graceful signal (default `SIGTERM`) |
| `--stop-exit-codes <a,b>` | Exit codes that should not trigger a restart |
| `--log-date-format <fmt>` | Date prefix for log lines (accepted and stored) |
| `-e`, `--env KEY=VALUE` | Set an environment variable (repeatable) |

## Terminal colors

`pm3 list`, `pm3 describe` and `pm3 logs` use PM2's palette: grey table
borders, bold-cyan headers and ids, green `online`, blue `launching`, yellow
`restarting`, red for anything failed, and the blue `PM3 |` prefix on daemon
log lines. `pm3 help` is laid out the way commander prints PM2's help, and
`pm3 logs` prefixes every line with the same `id|name |` column PM2 uses.

Colors are emitted only when standard output is a terminal, so piping `pm3
list` into a file or a log collector gives plain text. `FORCE_COLOR=1` forces
them on (a non-empty `FORCE_COLOR=0` forces them off), `NO_COLOR` turns them
off, and `pm3 --no-color <command>` does the same for one invocation.

## Exit status

A command that could not do what it was asked to exits with status `1` — a
`pm3 start` whose script or interpreter is missing, `pm3 describe`, `pm3 stop`
and friends for an unknown process, an unknown option or command, or a config
file whose apps failed to start. Like PM2, `pm3 start` of a config file still
launches the apps that can start and then exits non-zero, and running `pm3`
with no command prints the usage block and exits `1`. Successful commands —
and `--help` / `--version` — exit `0`.

## How it works

```
        pm3 <command>                      pm3 daemon
   ┌────────────────────┐            ┌──────────────────────────┐
   │  client package    │  loopback  │  daemon package          │
   │  parse CLI         │ ─────────► │  accept + dispatch       │
   │  connect to daemon │  newline-  │  supervisor (per app)    │
   │  print results     │  delimited │  log sinks + rotation    │
   └────────────────────┘  JSON      │  gzip + prune workers    │
                                     │  resource monitor        │
                                     └────────────┬─────────────┘
                                                  │ pipes
                                        ┌─────────┴──────────┐
                                        │  managed children  │
                                        └────────────────────┘
```

- The CLI reads the daemon's ephemeral port from `~/.pm3/daemon.port`. If the
  daemon is not running it starts one detached (`spawn_orphan` + `setsid`) and
  waits for the port file.
- Each managed app gets one supervisor coroutine that runs the
  *spawn → wait → maybe restart* loop.
- Child `stdout`/`stderr` are **pipes owned by the daemon**, pumped into
  `LogSink`s. This is what makes safe rotation possible.
- State lives in `~/.pm3`:

```
~/.pm3/
├── dump.json          # serialized process table
├── config.toml        # configuration (or config.json)
├── daemon.port        # ephemeral TCP port (while running)
├── daemon.pid         # daemon pid (while running)
├── pm3.log            # daemon's own stdout/stderr
└── logs/
    ├── <name>-out.log
    ├── <name>-err.log
    └── <name>-out__<stamp>.log[.gz]
```

Set `PM3_HOME` to relocate everything (useful for tests).

## Log rotation

`pm3` integrates what `pm2-logrotate` does as a separate module, and fixes the
three problems in its rotation strategy.

### Why the rewrite

`pm2-logrotate` rotates a file by **streaming it to a dated copy and then
truncating the original**. That design has three well-known defects:

1. **Data loss.** Anything a worker writes between the copy finishing and the
   truncate completing is silently discarded.
2. **O(size) work.** A multi-gigabyte log has to be copied in full before it
   can be truncated; the rotation worker stalls, and on a busy service the
   window above is large.
3. **Sparse holes.** After `truncate`, the writer's file offset is still at the
   old position, so the next write lands far into the file and leaves a
   NUL-filled gap.

It also matches rotated files with a substring test (`file.indexOf(base) >= 0`),
which happily matches unrelated files, and it assumes every log ends in `.log`.

`pm3` avoids all of this because **the daemon owns every log descriptor**:

- Rotation is `rename(live, live__<stamp>.log)` followed by opening a fresh
  live file. That is **O(1)**, **atomic** on POSIX, loses nothing (the writer
  immediately switches to the new descriptor), and never produces holes.
- Rotated files are matched by an **exact prefix/suffix** test
  (`<base>__<stamp>.log[.gz]`), so `api-out__backup.log` or a file that merely
  contains the base name is never mistaken for a rotated log.
- Gzip runs on a **background worker** with a configurable level, instead of
  blocking the rotation path.
- Retention is computed from **modification times**, and can additionally cap
  files by age.
- An optional `min_size` prevents rotating near-empty logs.
- If two rotations happen within the same timestamp tick, the second one gets a
  `-1`, `-2`, … suffix instead of overwriting its sibling.

### Policy

Show the current policy:

```sh
pm3 logrotate
```

Change a key:

```sh
pm3 set logrotate:max_size 100M
pm3 set logrotate:compress true
pm3 set logrotate:retain 14
pm3 set logrotate:rotate_interval "0 3 * * *"
```

| Key | Default | Meaning |
| --- | --- | --- |
| `max_size` | `10M` | Rotate at this size (`0` disables size rotation) |
| `min_size` | `0` | Never rotate below this size |
| `retain` | `30` | Number of rotated files to keep per log |
| `max_age_days` | `0` | Also delete rotated files older than this (`0` = off) |
| `compress` | `false` | Gzip rotated files in the background |
| `compression_level` | `6` | gzip level, 1–9 (validated; encoder level is fixed) |
| `date_format` | `YYYY-MM-DD_HH-mm-ss` | Timestamp tokens used in rotated names |
| `worker_interval` | `30` | Seconds between size/prune passes (min 1) |
| `rotate_interval` | `0 0 * * *` | Cron expression that forces a rotation |
| `tz` | system | Timezone for file names (`UTC+8`, `+05:30`, or an IANA name) |
| `rotate_module` | `true` | Reserved; kept for `pm2-logrotate` compatibility |

The policy is shared by every sink, so changes take effect immediately without
restarting the daemon.

### Configuration file

The policy lives in the **global** file, `$PM3_HOME/config.toml` or
`$PM3_HOME/config.json` — by default `~/.pm3/config.toml`. It is global because
the daemon is: one supervisor owns every process on the machine, so one policy
applies to all of them. A project-local `pm3.toml` is read for its
*applications*, never for rotation, and a `[logrotate]` table in one is
rejected rather than quietly ignored.

**Only TOML and JSON are accepted** — a config file that is silently ignored
is worse than a loud error. `logrotate.json` is still read so that an existing
install keeps working.

```toml
# ~/.pm3/config.toml
[logrotate]
max_size = "100M"
retain = 14
compress = true
compression_level = 6
rotate_interval = "0 3 * * *"
tz = "UTC+8"
```

```json
{
  "logrotate": {
    "max_size": "100M",
    "retain": 14,
    "compress": true
  }
}
```

Both are parsed into the same tree, so they behave identically. `pm3 config`
prints the file in use and its contents; `pm3 config init toml` (or `json`)
creates one seeded with the current policy; `pm3 set logrotate:...` rewrites
whichever file is active, keeping its syntax.

Sizes may be written as `100M`, `1G`, `512K` or a plain byte count, and a value
written back is always **exact**: `min_size = 1000` stays `1000` rather than
rounding to `0.98K`. Unknown keys are an error rather than being ignored, so a
typo fails loudly instead of quietly doing nothing.

`rotate_interval` accepts the usual cron syntax (5 or 6 fields, names,
ranges, steps, lists) plus `@hourly`/`@daily`/`@weekly`/`@monthly`/`@yearly`.
When both day-of-month and day-of-week are restricted, the schedule fires if
*either* matches, as Vixie cron does.

## Process lifecycle

- **Stop** sends `kill_signal` (default `SIGTERM`), waits up to `kill_timeout`
  milliseconds, then sends `SIGKILL`.
- **Autorestart** restarts the process whenever it exits, unless
  `--no-autorestart` was given, the exit code is listed in
  `--stop-exit-codes`, or the restart budget (`--max-restarts`) is exhausted.
- A run shorter than `--min-uptime` increments the *unstable restarts* counter.
- `--max-memory-restart` is enforced by a monitor that samples
  `/proc/<pid>/status` every two seconds.
- A process that is no longer desired online (stopped by the user, or out of
  restarts) is left alone by `pm3 resurrect`.
- After a daemon restart nothing can reattach to a dead child's pipes, so the
  loaded table starts out stopped; run `pm3 resurrect` to bring back the
  processes that were desired online. Any orphan from a hard daemon death is
  terminated first, so a service is never started twice.
- `pm3 resurrect` resolves each record the way `pm3 start` does before running
  it — an older pm3 could leave a record without an interpreter, which would
  otherwise be executed directly and fail without explanation — and reports a
  record it cannot resolve instead of dropping it.
- A daemon left over from another build announces itself before the next
  command runs, with PM2's out-of-date warning; `pm3 update` is the fix it
  points at: save the list, kill the daemon, launch this build, resurrect.
- Records written by an older pm3 (including a dump from before a field
  existed) are read with the missing values filled in, so upgrading never
  empties the process list over one missing key.

## Environment variables

| Variable | Meaning |
| --- | --- |
| `PM3_HOME` | State directory (default `$HOME/.pm3`) |

The launcher and installer add their own variables (`PM3_BINARY`,
`PM3_CACHE_DIR`, `PM3_VERSION`, `PM3_DOWNLOAD_BASE`, `PM3_REPO`, …); they are
documented in [`npmjs/README.md`](npmjs/README.md).

## Limitations

- Native (`--target native`) only: it needs POSIX process, signal and file
  APIs.
- Linux/macOS: process memory and CPU are read from `/proc`, so resource
  reporting is Linux-specific. Supervision itself is POSIX.
- `kill_signal` accepts `SIGTERM`, `SIGINT`, `SIGHUP` and `SIGKILL`.
- `compression_level` is validated and stored, but the built-in gzip encoder
  uses a fixed level. The system `gzip` binary is preferred when available, and
  that one does honour the level.
- `--log-date-format` is accepted and stored but line timestamping is not yet
  applied to log output.

## License

Apache-2.0.
