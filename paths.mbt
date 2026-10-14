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
