# `@tomasko/pm3`

The npm launcher for [`pm3`](https://github.com/tomasky/pm3) — a
language-agnostic process manager with built-in log rotation, in the spirit of
PM2.

```sh
npm install -g @tomasko/pm3
pm3 start ./worker.py --interpreter python3 --name worker
pm3 list
pm3 logs worker --follow
```

`pm3` supervises **any** background service: a shell script, a Python worker, a
Go binary, a Node app. It is not tied to Node.js, and the log rotation is built
into the daemon rather than bolted on as a plugin.

## What this package contains

A small launcher, not the binary itself. On the first `pm3` run it downloads
the prebuilt native binary for your platform from the GitHub release and caches
it. Nothing is downloaded at install time.

| Platform | Target |
| --- | --- |
| Linux x86-64 | `pm3-linux-x86_64` (static, musl) |
| Linux arm64 | `pm3-linux-aarch64` (static, musl) |
| macOS Apple silicon | `pm3-darwin-aarch64` |

The Linux builds are linked statically against musl, so they run on any
distribution regardless of its glibc version.

## Why there is no `postinstall`

This package deliberately declares **no install script**. Since npm 12,
dependency lifecycle scripts are blocked unless the user opts in; and pnpm 12
fails a *project* install outright with `ERR_PNPM_IGNORED_BUILDS` when a
dependency declares one:

```console
$ pnpm add @tomasko/pm3
Error: ERR_PNPM_IGNORED_BUILDS
  × adding a new package
  ╰─▶ Ignored build scripts: @tomasko/pm3@0.1.1
```

Downloading lazily from `bin/pm3.js` sidesteps all of it: it works under npm,
pnpm, yarn, bun, `npx`, and `--ignore-scripts`, because it is an ordinary
command rather than an install hook.

## Cache location

The downloaded binary is kept outside the package, so reinstalling or clearing
`node_modules` never triggers a second download:

| Platform | Path |
| --- | --- |
| Linux | `$XDG_CACHE_HOME/pm3` or `~/.cache/pm3` |
| macOS | `~/Library/Caches/pm3` |

## Environment variables

| Variable | Effect |
| --- | --- |
| `PM3_BINARY` | Run this binary and never download anything |
| `PM3_CACHE_DIR` | Where to keep the downloaded binary |
| `PM3_VERSION` | Release version to fetch (default: this package's version) |
| `PM3_REPO` | `owner/repo` to download from (default: `tomasky/pm3`) |
| `PM3_DOWNLOAD_BASE` | Full base URL, overriding `PM3_REPO`/`PM3_VERSION` |
| `PM3_FORCE_DOWNLOAD` | Re-download even if the cached binary exists |
| `PM3_SKIP_DOWNLOAD` | Never download; fail if the binary is absent |
| `PM3_NO_VERIFY` | Skip SHA-256 verification of the download |

`PM3_DOWNLOAD_BASE` and `PM3_REPO` are there for forks, private mirrors and
air-gapped installs:

```sh
PM3_DOWNLOAD_BASE=https://internal.example.com/pm3 npm install -g @tomasko/pm3
```

## Other ways to install

```sh
# Installer script (no Node.js required)
curl -LsSf https://raw.githubusercontent.com/tomasky/pm3/master/install.sh | bash

# Build from source
git clone https://github.com/tomasky/pm3 && cd pm3
moon build --target native --release
```

## License

Apache-2.0
