///| Configuration file handling.
///
/// pm3 keeps its settings in `$PM3_HOME` and accepts exactly two syntaxes:
/// **TOML** (`config.toml`) and **JSON** (`config.json`). Other extensions are
/// rejected rather than guessed at, because a silently ignored config file is
/// worse than a loud error. `logrotate.json` is still read for compatibility
/// with pm3 releases that predate `config.*`.
///
/// Both syntaxes are parsed into a `Json` tree, so there is a single loader and
/// a single set of defaults after the first step:
///
/// ```text
/// config.toml ──┐
///               ├──▶ Json tree ──▶ LogrotateConfig
/// config.json ──┘
/// ```

///|
/// The two configuration syntaxes pm3 understands.
pub(all) enum ConfigFormat {
  Toml
  Json
} derive(Eq, Debug)

///|
/// A configuration file pm3 found: where it is and how to read it.
pub(all) struct ConfigSource {
  path : String
  format : ConfigFormat
} derive(Eq, Debug)

///|
/// Format implied by a file name, or `None` for an extension pm3 refuses to
/// guess at.
pub fn config_format_of(path : String) -> ConfigFormat? {
  if path.has_suffix(".toml") {
    Some(Toml)
  } else if path.has_suffix(".json") {
    Some(Json)
  } else {
    None
  }
}

///|
/// The configuration file pm3 writes to when none exists yet.
pub fn default_config_source() -> ConfigSource {
  { path: pm3_config_toml_path(), format: Toml, }
}

///|
/// The first configuration file that exists, or `None`.
///
/// The order is TOML, JSON, then the legacy `logrotate.json`, so a user who
/// migrates by writing `config.toml` does not have to delete the old file.
pub fn find_config_source() -> ConfigSource? {
  for path in pm3_config_candidates() {
    if config_file_exists(path) {
      match config_format_of(path) {
        Some(format) => return Some({ path, format, })
        None => continue
      }
    }
  }
  None
}

///|
/// The file pm3 will read, or the file it would create.
pub fn active_config_source() -> ConfigSource {
  match find_config_source() {
    Some(source) => source
    None => default_config_source()
  }
}

///|
/// Whether a path names an existing file. Kept synchronous and free of the
/// async runtime so that `pm3 set` works even when no daemon is running.
fn config_file_exists(path : String) -> Bool {
  @fs.path_exists(path)
}

///|
/// Create `dir` and any missing parents. `@fs.create_dir` only makes the last
/// component, and `PM3_HOME` is user-supplied, so walk the path.
fn ensure_dir(dir : String) -> Result[Unit, String] {
  if dir.is_empty() || dir == "/" || config_file_exists(dir) {
    return Ok(())
  }
  let parent = path_dirname(dir)
  if parent != dir && !parent.is_empty() {
    match ensure_dir(parent) {
      Ok(_) => ()
      Err(msg) => return Err(msg)
    }
  }
  @fs.create_dir(dir) catch {
    _ =>
      // A concurrent creator, or a directory that appeared meanwhile, is fine.
      if !config_file_exists(dir) {
        return Err("cannot create directory '" + dir + "'")
      }
  }
  Ok(())
}

///|
/// Read a configuration file and parse it according to its extension.
///
/// Returns `Err` with a human-readable message for a missing file, an
/// unsupported extension, or a syntax error.
pub fn read_config_file(path : String) -> Result[Json, String] {
  let format = match config_format_of(path) {
    Some(f) => f
    None =>
      return Err(
        "unsupported config file '" + path + "': pm3 reads .toml and .json only",
      )
  }
  let text = @fs.read_file_to_string(path) catch {
    _ => return Err("cannot read config file '" + path + "'")
  }
  parse_config_text(text, format)
}

///|
/// Parse configuration text in the given syntax.
pub fn parse_config_text(
  text : String,
  format : ConfigFormat,
) -> Result[Json, String] {
  match format {
    Toml =>
      match parse_toml(text) {
        Ok(json) => Ok(json)
        Err(msg) => Err("cannot parse config: " + msg)
      }
    Json =>
      Ok(@json.parse(text)) catch {
        err => Err("cannot parse config: " + describe_error(err))
      }
  }
}

///|
/// Raised while reading a config document. Private, like `TomlError`: the
/// public entry points turn it into a `Result`.
priv suberror ConfigError {
  ConfigError(String)
}

///|
/// Every key the rotation policy understands.
fn logrotate_field_names() -> Array[String] {
  [
    "max_size", "retain", "compress", "compression_level", "date_format", "worker_interval",
    "rotate_interval", "tz", "rotate_module", "min_size", "max_age_days",
  ]
}

///|
/// Apply one optional field, forwarding a bad value as a `ConfigError`.
fn[T] apply_field(
  slot : Result[T?, String],
  set : (T) -> Unit,
) -> Unit raise ConfigError {
  match slot {
    Ok(Some(value)) => set(value)
    Ok(None) => ()
    Err(msg) => raise ConfigError(msg)
  }
}

