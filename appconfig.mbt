///| pm3's own configuration: the applications it should run.
///
/// This is the pm3 equivalent of PM2's `ecosystem.config.js` — a declarative
/// list of processes, so a project can be brought up with one command instead
/// of a shell script full of `pm3 start` calls:
///
/// ```toml
/// # pm3.toml
/// [defaults]                 # optional, applied to every app below
/// max_restarts = 16
/// max_memory_restart = "200M"
///
/// [[app]]
/// name = "worker"
/// script = "./worker.py"
/// interpreter = "python3"
/// args = ["--verbose"]
/// env = { PORT = "8080" }
/// ```
///
/// The same document in JSON:
///
/// ```json
/// {
///   "defaults": { "max_restarts": 16 },
///   "app": [
///     { "name": "worker", "script": "./worker.py", "interpreter": "python3" }
///   ]
/// }
/// ```
///
/// Paths inside a config file are resolved relative to the file itself, so a
/// checked-in `pm3.toml` works regardless of the directory pm3 is invoked
/// from. `cwd` defaults to the config file's directory for the same reason.

///|
/// Field names an `[[app]]` entry understands. Anything else is rejected, so a
/// typo is reported rather than silently ignored.
///
/// `exec_interpreter`, `interpreterArgs` and `node_args` are accepted because
/// PM2's ecosystem documents them — a config carried over from PM2 should load
/// as-is.
pub fn app_field_names() -> Array[String] {
  [
    "name", "script", "args", "namespace", "interpreter", "exec_interpreter", "interpreter_args",
    "interpreterArgs", "node_args", "cwd", "env", "autorestart", "max_restarts",
    "restart_delay", "min_uptime", "max_memory_restart", "kill_timeout", "kill_signal",
    "stop_exit_codes", "merge_logs", "out_log", "err_log", "log_date_format",
  ]
}

///|
fn read_string_array_field(
  members : Map[String, Json],
  key : String,
) -> Result[Array[String]?, String] {
  match members.get(key) {
    None => Ok(None)
    Some(Json::Array(items)) => {
      let out : Array[String] = []
      for item in items {
        match item {
          Json::String(text) => out.push(text)
          _ => return Err("every entry of '" + key + "' must be a string")
        }
      }
      Ok(Some(out))
    }
    Some(_) => Err("'" + key + "' must be an array of strings")
  }
}

///|
fn read_int_array_field(
  members : Map[String, Json],
  key : String,
) -> Result[Array[Int32]?, String] {
  match members.get(key) {
    None => Ok(None)
    Some(Json::Array(items)) => {
      let out : Array[Int32] = []
      for item in items {
        match item {
          Json::Number(n, ..) => out.push(n.to_int())
          Json::String(text) => {
            let parsed : Int32? = Some(@string.parse_int(text)) catch {
              _ => None
            }
            match parsed {
              Some(value) => out.push(value)
              None =>
                return Err("every entry of '" + key + "' must be an integer")
            }
          }
          _ => return Err("every entry of '" + key + "' must be an integer")
        }
      }
      Ok(Some(out))
    }
    Some(_) => Err("'" + key + "' must be an array of integers")
  }
}

///|
fn read_string_map_field(
  members : Map[String, Json],
  key : String,
) -> Result[Map[String, String]?, String] {
  match members.get(key) {
    None => Ok(None)
    Some(Json::Object(entries)) => {
      let out : Map[String, String] = Map([])
      for name, value in entries {
        match value {
          Json::String(text) => out.set(name, text)
          Json::Number(n, ..) => out.set(name, n.to_string())
          Json::True => out.set(name, "true")
          Json::False => out.set(name, "false")
          _ => return Err("'" + key + "." + name + "' must be a scalar")
        }
      }
      Ok(Some(out))
    }
    Some(_) => Err("'" + key + "' must be a table or object of scalars")
  }
}

///|
/// Read the first alias that is present, so both PM2's and pm3's spelling of a
/// field work. Values are checked with `read_text_field`, so a non-string is
/// still an error.
fn read_aliased_text_field(
  members : Map[String, Json],
  keys : Array[String],
) -> Result[String?, String] {
  for key in keys {
    match read_text_field(members, key) {
      Ok(None) => ()
      Ok(Some(value)) => return Ok(Some(value))
      Err(message) => return Err(message)
    }
  }
  Ok(None)
}

