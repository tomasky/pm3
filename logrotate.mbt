///|
/// Log rotation policy and the pure planning logic behind it.
///
/// This is the pm3 re-implementation of `pm2-logrotate`. The original module
/// works by *copying* a log file to a dated name and then truncating the
/// original. That has three well-known problems:
///
/// 1. **Data loss** — anything appended between the copy and the truncate is
///    discarded.
/// 2. **O(size) work** — a multi-gigabyte log has to be read and written in
///    full before it can be truncated, stalling the worker.
/// 3. **Sparse holes** — the writer keeps its file offset after truncation, so
///    the next writes land at the old offset, leaving a NUL-filled prefix.
///
/// pm3 avoids all three: the daemon owns every managed log file descriptor and
/// rotates by *renaming* the current file and reopening a fresh one. That is
/// an O(1) metadata operation, is atomic on POSIX, and loses nothing because
/// the writer immediately switches to the new descriptor. The functions here
/// describe that policy; the daemon performs the rename/reopen.

///|
/// Rotation policy. Persisted as JSON so `pm3 set logrotate:...` survives
/// daemon restarts.
pub struct LogrotateConfig {
  /// Rotate when a log reaches this many bytes. `0` disables size rotation.
  mut max_size : Int64
  /// Keep at most this many rotated files per log. `0` keeps only the current.
  mut retain : Int32
  /// Gzip rotated files in the background.
  mut compress : Bool
  /// Gzip level, 1 (fast) to 9 (small). Defaults to 9, the fixed
  /// `Z_BEST_COMPRESSION` level `pm2-logrotate` uses.
  mut compression_level : Int32
  /// `moment`-style token string used in rotated file names.
  mut date_format : String
  /// How often, in seconds, the daemon checks log sizes. Minimum 1.
  mut worker_interval : Int32
  /// Cron expression that forces a rotation.
  mut rotate_interval : String
  /// Optional fixed UTC offset for file names, e.g. `UTC+8`. Empty = system.
  mut tz : String
  /// Rotate logs of pm3-managed modules as well.
  mut rotate_module : Bool
  /// Never rotate a file smaller than this. Guards against rotating empty logs.
  mut min_size : Int64
  /// Delete rotated files older than this many days. `0` disables the age cap.
  mut max_age_days : Int32
} derive(Eq, Debug, ToJson, FromJson)

///|
/// Default policy, matching the familiar `pm2-logrotate` defaults.
pub fn default_logrotate_config() -> LogrotateConfig {
  {
    max_size: 10L * 1024L * 1024L,
    retain: 30,
    compress: false,
    compression_level: 9,
    date_format: "YYYY-MM-DD_HH-mm-ss",
    worker_interval: 30,
    rotate_interval: "0 0 * * *",
    tz: "",
    rotate_module: true,
    min_size: 0L,
    max_age_days: 0,
  }
}

///|
/// Parse a `true`/`false` value, also accepting `1`/`0` and `yes`/`no`.
pub fn parse_bool_value(text : StringView) -> Bool? {
  match text.trim().to_lower().to_owned() {
    "true" | "1" | "yes" | "on" => Some(true)
    "false" | "0" | "no" | "off" => Some(false)
    _ => None
  }
}

///|
/// A rotated log file: its name and modification time.
///
/// The modification time is in nanoseconds since the epoch. Sub-second
/// precision matters: a busy log can rotate several times inside one second,
/// and retention has to tell those files apart to keep the true newest ones.
pub(all) struct RotatedFile {
  name : String
  mtime : Int64
} derive(Eq, Debug)

///|
/// Compute the path a rotated log should be renamed to.
///
/// `log_path` is the live log (e.g. `.../logs/api-out.log`); the result is
/// `.../logs/api-out__<stamp>.log` (plus `.gz` when compression is enabled).
pub fn rotated_path(
  log_path : String,
  stamp : String,
  compress : Bool,
) -> String {
  let dir = path_dirname(log_path)
  let base = strip_suffix_owned(path_basename(log_path), ".log")
  let ext = if compress { ".log.gz" } else { ".log" }
  path_join(dir, "\{base}__\{stamp}\{ext}")
}

///|
/// If `file_name` is a rotated sibling of `log_path`, return the timestamp
/// suffix that was embedded in its name.
///
/// This replaces the original's `indexOf(base)` test, which also matched
/// unrelated files such as `api-out__backup.log` or a differently named log
/// that merely contained the base name.
pub fn parse_rotated_stamp(log_path : String, file_name : String) -> String? {
  let base = strip_suffix_owned(path_basename(log_path), ".log")
  let prefix = "\{base}__"
  let view = file_name.view()
  guard view.has_prefix(prefix) else { return None }
  let rest = view.view(start_offset=prefix.length(), end_offset=view.length())
  let body = match rest.strip_suffix(".gz") {
    Some(v) => v
    None => rest
  }
  guard body.has_suffix(".log") else { return None }
  Some(body.view(start_offset=0, end_offset=body.length() - 4).to_owned())
}

///|
/// Whether a log of `size` bytes should be rotated under `config`.
pub fn rotation_due(size : Int64, config : LogrotateConfig) -> Bool {
  if size <= 0L {
    return false
  }
  if config.min_size > 0L && size < config.min_size {
    return false
  }
  config.max_size > 0L && size >= config.max_size
}

