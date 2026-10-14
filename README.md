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

- **Any executable.** `pm3` supervises an arbitrary command line; the optional
  `--interpreter` flag covers scripts that are not directly executable.
- **Crash recovery.** Automatic restarts with `min_uptime` / unstable-restart
  tracking, restart budgets, restart delays, `stop_exit_codes` and
  `max_memory_restart`.
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
cross-compiled), smoke-tests it, attaches it plus a `.tar.gz` and a `.sha256`
to a GitHub Release, and then publishes `@tomasko/pm3` to npm — after the
release exists, so the asset is there for the first user to pull. Pushing a tag
is the whole trigger:

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

# Pass arguments to the managed process after `--`.
pm3 start ./server --name api -- --port 8080

# Environment variables.
pm3 start ./server --name api -e PORT=8080 -e LOG_LEVEL=info

# Inspect it. The footer totals the running processes.
pm3 list
# id  name   status  cpu    mem     restarts  uptime  command
# --  -----  ------  -----  ------  --------  ------  ------------------
# 0   worker online  0.1%   24 MB   0         2h14m   ./worker.sh
# 1   digest online  91.5%  118 MB  3         41m     python3 ./digest.py
#
# 2/2 online   total cpu 91.6%   total mem 142.13 MB

pm3 describe api
pm3 logs api --follow

# Stop it, remove it.
pm3 stop api
pm3 delete api
```

Or declare the services in a `pm3.toml` and bring them all up at once —
see [Application config](#application-config).

```sh
pm3 start                 # reads ./pm3.toml
pm3 config apps           # what would that start?
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
| `args` | array of strings |
| `interpreter` | string |
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
pm3 config apps            # check what would be started
```

Apps that are already online are left running, so re-running `pm3 start` after
adding one app to the file is not disruptive; everything else is started, and
a failure in one app does not abort the rest of the file.

> `pm3 start <script> ...` is unchanged: a single script is still started
directly, and options after the script are passed to the program, so
`pm3 start sh -c 'echo hi'` works. Use `--config` when the ambiguity matters.

## Commands

| Command | Description |
| --- | --- |
| `pm3 start <script> [options] [-- args...]` | Start and supervise a process |
| `pm3 start [--config <file>]` | Start every app a config file declares |
| `pm3 list` (aliases `ls`, `ps`, `status`) | Table of managed processes, with running/total counts and total CPU and memory |
| `pm3 describe <name>` | Full configuration and runtime state |
| `pm3 stop [name]` | Stop one process, or all when no name is given |
| `pm3 restart [name]` | Restart one process, or all (resets the restart counter) |
| `pm3 delete [name]` (alias `del`) | Stop and remove processes |
| `pm3 logs [name] [--lines N] [--follow] [--err]` | Show (and follow) logs |
| `pm3 flush [name]` | Truncate the live log(s) |
| `pm3 reloadLogs` | Rotate every managed log now |
| `pm3 logrotate` | Show the rotation policy |
| `pm3 set logrotate:<key> <value>` | Change the rotation policy |
| `pm3 config` | Show the active config file and its contents |
| `pm3 config init [toml\|json] [--force]` | Create a config file |
| `pm3 config apps` | List the apps the config file declares |
| `pm3 save` | Persist the process list to `dump.json` |
| `pm3 resurrect` | Start the processes that were desired online |
| `pm3 kill` | Stop the daemon (and its processes) |
| `pm3 version` | Print the version |

### `start` options

| Option | Meaning |
| --- | --- |
| `--config <file>` | Read the app list from a `pm3.toml` / `pm3.json` instead |
| `-n`, `--name <name>` | Process name (default: script basename) |
| `-i`, `--interpreter <cmd>` | Run `<script>` as an argument to `<cmd>` |
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
| `-e`, `--env KEY=VALUE` | Set an environment variable (repeatable) |

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

MIT.
