///|
/// Background loops: log rotation, gzip compression and resource monitoring.
///
/// These run as long-lived coroutines inside the daemon's task group.

///|
/// Parse a fixed UTC offset such as `UTC+8`, `GMT-5`, `+05:30` or `-0800`.
/// Returns `None` for named zones (e.g. `America/New_York`).
pub fn parse_fixed_tz(tz : String) -> Int? {
  let mut body = tz.trim().to_owned()
  let upper = body.to_upper()
  if upper.has_prefix("UTC") {
    body = body.view(start_offset=3, end_offset=body.length()).to_owned()
  } else if upper.has_prefix("GMT") {
    body = body.view(start_offset=3, end_offset=body.length()).to_owned()
  }
  let trimmed = body.trim().to_owned()
  if trimmed.length() == 0 {
    return Some(0)
  }
  let sign_char = match trimmed.get_char(0) {
    Some(c) => c
    None => return None
  }
  let sign = if sign_char == '+' {
    1
  } else if sign_char == '-' {
    -1
  } else {
    return None
  }
  let digits = trimmed.view(start_offset=1, end_offset=trimmed.length())
  let (hour_text, minute_text) = match digits.split_once(":") {
    Some((h, m)) => (h, m)
    None =>
      if digits.length() == 4 {
        (
          digits.view(start_offset=0, end_offset=2),
          digits.view(start_offset=2, end_offset=4),
        )
      } else {
        (
          digits,
          digits.view(start_offset=digits.length(), end_offset=digits.length()),
        )
      }
  }
  let hours = match @pm3.parse_non_negative_int(hour_text) {
    Some(h) => h
    None => return None
  }
  let minutes = if minute_text.length() == 0 {
    0
  } else {
    match @pm3.parse_non_negative_int(minute_text) {
      Some(m) => m
      None => return None
    }
  }
  if hours > 18 || minutes > 59 {
    return None
  }
  Some(sign * (hours * 3600 + minutes * 60))
}

///|
/// Resolve the UTC offset for file names. Named zones are delegated to
/// `date +%z`, which reads the system tz database.
pub async fn resolve_tz_offset(tz : String, epoch_secs : Int64) -> Int {
  if tz.length() == 0 {
    return pm3_local_offset(epoch_secs)
  }
  match parse_fixed_tz(tz) {
    Some(offset) => offset
    None => {
      let result = @process.collect_stdout(
        "date",
        ["+%z"],
        extra_env=Map([("TZ", tz)]),
      ) catch {
        _ => return pm3_local_offset(epoch_secs)
      }
      let (_, data) = result
      let text = data.text().trim().to_owned() catch {
          _ => return pm3_local_offset(epoch_secs)
        }
      // `date +%z` prints e.g. `+0800`.
      match parse_fixed_tz(text) {
        Some(offset) => offset
        None => pm3_local_offset(epoch_secs)
      }
    }
  }
}

///|
/// Extract the first run of decimal digits in `text` as an integer.
fn first_integer(text : StringView) -> Int64? {
  let mut start = -1
  for i in 0..<text.length() {
    let is_digit = match text.get_char(i) {
      Some(c) => c >= '0' && c <= '9'
      None => false
    }
    if is_digit {
      if start < 0 {
        start = i
      }
    } else if start >= 0 {
      return parse_int64_range(text, start, i)
    }
  }
  if start >= 0 {
    parse_int64_range(text, start, text.length())
  } else {
    None
  }
}

///|
fn parse_int64_range(text : StringView, start : Int, end : Int) -> Int64? {
  let mut value = 0L
  for i in start..<end {
    match text.get_char(i) {
      Some(c) => value = value * 10L + (c.to_int() - '0'.to_int()).to_int64()
      None => return None
    }
  }
  Some(value)
}

///|
/// Resident set size in bytes, read from `/proc/<pid>/status`.
pub async fn read_rss_bytes(pid : Int) -> Int64 {
  let path = "/proc/\{pid}/status"
  let text = @fs.read_file(path).text() catch { _ => return 0L }
  for line in text.split("\n") {
    if line.has_prefix("VmRSS:") {
      match first_integer(line) {
        Some(kb) => return kb * 1024L
        None => return 0L
      }
    }
  }
  0L
}