///|
/// Read `interpreter_args` under any of the names PM2 accepts — the snake_case
/// form used by ecosystem files, the camelCase form used by `ecosystem.config.js`
/// authors, and PM2's own `node_args`.
///
/// A single string is split on whitespace the way PM2 splits it, so both
/// `interpreter_args = "--harmony --max-old-space-size=512"` and
/// `interpreter_args = ["--harmony"]` work.
fn read_interpreter_args_field(
  members : Map[String, Json],
) -> Result[Array[String]?, String] {
  for key in ["interpreter_args", "interpreterArgs", "node_args"] {
    match members.get(key) {
      None => ()
      Some(Json::String(text)) => return Ok(Some(split_shell_words(text)))
      _ => return read_string_array_field(members, key)
    }
  }
  Ok(None)
}

///|
/// Copy an application, keeping only the launch specification. Runtime fields
/// reset to their fresh values, which is what a config file describes.
fn clone_app(app : App) -> App {
  let copy = App::new(app.name, app.script, app.args.copy())
  copy.app_namespace = app.app_namespace
  copy.interpreter = app.interpreter
  copy.interpreter_args = app.interpreter_args.copy()
  copy.cwd = app.cwd
  copy.env = Map([])
  for key, value in app.env {
    copy.env.set(key, value)
  }
  copy.out_log = app.out_log
  copy.err_log = app.err_log
  copy.merge_logs = app.merge_logs
  copy.log_date_format = app.log_date_format
  copy.autorestart = app.autorestart
  copy.max_restarts = app.max_restarts
  copy.restart_delay = app.restart_delay
  copy.min_uptime = app.min_uptime
  copy.max_memory_restart = app.max_memory_restart
  copy.kill_timeout = app.kill_timeout
  copy.kill_signal = app.kill_signal
  copy.stop_exit_codes = app.stop_exit_codes.copy()
  copy
}

///|
/// Resolve the `script` of an app.
///
/// A bare name that is not a file next to the config — `sh`, `python3`, `go` —
/// is left alone so it is looked up on `PATH`, exactly as `pm3 start sh`
/// would. Anything with a slash in it, or a name that does exist next to the
/// config, is a path and is resolved.
fn resolve_script_path(base_dir : String, value : String) -> String {
  if value.is_empty() || base_dir.is_empty() || value.has_prefix("/") {
    return value
  }
  if value.contains("/") || @fs.path_exists(path_join(base_dir, value)) {
    return resolve_config_path(base_dir, value)
  }
  value
}

///|
/// Resolve a path from a config file against the file's own directory.
fn resolve_config_path(base_dir : String, value : String) -> String {
  if value.is_empty() || base_dir.is_empty() || value.has_prefix("/") {
    return value
  }
  let relative = if value.has_prefix("./") {
    value[2:].to_owned()
  } else {
    value
  }
  path_join(base_dir, relative)
}

///|
/// Read one app table, layered over `base` (the defaults).
fn app_from_table(
  members : Map[String, Json],
  base : App,
  base_dir : String,
) -> App raise ConfigError {
  let known = app_field_names()
  for key, _ in members {
    if !known.contains(key) {
      raise ConfigError(
        "unknown app setting '" + key + "'; expected one of " + known.join(", "),
      )
    }
  }
  let app = clone_app(base)
  let mut script_set = false
  let mut name_set = false
  let mut cwd_set = false
  let mut out_set = false
  let mut err_set = false
  apply_field(read_text_field(members, "name"), v => {
    app.name = v
    name_set = true
  })
  apply_field(read_text_field(members, "script"), v => {
    app.script = resolve_script_path(base_dir, v)
    script_set = true
  })
  apply_field(read_string_array_field(members, "args"), v => app.args = v)
  apply_field(read_text_field(members, "namespace"), v => app.app_namespace = v)
  apply_field(
    read_aliased_text_field(members, ["interpreter", "exec_interpreter"]),
    v => app.interpreter = v,
  )
  apply_field(read_interpreter_args_field(members), v => {
    app.interpreter_args = v
  })
  apply_field(read_text_field(members, "cwd"), v => {
    app.cwd = resolve_config_path(base_dir, v)
    cwd_set = true
  })
  apply_field(read_string_map_field(members, "env"), v => {
    for key, value in v {
      app.env.set(key, value)
    }
  })
  apply_field(read_bool_field(members, "autorestart"), v => app.autorestart = v)
  apply_field(read_int_field(members, "max_restarts"), v => app.max_restarts = v)
  apply_field(read_int_field(members, "restart_delay"), v => {
    app.restart_delay = v
  })
  apply_field(read_int_field(members, "min_uptime"), v => app.min_uptime = v)
  apply_field(read_size_field(members, "max_memory_restart"), v => {
    app.max_memory_restart = v
  })
  apply_field(read_int_field(members, "kill_timeout"), v => app.kill_timeout = v)
  apply_field(read_text_field(members, "kill_signal"), v => app.kill_signal = v)
  apply_field(read_int_array_field(members, "stop_exit_codes"), v => {
    app.stop_exit_codes = v
  })
  apply_field(read_bool_field(members, "merge_logs"), v => app.merge_logs = v)
  apply_field(read_text_field(members, "out_log"), v => {
    app.out_log = resolve_config_path(base_dir, v)
    out_set = true
  })
  apply_field(read_text_field(members, "err_log"), v => {
    app.err_log = resolve_config_path(base_dir, v)
    err_set = true
  })
  apply_field(read_text_field(members, "log_date_format"), v => {
    app.log_date_format = v
  })
  if !script_set || app.script.is_empty() {
    raise ConfigError("every app needs a 'script'")
  }
  if !name_set || app.name.is_empty() {
    app.name = derive_config_app_name(app.script)
  }
  // A name that only became known here still decides the default log paths.
  if !out_set {
    app.out_log = default_log_path(app.name, "out")
  }
  if !err_set {
    app.err_log = default_log_path(app.name, "err")
  }
  if !cwd_set {
    app.cwd = base_dir
  }
  if app.kill_signal.is_empty() {
    app.kill_signal = default_kill_signal()
  }
  if app.max_restarts < 0 {
    raise ConfigError("'max_restarts' must not be negative")
  }
  if app.restart_delay < 0 {
    raise ConfigError("'restart_delay' must not be negative")
  }
  if app.kill_timeout < 0 {
    raise ConfigError("'kill_timeout' must not be negative")
  }
  app
}