///|
/// Choose which rotated files to delete.
///
/// Files are ordered newest-first by modification time (nanoseconds since the
/// epoch); everything after the first `retain` is deleted. When
/// `max_age_days > 0`, files older than that are deleted as well, regardless
/// of position.
pub fn select_for_deletion(
  files : Array[RotatedFile],
  retain : Int32,
  max_age_days : Int32,
  now : Int64,
) -> Array[String] {
  let sorted = files.copy()
  sorted.sort_by(fn(a, b) { compare_int64(b.mtime, a.mtime) })
  let doomed : Array[String] = []
  for i in 0..<sorted.length() {
    let file = sorted[i]
    let too_old = max_age_days > 0 &&
      now - file.mtime > max_age_days.to_int64() * 86400L * 1_000_000_000L
    if i >= retain || too_old {
      doomed.push(file.name)
    }
  }
  doomed
}

///|
/// Three-way comparison for `Int64` values.
fn compare_int64(a : Int64, b : Int64) -> Int32 {
  if a < b {
    -1
  } else if a > b {
    1
  } else {
    0
  }
}

///|
/// Update one field of the policy from a string, as used by
/// `pm3 set logrotate:<key> <value>`.
///
/// Keys use pm3's snake_case spelling; the camelCase names `pm2-logrotate`
/// documents (`dateFormat`, `workerInterval`, `rotateInterval`,
/// `rotateModule`, `TZ`) are accepted as aliases.
pub fn LogrotateConfig::set_field(
  self : LogrotateConfig,
  key : String,
  value : String,
) -> Result[Unit, String] {
  match key {
    "max_size" =>
      match parse_size(value) {
        Some(v) => {
          self.max_size = v
          Ok(())
        }
        None => Err("max_size must be a size such as 10M, 1G or 512K")
      }
    "min_size" =>
      match parse_size(value) {
        Some(v) => {
          self.min_size = v
          Ok(())
        }
        None => Err("min_size must be a size such as 1K")
      }
    "retain" =>
      match parse_non_negative_int(value) {
        Some(v) => {
          self.retain = v
          Ok(())
        }
        None => Err("retain must be a non-negative integer")
      }
    "max_age_days" =>
      match parse_non_negative_int(value) {
        Some(v) => {
          self.max_age_days = v
          Ok(())
        }
        None => Err("max_age_days must be a non-negative integer")
      }
    "compress" =>
      match parse_bool_value(value) {
        Some(v) => {
          self.compress = v
          Ok(())
        }
        None => Err("compress must be true or false")
      }
    "compression_level" =>
      match parse_non_negative_int(value) {
        Some(v) if v >= 1 && v <= 9 => {
          self.compression_level = v
          Ok(())
        }
        _ => Err("compression_level must be between 1 and 9")
      }
    "date_format" | "dateFormat" =>
      if value.length() == 0 {
        Err("date_format must not be empty")
      } else {
        self.date_format = value
        Ok(())
      }
    "worker_interval" | "workerInterval" =>
      match parse_non_negative_int(value) {
        Some(v) if v >= 1 => {
          self.worker_interval = v
          Ok(())
        }
        _ => Err("worker_interval must be at least 1 second")
      }
    "rotate_interval" | "rotateInterval" =>
      match parse_cron(value) {
        Some(_) => {
          self.rotate_interval = value
          Ok(())
        }
        None => Err("rotate_interval must be a valid cron expression")
      }
    "tz" | "TZ" => {
      self.tz = value
      Ok(())
    }
    "rotate_module" | "rotateModule" =>
      match parse_bool_value(value) {
        Some(v) => {
          self.rotate_module = v
          Ok(())
        }
        None => Err("rotate_module must be true or false")
      }
    _ => Err("unknown logrotate option '\{key}'")
  }
}

///|
/// Parse a base-10 non-negative integer.
pub fn parse_non_negative_int(text : StringView) -> Int32? {
  let t = text.trim()
  if t.length() == 0 {
    return None
  }
  for i in 0..<t.length() {
    guard t.get_char(i) is Some(c) else { return None }
    if c < '0' || c > '9' {
      return None
    }
  }
  Some(@string.parse_int(t)) catch {
    _ => None
  }
}

///|
/// Render the policy as aligned `key = value` lines for `pm3 logrotate`.
pub fn LogrotateConfig::to_display(self : LogrotateConfig) -> String {
  let buf = StringBuilder()
  buf.write_string("max_size          = \{format_size(self.max_size)}\n")
  buf.write_string("min_size          = \{format_size(self.min_size)}\n")
  buf.write_string("retain            = \{self.retain}\n")
  buf.write_string("max_age_days      = \{self.max_age_days}\n")
  buf.write_string("compress          = \{self.compress}\n")
  buf.write_string("compression_level = \{self.compression_level}\n")
  buf.write_string("date_format       = \{self.date_format}\n")
  buf.write_string("worker_interval   = \{self.worker_interval}s\n")
  buf.write_string("rotate_interval   = \{self.rotate_interval}\n")
  let tz_display = if self.tz.length() == 0 { "<system>" } else { self.tz }
  buf.write_string("tz                = \{tz_display}\n")
  buf.write_string("rotate_module     = \{self.rotate_module}\n")
  buf.to_string()
}