///|
/// Read a size-valued field. Accepts `"10M"`, `"10485760"` and a bare number,
/// so both hand-written and machine-written configs load.
fn read_size_field(
  members : Map[String, Json],
  key : String,
) -> Result[Int64?, String] {
  match members.get(key) {
    None => Ok(None)
    Some(Json::String(text)) =>
      match parse_size(text) {
        Some(value) => Ok(Some(value))
        None =>
          Err(
            "'" +
            key +
            "' must be a size such as 10M, 1G or 512K, got '" +
            text +
            "'",
          )
      }
    Some(Json::Number(n, ..)) => Ok(Some(n.to_int64()))
    Some(_) => Err("'" + key + "' must be a size")
  }
}

///|
fn read_int_field(
  members : Map[String, Json],
  key : String,
) -> Result[Int32?, String] {
  match members.get(key) {
    None => Ok(None)
    Some(Json::Number(n, ..)) => Ok(Some(n.to_int()))
    Some(Json::String(text)) => {
      let parsed : Int32? = Some(@string.parse_int(text)) catch { _ => None }
      match parsed {
        Some(value) => Ok(Some(value))
        None => Err("'" + key + "' must be an integer, got '" + text + "'")
      }
    }
    Some(_) => Err("'" + key + "' must be an integer")
  }
}

///|
fn read_bool_field(
  members : Map[String, Json],
  key : String,
) -> Result[Bool?, String] {
  match members.get(key) {
    None => Ok(None)
    Some(Json::True) => Ok(Some(true))
    Some(Json::False) => Ok(Some(false))
    Some(_) => Err("'" + key + "' must be true or false")
  }
}

///|
fn read_text_field(
  members : Map[String, Json],
  key : String,
) -> Result[String?, String] {
  match members.get(key) {
    None => Ok(None)
    Some(Json::String(text)) => Ok(Some(text))
    Some(_) => Err("'" + key + "' must be a string")
  }
}

///|
/// Extract the rotation policy from a parsed config document.
///
/// A `[logrotate]` table is the documented shape. A document that is itself a
/// policy (the legacy `logrotate.json`) is also accepted, so upgrading does not
/// require rewriting the file by hand. Unknown keys are rejected: a typo in a
/// config file should be loud, not silently ignored.
pub fn logrotate_from_json(json : Json) -> Result[LogrotateConfig, String] {
  Ok(read_logrotate(json)) catch {
    ConfigError(msg) => Err(msg)
  }
}

///|
fn read_logrotate(json : Json) -> LogrotateConfig raise ConfigError {
  let body = match json {
    Object(members) =>
      match members.get("logrotate") {
        Some(section) => section
        None => json
      }
    _ => json
  }
  let members = match body {
    Object(m) => m
    _ => raise ConfigError("the logrotate section must be a table or object")
  }
  let known = logrotate_field_names()
  for key, _ in members {
    if !known.contains(key) {
      raise ConfigError(
        "unknown logrotate setting '" +
        key +
        "'; expected one of " +
        known.join(", "),
      )
    }
  }
  let config = default_logrotate_config()
  apply_field(read_size_field(members, "max_size"), v => config.max_size = v)
  apply_field(read_int_field(members, "retain"), v => config.retain = v)
  apply_field(read_bool_field(members, "compress"), v => config.compress = v)
  apply_field(read_int_field(members, "compression_level"), v => {
    config.compression_level = v
  })
  apply_field(read_text_field(members, "date_format"), v => {
    config.date_format = v
  })
  apply_field(read_int_field(members, "worker_interval"), v => {
    config.worker_interval = v
  })
  apply_field(read_text_field(members, "rotate_interval"), v => {
    config.rotate_interval = v
  })
  apply_field(read_text_field(members, "tz"), v => config.tz = v)
  apply_field(read_bool_field(members, "rotate_module"), v => {
    config.rotate_module = v
  })
  apply_field(read_size_field(members, "min_size"), v => config.min_size = v)
  apply_field(read_int_field(members, "max_age_days"), v => {
    config.max_age_days = v
  })
  if config.compression_level < 1 || config.compression_level > 9 {
    raise ConfigError("'compression_level' must be between 1 and 9")
  }
  if config.worker_interval < 1 {
    raise ConfigError("'worker_interval' must be at least 1 second")
  }
  config
}

///|
/// Load the rotation policy, together with the file it came from.
///
/// A missing file is not an error: pm3 falls back to the defaults and reports
/// where the settings would be written.
pub fn load_logrotate_config() -> (LogrotateConfig, ConfigSource) {
  match find_config_source() {
    None => (default_logrotate_config(), default_config_source())
    Some(source) =>
      match read_config_file(source.path) {
        Err(_) => (default_logrotate_config(), source)
        Ok(json) =>
          match logrotate_from_json(json) {
            Ok(config) => (config, source)
            Err(_) => (default_logrotate_config(), source)
          }
      }
  }
}