///|
/// `(utime + stime)` in clock ticks, read from `/proc/<pid>/stat`.
pub async fn read_cpu_ticks(pid : Int) -> Int64 {
  let path = "/proc/\{pid}/stat"
  let text = @fs.read_file(path).text() catch { _ => return 0L }
  let close = match text.rev_find(")") {
    Some(i) => i
    None => return 0L
  }
  let rest = text.view(start_offset=close + 1, end_offset=text.length())
  let tokens : Array[String] = []
  for token in rest.split(" ") {
    if token.length() > 0 {
      tokens.push(token.to_owned())
    }
  }
  // tokens[0] is `state` (field 3); utime is field 14, stime field 15.
  if tokens.length() < 13 {
    return 0L
  }
  let utime = match first_integer(tokens[11]) {
    Some(v) => v
    None => 0L
  }
  let stime = match first_integer(tokens[12]) {
    Some(v) => v
    None => 0L
  }
  utime + stime
}

///|
/// The periodic rotation/prune loop.
///
/// Wakes once a second so that `pm3 set logrotate:worker_interval` and cron
/// changes take effect quickly; the size/prune pass itself runs every
/// `worker_interval` seconds.
pub async fn run_logrotate_loop(state : DaemonState) -> Unit {
  let mut elapsed = 0
  let mut forced_expr = ""
  let mut next_forced = -1L
  while state.running {
    @async.sleep(1000)
    if !state.running {
      break
    }
    elapsed = elapsed + 1
    let now = @async.now() / 1000L
    let offset = resolve_tz_offset(state.config.tz, now)
    // Cron-driven forced rotation, evaluated every tick.
    let expr = state.config.rotate_interval
    if expr != forced_expr {
      forced_expr = expr
      next_forced = match @pm3.parse_cron(expr) {
        Some(spec) =>
          match @pm3.next_cron_fire(spec, now - 1L, offset) {
            Some(t) => t
            None => -1L
          }
        None => -1L
      }
    }
    if next_forced > 0L && now >= next_forced {
      for _, sink in state.sinks {
        sink.request_rotate()
      }
      next_forced = match @pm3.parse_cron(expr) {
        Some(spec) =>
          match @pm3.next_cron_fire(spec, now, offset) {
            Some(t) => t
            None => -1L
          }
        None => -1L
      }
    }
    let interval = if state.config.worker_interval < 1 {
      1
    } else {
      state.config.worker_interval
    }
    if elapsed < interval {
      continue
    }
    elapsed = 0
    for _, sink in state.sinks {
      sink.tz_offset = offset
      sink.maybe_rotate()
      sink.prune(now)
    }
  }
}

///|
/// The gzip worker: rotates produce paths, this loop compresses them.
pub async fn run_compress_loop(state : DaemonState) -> Unit {
  while state.running {
    let path = state.compress_queue.get()
    if !state.running {
      break
    }
    compress_file(path)
  }
}

///|
/// Gzip `path` into `path + ".gz"` and remove the original.
async fn compress_file(path : String) -> Unit {
  let gz = path + ".gz"
  let input = @fs.open(path, mode=@fs.ReadOnly, create_mode=@fs.OpenExisting) catch {
    _ => return
  }
  let output = @fs.open(
    gz,
    mode=@fs.WriteOnly,
    create_mode=@fs.CreateOrTruncate,
  ) catch {
    _ => {
      input.close()
      return
    }
  }
  let ok = try {
    let encoder = @gzip.Encoder(output)
    encoder.write_reader(input)
    encoder.end()
    true
  } catch {
    _ => false
  }
  input.close()
  output.close()
  if ok {
    @fs.remove(path) catch {
      _ => ()
    }
  } else {
    @fs.remove(gz) catch {
      _ => ()
    }
  }
}

///|
/// The resource monitor: keeps `memory`/`cpu` fresh and enforces
/// `max_memory_restart`.
pub async fn run_monitor_loop(
  group : @async.TaskGroup[Unit],
  state : DaemonState,
) -> Unit {
  let clk = pm3_clk_tck().to_int64()
  while state.running {
    @async.sleep(2000)
    if !state.running {
      break
    }
    for _, managed in state.ordered() {
      let app = managed.app
      match managed.proc {
        None => ()
        Some(proc) => {
          let pid = proc.pid
          app.memory = read_rss_bytes(pid)
          let ticks = read_cpu_ticks(pid)
          let now = @async.now()
          if clk > 0L && managed.last_cpu_at > 0L {
            let dt = (now - managed.last_cpu_at).to_double() / 1000.0
            if dt > 0.0 {
              let dticks = (ticks - managed.last_cpu_ticks).to_double()
              let pct = dticks / clk.to_double() / dt * 100.0
              app.cpu = if pct < 0.0 { 0.0 } else { pct }
            }
          }
          managed.last_cpu_ticks = ticks
          managed.last_cpu_at = now
          if app.max_memory_restart > 0L &&
            app.memory > app.max_memory_restart &&
            app.status == @pm3.status_online {
            restart_managed(group, state, managed)
          }
        }
      }
    }
  }
}
