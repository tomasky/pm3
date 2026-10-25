///|
/// The daemon log.
///
/// PM2 routes every daemon-side `console.*` call through `overrideConsole`,
/// which prefixes each line with `<formatted time>: PM2 <method>: `. The
/// format comes from `PM2_LOG_DATE_FORMAT` (default `YYYY-MM-DDTHH:mm:ss`)
/// and an empty value turns the prefix off; pm3 reads `PM3_LOG_DATE_FORMAT`
/// first and falls back to PM2's variable so a drop-in environment keeps
/// working, and applies the same default and empty-string semantics.

///|
/// The format for the daemon log's line prefix.
fn daemon_log_format() -> String {
  for name in ["PM3_LOG_DATE_FORMAT", "PM2_LOG_DATE_FORMAT"] {
    match @env.get_env_var(name) {
      Some(value) => return value
      None => ()
    }
  }
  "YYYY-MM-DDTHH:mm:ss"
}

///|
/// The `<time>: ` prefix a daemon log line carries, or the empty string when
/// the format is empty (PM2 then writes the bare message).
fn daemon_log_stamp(
  epoch_secs : Int64,
  offset_secs : Int32,
  fmt : String,
) -> String {
  if fmt.is_empty() {
    return ""
  }
  @pm3.format_timestamp(epoch_secs, offset_secs, fmt) + ": "
}

///|
/// One daemon log line, rendered the way PM2's console wrapper renders it:
/// `<time>: PM3 log: <message>`.
fn daemon_line(
  epoch_secs : Int64,
  offset_secs : Int32,
  fmt : String,
  msg : String,
) -> String {
  let level = if fmt.is_empty() { "" } else { "PM3 log: " }
  daemon_log_stamp(epoch_secs, offset_secs, fmt) + level + msg + "\n"
}

///|
/// Write one line to the daemon log. The client that spawns the daemon
/// redirects its stderr to `pm3.log`.
async fn daemon_log(msg : String) -> Unit {
  let now = @env.now().reinterpret_as_int64() / 1000L
  @stdio.stderr.write(
    daemon_line(now, pm3_local_offset(now), daemon_log_format(), msg),
  ) catch {
    _ => ()
  }
}

///|
/// `key : value`, with the key padded to 20 columns — PM2's `fmt.field`.
fn daemon_field(key : String, value : String) -> String {
  @pm3.pad_right(key, 20, ' ') + " : " + value
}

///|
/// `uname(2)` machine in Node's `process.arch` naming, which is what PM2
/// prints as "Current arch" in its banner.
fn daemon_arch() -> String {
  match pm3_uname_machine() {
    1 => "x64"
    2 => "arm64"
    3 => "arm"
    4 => "ia32"
    5 => "ppc64"
    6 => "s390x"
    7 => "riscv64"
    _ => "unknown"
  }
}

///|
/// The banner PM2 logs when its daemon starts ("--- New PM2 Daemon started"),
/// with pm3's own values. Fields PM2 has no pm3 counterpart for (the Node.js
/// version, the bus socket, the concurrent-action limit) are left out, and
/// the two IPC socket paths collapse into pm3's single port file.
fn daemon_banner_lines(
  epoch_secs : Int64,
  offset_secs : Int32,
  exe : String,
) -> Array[String] {
  let sep = "==============================================================================="
  [
    sep,
    @pm3.pad_right("--- New PM3 Daemon started ", 79, '-'),
    daemon_field(
      "Time",
      @pm3.format_timestamp(
        epoch_secs, offset_secs, "ddd MMM DD YYYY HH:mm:ss [GMT]ZZ",
      ),
    ),
    daemon_field("PM3 version", @pm3.pm3_version),
    daemon_field("Current arch", daemon_arch()),
    daemon_field("PM3 home", @pm3.pm3_state_dir()),
    daemon_field("PM3 PID file", @pm3.pm3_pid_path()),
    daemon_field("PM3 port file", @pm3.pm3_port_path()),
    daemon_field("Application log path", @pm3.pm3_log_dir()),
    daemon_field("Worker Interval", monitor_interval_ms.to_string()),
    daemon_field("Process dump file", @pm3.pm3_dump_path()),
    daemon_field("SIGTERM timeout", @pm3.default_kill_timeout_ms.to_string()),
    daemon_field("Runtime Binary", exe),
    sep,
  ]
}

///|
/// Write the startup banner to the daemon log.
async fn daemon_banner(exe : String) -> Unit {
  let now = @env.now().reinterpret_as_int64() / 1000L
  for line in daemon_banner_lines(now, pm3_local_offset(now), exe) {
    daemon_log(line)
  }
}