///|
/// Derive an app name from a script path: the basename without its extension.
pub fn derive_config_app_name(script : String) -> String {
  let base = path_basename(script)
  match base.rev_find(".") {
    Some(index) if index > 0 =>
      base.view(start_offset=0, end_offset=index).to_owned()
    _ => base
  }
}

///|
/// Read the `[defaults]` table that every app in the document inherits.
fn read_app_defaults(members : Map[String, Json]) -> App raise ConfigError {
  let base = App::new("", "", [])
  let table = match members.get("defaults") {
    None => return base
    Some(Json::Object(inner)) => inner
    Some(_) => raise ConfigError("'defaults' must be a table or object")
  }
  // Reuse the per-app reader, minus the checks that only make sense for a
  // concrete app.
  let app = clone_app(base)
  let known = app_field_names()
  for key, _ in table {
    if !known.contains(key) {
      raise ConfigError(
        "unknown default '" + key + "'; expected one of " + known.join(", "),
      )
    }
  }
  apply_field(read_string_array_field(table, "args"), v => app.args = v)
  apply_field(read_text_field(table, "namespace"), v => app.app_namespace = v)
  apply_field(
    read_aliased_text_field(table, ["interpreter", "exec_interpreter"]),
    v => app.interpreter = v,
  )
  apply_field(read_interpreter_args_field(table), v => app.interpreter_args = v)
  apply_field(read_string_map_field(table, "env"), v => {
    for key, value in v {
      app.env.set(key, value)
    }
  })
  apply_field(read_bool_field(table, "autorestart"), v => app.autorestart = v)
  apply_field(read_int_field(table, "max_restarts"), v => app.max_restarts = v)
  apply_field(read_int_field(table, "restart_delay"), v => app.restart_delay = v)
  apply_field(read_int_field(table, "min_uptime"), v => app.min_uptime = v)
  apply_field(read_size_field(table, "max_memory_restart"), v => {
    app.max_memory_restart = v
  })
  apply_field(read_int_field(table, "kill_timeout"), v => app.kill_timeout = v)
  apply_field(read_text_field(table, "kill_signal"), v => app.kill_signal = v)
  apply_field(read_int_array_field(table, "stop_exit_codes"), v => {
    app.stop_exit_codes = v
  })
  apply_field(read_bool_field(table, "merge_logs"), v => app.merge_logs = v)
  apply_field(read_text_field(table, "log_date_format"), v => {
    app.log_date_format = v
  })
  if app.kill_signal.is_empty() {
    app.kill_signal = default_kill_signal()
  }
  app
}

///|
/// Whether a document declares any applications.
pub fn has_apps(json : Json) -> Bool {
  match json {
    Object(members) =>
      match members.get("app") {
        Some(Json::Array(items)) => items.length() > 0
        _ =>
          match members.get("apps") {
            Some(Json::Array(items)) => items.length() > 0
            _ => false
          }
      }
    _ => false
  }
}