///|
/// The rotation policy as a `Json` object nested under `logrotate`.
pub fn logrotate_to_json(config : LogrotateConfig) -> Json {
  let body : Map[String, Json] = Map([])
  body.set("max_size", Json::string(format_size_exact(config.max_size)))
  body.set("retain", Json::number(config.retain.to_double()))
  body.set("compress", Json::boolean(config.compress))
  body.set(
    "compression_level",
    Json::number(config.compression_level.to_double()),
  )
  body.set("date_format", Json::string(config.date_format))
  body.set("worker_interval", Json::number(config.worker_interval.to_double()))
  body.set("rotate_interval", Json::string(config.rotate_interval))
  body.set("tz", Json::string(config.tz))
  body.set("rotate_module", Json::boolean(config.rotate_module))
  body.set("min_size", Json::string(format_size_exact(config.min_size)))
  body.set("max_age_days", Json::number(config.max_age_days.to_double()))
  let root : Map[String, Json] = Map([])
  root.set("logrotate", Json::object(body))
  Json::object(root)
}

///|
/// Render a TOML string literal, escaping the characters TOML treats specially.
fn toml_string(value : String) -> String {
  let buf = StringBuilder()
  buf.write_char('"')
  for i in 0..<value.length() {
    match value.get_char(i) {
      Some('"') => buf.write_string("\\\"")
      Some('\\') => buf.write_string("\\\\")
      Some('\n') => buf.write_string("\\n")
      Some('\r') => buf.write_string("\\r")
      Some('\t') => buf.write_string("\\t")
      Some(c) => buf.write_char(c)
      None => ()
    }
  }
  buf.write_char('"')
  buf.to_string()
}

///|
/// Serialise the rotation policy as a `config.toml` document.
///
/// The output is regenerated from scratch, so comments in a hand-edited file
/// are lost when `pm3 set` rewrites it. `pm3 config` prints the file path
/// first, which is the hint to edit it by hand instead.
pub fn logrotate_to_toml(config : LogrotateConfig) -> String {
  let buf = StringBuilder()
  buf.write_string("# pm3 configuration. Regenerated by `pm3 set`; see also\n")
  buf.write_string("# https://github.com/tomasky/pm3#configuration\n\n")
  buf.write_string("[logrotate]\n")
  buf.write_string(
    "max_size = " + toml_string(format_size_exact(config.max_size)) + "\n",
  )
  buf.write_string("retain = " + config.retain.to_string() + "\n")
  buf.write_string("compress = " + config.compress.to_string() + "\n")
  buf.write_string(
    "compression_level = " + config.compression_level.to_string() + "\n",
  )
  buf.write_string("date_format = " + toml_string(config.date_format) + "\n")
  buf.write_string(
    "worker_interval = " + config.worker_interval.to_string() + "\n",
  )
  buf.write_string(
    "rotate_interval = " + toml_string(config.rotate_interval) + "\n",
  )
  buf.write_string("tz = " + toml_string(config.tz) + "\n")
  buf.write_string("rotate_module = " + config.rotate_module.to_string() + "\n")
  buf.write_string(
    "min_size = " + toml_string(format_size_exact(config.min_size)) + "\n",
  )
  buf.write_string("max_age_days = " + config.max_age_days.to_string() + "\n")
  buf.to_string()
}

///|
/// Serialise the rotation policy in the syntax the source file uses.
pub fn render_config(config : LogrotateConfig, format : ConfigFormat) -> String {
  match format {
    Toml => logrotate_to_toml(config)
    Json => logrotate_to_json(config).stringify(indent=2) + "\n"
  }
}

///|
/// Persist the rotation policy back to its file, creating parent directories as
/// needed. The format follows the file name.
pub fn save_logrotate_config(
  config : LogrotateConfig,
  source : ConfigSource,
) -> Result[Unit, String] {
  match config_format_of(source.path) {
    None =>
      Err(
        "unsupported config file '" +
        source.path +
        "': pm3 reads .toml and .json only",
      )
    Some(format) => {
      match ensure_dir(path_dirname(source.path)) {
        Err(msg) => return Err(msg)
        Ok(_) => ()
      }
      let text = render_config(config, format)
      @fs.write_string_to_file(source.path, text) catch {
        _ => return Err("cannot write config file '" + source.path + "'")
      }
      Ok(())
    }
  }
}

///|
/// Render any error type that implements `Debug` as a one-line message.
fn[T : @debug.Debug] describe_error(err : T) -> String {
  @debug.render(@debug.Debug::to_repr(err))
}

///|
/// Create a configuration file seeded with the current effective policy.
///
/// Refuses to overwrite an existing file unless `force` is set, so a stray
/// invocation cannot silently discard a hand-written config. Returns the path
/// that was written.
pub fn write_default_config(
  format : ConfigFormat,
  force : Bool,
) -> Result[String, String] {
  let (config, _) = load_logrotate_config()
  let path = match format {
    Toml => pm3_config_toml_path()
    Json => pm3_config_json_path()
  }
  if !force && config_file_exists(path) {
    return Err("'" + path + "' already exists (pass --force to overwrite)")
  }
  match save_logrotate_config(config, { path, format, }) {
    Ok(_) => Ok(path)
    Err(msg) => Err(msg)
  }
}
