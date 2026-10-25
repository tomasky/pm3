///|
/// Filesystem path helpers and pm3 directory layout.
///
/// pm3 deliberately keeps its own, tiny path layer instead of pulling in a
/// platform path library: the daemon only ever deals with POSIX-style paths.

///|
/// Return the directory part of `path` (everything before the last `/`).
/// Returns `"."` when there is no separator.
pub fn path_dirname(path : String) -> String {
  let view = path.view()
  match view.rev_find("/") {
    Some(index) =>
      if index == 0 {
        "/"
      } else {
        view.view(start_offset=0, end_offset=index).to_owned()
      }
    None => "."
  }
}

///|
/// Return the final component of `path`.
pub fn path_basename(path : String) -> String {
  let view = path.view()
  match view.rev_find("/") {
    Some(index) =>
      view.view(start_offset=index + 1, end_offset=view.length()).to_owned()
    None => path
  }
}

///|
/// Join two path segments with a single `/`.
pub fn path_join(left : String, right : String) -> String {
  if left.length() == 0 {
    return right
  }
  if left.view().has_suffix("/") {
    "\{left}\{right}"
  } else {
    "\{left}/\{right}"
  }
}

///|
/// Resolve a `pm3 start <script>` argument against the directory the command
/// was run in.
///
/// PM2 does this in the CLI — `cwd = path.resolve(process.cwd(), cwd)` and
/// `pm_exec_path = path.resolve(cwd, app.script)` — because the daemon's own
/// working directory is an implementation detail: it is wherever the daemon
/// happened to be launched from, which `pm3 update` or the first `pm3`
/// command of the day can change. A record that keeps the argument as typed
/// would then stop resolving after the next daemon restart.
///
/// Returns the script to record and the cwd to run it in. A `cwd` that was
/// given is resolved like the script, even when the script does not name a
/// file. An argument that names no file is left exactly as it was, so `pm3
/// start <name>` can still revive a managed process and a bare command still
/// reaches `PATH` (through the daemon's `which`).
pub fn resolve_start_path(
  script : String,
  cwd : String?,
  base : String,
) -> (String, String?) {
  // A relative `--cwd` is the CLI's to resolve, the way PM2 resolves it.
  let given = match cwd {
    Some(dir) => Some(resolve_config_path(base, dir))
    None => None
  }
  let joined = resolve_config_path(base, script)
  if joined.length() > 0 && @fs.path_exists(joined) {
    match given {
      Some(_) => (joined, given)
      None => (joined, Some(base))
    }
  } else {
    (script, given)
  }
}

///|
/// The `version` of the nearest `package.json` at or above the app's script,
/// the way PM2 fills `pm2_env.version` (`Utility.findPackageVersion`, which
/// walks outwards with `find-package-json`). `base` resolves a relative
/// script. The first `package.json` that exists and parses decides the
/// answer: its `version`, or `N/A` when it has none. A file that exists but
/// does not parse is skipped, and running out of directories is also `N/A`.
pub fn find_package_version(script : String, base : String) -> String {
  let full = if script.has_prefix("/") {
    script
  } else if base.length() > 0 {
    path_join(base, script)
  } else {
    return "N/A"
  }
  let mut dir = path_dirname(full)
  while dir.length() > 1 && dir.has_prefix("/") {
    let file = path_join(dir, "package.json")
    if @fs.path_exists(file) {
      let parsed : Json? = Some(@json.parse(@fs.read_file_to_string(file))) catch {
        _ => None
      }
      match parsed {
        Some(json) =>
          match json {
            Json::Object(members) =>
              match members.get("version") {
                Some(Json::String(version)) => return version
                _ => return "N/A"
              }
            _ => return "N/A"
          }
        None => ()
      }
    }
    dir = path_dirname(dir)
  }
  "N/A"
}

///|
/// Remove a trailing `suffix` from `name`, if present.
pub fn strip_suffix_owned(name : String, suffix : String) -> String {
  match name.view().strip_suffix(suffix) {
    Some(view) => view.to_owned()
    None => name
  }
}

///|
/// The pm3 home directory. Honours `PM3_HOME`, otherwise `$HOME/.pm3`.
pub fn pm3_home() -> String {
  match @env.get_env_var("PM3_HOME") {
    Some(p) if p.length() > 0 => p
    _ => {
      let home = match @env.get_env_var("HOME") {
        Some(h) if h.length() > 0 => h
        _ => "/tmp"
      }
      path_join(home, ".pm3")
    }
  }
}

///|
/// Directory holding the daemon's own state (dump, port, config).
pub fn pm3_state_dir() -> String {
  pm3_home()
}

///|
/// Directory holding application log files.
pub fn pm3_log_dir() -> String {
  path_join(pm3_home(), "logs")
}

///|
/// Path of the serialized process list.
pub fn pm3_dump_path() -> String {
  path_join(pm3_home(), "dump.json")
}

///|
/// Path of the persisted log-rotation configuration.
///
/// `logrotate.json` is the historical name and is still read, but new installs
/// are steered at `config.toml` / `config.json`, which can hold more than the
/// rotation policy.
pub fn pm3_logrotate_config_path() -> String {
  path_join(pm3_home(), "logrotate.json")
}

///|
/// Path of the TOML configuration file.
pub fn pm3_config_toml_path() -> String {
  path_join(pm3_home(), "config.toml")
}

///|
/// Path of the JSON configuration file.
pub fn pm3_config_json_path() -> String {
  path_join(pm3_home(), "config.json")
}

///|
/// Configuration files pm3 looks for, in order of precedence. Only TOML and
/// JSON are supported; the last entry is the pre-`config.*` name.
pub fn pm3_config_candidates() -> Array[String] {
  [pm3_config_toml_path(), pm3_config_json_path(), pm3_logrotate_config_path()]
}

///|
/// Path of the file that publishes the daemon's TCP port.
pub fn pm3_port_path() -> String {
  path_join(pm3_home(), "daemon.port")
}

///|
/// Path of the file that publishes the daemon's process id.
pub fn pm3_pid_path() -> String {
  path_join(pm3_home(), "daemon.pid")
}

///|
/// Path of the daemon's own stdout/stderr log.
pub fn pm3_daemon_log_path() -> String {
  path_join(pm3_home(), "pm3.log")
}

///|
/// Whether `path` is a log destination that must never be opened, rotated or
/// truncated: the null device (in any case) and the empty path.
///
/// `pm3 start --out-file /dev/null` is a legitimate way to silence one
/// stream, and PM2's logger skips `NULL` and `/dev/null` paths outright. A
/// rotation is a rename plus a reopen, so rotating the null device would
/// rename it to `null__<stamp>.log` and leave a regular file where the device
/// was — under root on devtmpfs, that rename succeeds.
pub fn is_discard_log_path(path : String) -> Bool {
  let trimmed = path.trim()
  trimmed.length() == 0 || trimmed.to_lower() == "/dev/null"
}

///|
/// Whether `path` is the daemon's own log. It rotates under the same policy
/// as application logs — `pm2-logrotate` rotates `pm2.log` the same way — but
/// `reloadLogs` and the cron trigger deliberately leave it alone, again
/// matching `pm2-logrotate`, and `flush` truncates it like PM2 does.
pub fn is_daemon_log_path(path : String) -> Bool {
  path == pm3_daemon_log_path()
}