///|
/// Build the application list declared in a parsed config document.
///
/// `base_dir` is the directory of the config file, used to resolve the paths
/// it contains.
pub fn apps_from_json(
  json : Json,
  base_dir : String,
) -> Result[Array[App], String] {
  Ok(read_apps(json, base_dir)) catch {
    ConfigError(msg) => Err(msg)
  }
}

///|
fn read_apps(json : Json, base_dir : String) -> Array[App] raise ConfigError {
  let members = match json {
    Object(members) => members
    _ => raise ConfigError("the config file must be a table or object")
  }
  let defaults = read_app_defaults(members)
  let entries = match members.get("app") {
    Some(Json::Array(items)) => items
    Some(_) => raise ConfigError("'app' must be an array of tables: [[app]]")
    None =>
      match members.get("apps") {
        Some(Json::Array(items)) => items
        Some(_) =>
          raise ConfigError("'apps' must be an array of tables: [[app]]")
        None =>
          raise ConfigError(
            "no applications declared; add one with [[app]] and a 'script'",
          )
      }
  }
  let apps : Array[App] = []
  for entry in entries {
    let table = match entry {
      Object(inner) => inner
      _ => raise ConfigError("every [[app]] entry must be a table")
    }
    apps.push(app_from_table(table, defaults, base_dir))
  }
  if apps.is_empty() {
    raise ConfigError("no applications declared")
  }
  apps
}

///|
/// The absolute directory a config file lives in.
///
/// Relative paths inside the file are resolved against it, so a checked-in
/// `pm3.toml` behaves the same no matter where pm3 was invoked from — and
/// unlike the daemon's working directory, which is whatever it was started
/// with.
fn absolute_config_dir(path : String) -> String {
  let full = if path.has_prefix("/") {
    path
  } else {
    match @env.current_dir() {
      Some(dir) => path_join(dir, path)
      None => path
    }
  }
  path_dirname(full)
}

///|
/// Whether a document carries a `[logrotate]` table.
fn declares_logrotate(json : Json) -> Bool {
  match json {
    Object(members) => members.contains("logrotate")
    _ => false
  }
}

///|
/// Whether a path is the global config file — the only one whose `[logrotate]`
/// table means anything.
fn is_global_config(path : String) -> Bool {
  let full = if path.has_prefix("/") {
    path
  } else {
    match @env.current_dir() {
      Some(dir) => path_join(dir, path)
      None => path
    }
  }
  for candidate in pm3_config_candidates() {
    if candidate == full {
      return true
    }
  }
  false
}

///|
/// Read and parse an application config file, returning the apps it declares.
pub fn load_apps_from_file(path : String) -> Result[Array[App], String] {
  match read_config_file(path) {
    Err(msg) => Err(msg)
    Ok(json) => {
      // The rotation policy is global: the daemon is one supervisor for the
      // whole machine, so a project-local `[logrotate]` table would be read by
      // nobody. Saying so beats letting it sit there looking effective.
      if !is_global_config(path) && declares_logrotate(json) {
        return Err(
          "log rotation is configured globally, in " +
          pm3_config_toml_path() +
          "; remove the [logrotate] table from this file",
        )
      }
      apps_from_json(json, absolute_config_dir(path))
    }
  }
}

///|
/// Whether a path names a config file pm3 should read rather than a program
/// to run. Only TOML and JSON are ever config files.
pub fn is_app_config_file(path : String) -> Bool {
  (path.has_suffix(".toml") || path.has_suffix(".json")) &&
  @fs.path_exists(path)
}

///|
/// Configuration files pm3 looks for when `pm3 start` is given no script.
///
/// A project-local `pm3.toml` comes first, so a checked-in file wins over the
/// user's global defaults; `PM3_CONFIG` overrides both. This list is about
/// *applications* only — the rotation policy is read from the global file
/// alone, whatever else exists.
pub fn app_config_candidates() -> Array[String] {
  let out : Array[String] = []
  match @env.get_env_var("PM3_CONFIG") {
    Some(path) if path.length() > 0 => out.push(path)
    _ => ()
  }
  out.push("pm3.toml")
  out.push("pm3.json")
  out.push(pm3_config_toml_path())
  out.push(pm3_config_json_path())
  out
}

///|
/// The first application config file that exists, or `None`.
pub fn find_app_config() -> String? {
  for path in app_config_candidates() {
    if @fs.path_exists(path) {
      return Some(path)
    }
  }
  None
}
