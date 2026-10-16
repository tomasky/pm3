///|
/// The pm3 command-line interface.

///|
/// `exit(3)`, so a command that failed can return a non-zero status the way
/// PM2 does.
extern "C" fn pm3_exit(status : Int) -> Unit = "pm3_exit"

///|
/// Set by `print_error`: the command failed, so the process exits non-zero.
let command_failed : Ref[Bool] = Ref(false)

///|
async fn print_line(text : String) -> Unit {
  @stdio.stdout.write(text + "\n")
}

///|
/// Report a failure on standard error. Every call site means the command could
/// not do what it was asked to, so the exit status becomes non-zero.
async fn print_error(text : String) -> Unit {
  command_failed.val = true
  @stdio.stderr.write(text + "\n")
}

///|
/// Whether the CLI should colour its output. Kept in one place so every view
/// agrees.
fn colors() -> Bool {
  @pm3.colors_enabled()
}

///|
/// PM2's colours for the process states: green while it runs, blue while it
/// is coming up, yellow while it is being restarted or has never run, red
/// when it is not running.
fn style_status(status : String) -> String {
  match status {
    "online" => @pm3.green_bold(status)
    "launching" => @pm3.blue_bold(status)
    "restarting" => @pm3.yellow_bold(status)
    "created" => @pm3.yellow_bold(status)
    _ => @pm3.red_bold(status)
  }
}

///|
/// A bordered table with a header row, in PM2's shape and colours.
fn render_table(headers : Array[String], rows : Array[Array[String]]) -> String {
  @pm3.render_box(Some(headers), rows, style=colors())
}

///|
/// Decode the app records a daemon response carries. A payload this build
/// cannot read means the daemon is not this build (or is broken), which must
/// be reported: an empty list is a legitimate answer, an unreadable one is
/// not.
async fn decode_apps(response : @pm3.Response) -> Array[@pm3.App]? {
  match @pm3.app_records_from_json(response.data) {
    Some(apps) => Some(apps)
    None => {
      print_error(
        "pm3: could not read the process list from the daemon; run `pm3 update` to restart it",
      )
      None
    }
  }
}

///|
/// Fetch the process list from the daemon. The error is already reported when
/// this returns `None`.
async fn fetch_apps() -> Array[@pm3.App]? {
  let response = call(@pm3.Request::new("list"))
  if !response.ok {
    print_error("pm3: \{response.msg}")
    return None
  }
  decode_apps(response)
}

///|
/// PM2 caps the name column at 40 characters of width — 38 of content — and
/// cuts a longer name with a single-character ellipsis (`fitColumn` in
/// `pm2-ls.js`).
fn fit_name_pm2(name : String) -> String {
  if name.length() <= 38 {
    return name
  }
  name.view(start_offset=0, end_offset=37).to_owned() + "…"
}

///|
/// `pm3 list`
async fn cmd_list(args : Array[String]) -> Unit {
  if args.contains("--json") {
    // The raw payload is passed through, so it works even against a daemon
    // whose records this build cannot fully read.
    let response = call(@pm3.Request::new("list"))
    if !response.ok {
      print_error("pm3: \{response.msg}")
      return
    }
    print_line(response.data.stringify())
    return
  }
  let apps = match fetch_apps() {
    Some(apps) => apps
    None => return
  }
  if apps.length() == 0 {
    print_line("no processes managed by pm3")
    return
  }
  let now = @async.now()
  // PM2's columns, in PM2's order. `mode`, `user` and `watching` are fixed
  // for now: pm3 only forks, and tracks neither watch mode nor a per-app uid.
  let headers = [
    "id", "name", "namespace", "version", "mode", "pid", "uptime", "↺", "status",
    "cpu", "mem", "user", "watching",
  ]
  let rows : Array[Array[String]] = []
  // Totals are accumulated over the running processes only: a stopped one
  // holds no memory, and adding the last sample it was measured with would
  // report memory that is no longer there.
  let mut total_cpu = 0.0
  let mut total_mem = 0L
  let mut online = 0
  for app in apps {
    let status = if app.status == @pm3.status_errored {
      "errored(\{app.exit_code})"
    } else {
      app.status
    }
    // Like PM2, the uptime cell is a duration only while the process is
    // online; anything else shows `0`.
    let uptime = if app.status == @pm3.status_online && app.started_at > 0L {
      @pm3.format_uptime_pm2(now - app.started_at)
    } else {
      "0"
    }
    if app.is_online() {
      online = online + 1
      total_cpu = total_cpu + app.cpu
      total_mem = total_mem + app.memory
    }
    rows.push([
      @pm3.bold_cyan(app.pm_id.to_string()),
      fit_name_pm2(app.name),
      app.app_namespace,
      if app.version.length() > 0 { app.version } else { "N/A" },
      @pm3.bold_inverse("fork"),
      app.pid.to_string(),
      uptime,
      app.restarts.to_string(),
      style_status(status),
      @pm3.format_cpu_percent(app.cpu),
      @pm3.format_size_pm2(app.memory),
      @pm3.style_bold(
        if app.username.length() > 0 { app.username } else { "N/A" },
      ),
      @pm3.style_gray("disabled"),
    ])
  }
  print_line(render_table(headers, rows))
  print_line(
    "\{online}/\{apps.length()} online   total cpu " +
    @pm3.format_cpu_percent(total_cpu) +
    "   total mem " +
    @pm3.format_size_pm2(total_mem),
  )
}

///|
/// `pm3 describe <name>`
async fn cmd_describe(args : Array[String]) -> Unit {
  if args.length() == 0 {
    print_error("pm3 describe: missing process name")
    return
  }
  let request = @pm3.Request::with_args("describe", [args[0]])
  let response = call(request)
  if !response.ok {
    print_error("pm3: \{response.msg}")
    return
  }
  let apps = match decode_apps(response) {
    Some(apps) => apps
    None => return
  }
  for app in apps {
    let now = @async.now()
    let lines : Array[(String, String)] = [
      ("pm_id", app.pm_id.to_string()),
      ("name", app.name),
      ("status", style_status(app.status)),
      ("pid", app.pid.to_string()),
      ("command", app.command_display()),
      (
        "interpreter",
        if app.interpreter.length() == 0 {
          "<direct>"
        } else {
          app.interpreter
        },
      ),
      (
        "interpreter args",
        if app.interpreter_args.length() == 0 {
          "<none>"
        } else {
          app.interpreter_args.join(" ")
        },
      ),
      ("cwd", if app.cwd.length() == 0 { "<inherited>" } else { app.cwd }),
      ("out log", app.out_log),
      (
        "err log",
        if app.merge_logs {
          "<merged into out log>"
        } else {
          app.err_log
        },
      ),
      ("autorestart", app.autorestart.to_string()),
      ("restarts", app.restarts.to_string()),
      ("unstable restarts", app.unstable_restarts.to_string()),
      ("max restarts", app.max_restarts.to_string()),
      ("restart delay", "\{app.restart_delay}ms"),
      ("min uptime", "\{app.min_uptime}ms"),
      ("kill timeout", "\{app.kill_timeout}ms"),
      ("kill signal", app.kill_signal),
      (
        "max memory restart",
        if app.max_memory_restart > 0L {
          @pm3.format_size_pm2(app.max_memory_restart)
        } else {
          "<disabled>"
        },
      ),
      ("memory", @pm3.format_size_pm2(app.memory)),
      ("cpu", @pm3.format_cpu_percent(app.cpu)),
      ("exit code", app.exit_code.to_string()),
      ("created at", app.created_at.to_string()),
      (
        "uptime",
        if app.is_online() {
          @pm3.format_duration(now - app.started_at)
        } else {
          "-"
        },
      ),
    ]
    let rows : Array[Array[String]] = []
    for entry in lines {
      let (key, value) = entry
      rows.push([key, value])
    }
    print_line("")
    print_line(
      @pm3.bold_inverse(
        " Describing process with id \{app.pm_id} - name \{app.name} ",
      ),
    )
    @stdio.stdout.write(@pm3.render_box(None, rows, style=colors()))
  }
}

///|
/// Parse `pm3 start` arguments into a request.
fn parse_start(args : Array[String]) -> Result[@pm3.Request, String] {
  let request = @pm3.Request::new("start")
  let mut script = ""
  let process_args : Array[String] = []
  let env : Map[String, String] = Map([])
  let mut after_separator = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if after_separator {
      process_args.push(arg)
      i = i + 1
      continue
    }
    if arg == "--" {
      after_separator = true
      i = i + 1
      continue
    }
    let needs_value = [
      "--name", "-n", "--namespace", "--interpreter", "-i", "--interpreter-args",
      "--node-args", "--cwd", "--out-file", "--err-file", "--log-date-format",
      "--max-restarts", "--restart-delay", "--min-uptime", "--max-memory-restart",
      "--kill-timeout", "--kill-signal", "--stop-exit-codes", "--env", "-e",
    ]
    if needs_value.contains(arg) {
      if i + 1 >= args.length() {
        return Err("option \{arg} requires a value")
      }
      let value = args[i + 1]
      match arg {
        "--name" | "-n" => request.opts.set("name", value)
        "--namespace" => request.opts.set("namespace", value)
        "--interpreter" | "-i" => request.opts.set("interpreter", value)
        "--interpreter-args" | "--node-args" =>
          request.opts.set("interpreter_args", value)
        "--cwd" => request.opts.set("cwd", value)
        "--out-file" => request.opts.set("out_log", value)
        "--err-file" => request.opts.set("err_log", value)
        "--log-date-format" => request.opts.set("log_date_format", value)
        "--max-restarts" => request.opts.set("max_restarts", value)
        "--restart-delay" => request.opts.set("restart_delay", value)
        "--min-uptime" => request.opts.set("min_uptime", value)
        "--max-memory-restart" => request.opts.set("max_memory_restart", value)
        "--kill-timeout" => request.opts.set("kill_timeout", value)
        "--kill-signal" => request.opts.set("kill_signal", value)
        "--stop-exit-codes" => request.opts.set("stop_exit_codes", value)
        "--env" | "-e" =>
          match value.split_once("=") {
            Some((key, val)) => env.set(key.trim().to_owned(), val.to_owned())
            None => return Err("--env expects KEY=VALUE")
          }
        _ => ()
      }
      i = i + 2
      continue
    }
    if arg == "--merge-logs" {
      request.opts.set("merge_logs", "true")
      i = i + 1
      continue
    }
    if arg == "--no-autorestart" {
      request.opts.set("autorestart", "false")
      i = i + 1
      continue
    }
    if arg.has_prefix("-") {
      // Before the script, an unrecognized option is a mistake. After it, it
      // belongs to the program: `pm3 start sh -c '...'` has to work.
      if script.length() == 0 {
        return Err("unknown option \{arg}")
      }
      process_args.push(arg)
      i = i + 1
      continue
    }
    if script.length() == 0 {
      script = arg
    } else {
      process_args.push(arg)
    }
    i = i + 1
  }
  if script.length() == 0 {
    return Err(
      "start: missing script — pass a program to run, or a pm3.toml / pm3.json describing the apps",
    )
  }
  if env.length() > 0 {
    request.opts.set("env_json", @json.to_json(env).stringify())
  }
  request.args.push(script)
  for value in process_args {
    request.args.push(value)
  }
  Ok(request)
}

///|
/// The config file `pm3 start` should read instead of a single script, if any.
///
/// An explicit `--config <file>` wins; otherwise a bare `pm3 start` falls back
/// to the first config file pm3 can find. A positional argument only counts as
/// a config file when it is named `.toml` or `.json` and actually exists, so
/// `pm3 start ./server.json` still runs a program.
///
/// There is deliberately no `-c` shorthand: `pm3 start sh -c '...'` is a
/// perfectly ordinary command line and must keep working.
fn start_config_path(args : Array[String]) -> Result[String?, String] {
  let mut index = 0
  while index < args.length() {
    if args[index] == "--config" {
      if index + 1 >= args.length() {
        return Err("option --config requires a value")
      }
      return Ok(Some(args[index + 1]))
    }
    index = index + 1
  }
  if args.length() == 0 {
    return Ok(@pm3.find_app_config())
  }
  if @pm3.is_app_config_file(args[0]) {
    return Ok(Some(args[0]))
  }
  Ok(None)
}

///|
/// `pm3 start --config <file>` — start every app the file declares.
async fn cmd_start_config(path : String) -> Unit {
  let apps = match @pm3.load_apps_from_file(path) {
    Ok(apps) => apps
    Err(message) => {
      print_error("pm3: \{path}: \{message}")
      return
    }
  }
  let request = @pm3.Request::new(@pm3.cmd_start_apps)
  request.args.push(@json.to_json(apps).stringify())
  let response = call(request)
  if response.ok {
    print_line(response.msg)
    // `pm2 start <config>` shows the list once every app came up; a config
    // with a failing app reports that and nothing else.
    cmd_list([])
  } else {
    print_error("pm3: \{response.msg}")
  }
}

///|
/// Resolve a `pm3 start <script>` request against the directory the command
/// was run in, so the record the daemon saves does not depend on where the
/// daemon happens to live (see `resolve_start_path`).
fn resolve_start_request(request : @pm3.Request) -> Unit {
  if request.args.length() == 0 {
    return
  }
  let base = match @env.current_dir() {
    Some(dir) => dir
    None => return
  }
  let (script, cwd) = @pm3.resolve_start_path(
    request.args[0],
    request.opts.get("cwd"),
    base,
  )
  request.args[0] = script
  match cwd {
    Some(dir) => request.opts.set("cwd", dir)
    None => ()
  }
}

///|
/// `pm3 start ...`
async fn cmd_start(args : Array[String]) -> Unit {
  match start_config_path(args) {
    Err(message) => {
      print_error("pm3: \{message}")
      return
    }
    Ok(Some(path)) => return cmd_start_config(path)
    Ok(None) => ()
  }
  let request = match parse_start(args) {
    Ok(request) => request
    Err(message) => {
      print_error("pm3: \{message}")
      return
    }
  }
  resolve_start_request(request)
  let response = call(request)
  if response.ok {
    print_line(response.msg)
    // PM2 prints the list of everything it manages once an app is up.
    cmd_list([])
  } else {
    print_error("pm3: \{response.msg}")
  }
}

///|
/// `pm3 stop|restart|delete [name]`
async fn cmd_lifecycle(command : String, args : Array[String]) -> Unit {
  let name = if args.length() > 0 { args[0] } else { "" }
  let request = if name.length() > 0 {
    @pm3.Request::with_args(command, [name])
  } else {
    @pm3.Request::new(command)
  }
  let response = call(request)
  if response.ok {
    print_line(response.msg)
    // PM2 ends these with the process list, so the state the action left
    // behind is right there.
    cmd_list([])
  } else {
    print_error("pm3: \{response.msg}")
  }
}

///|
/// What a log file's lines are: program output, program error output, or the
/// daemon's own log.
priv enum LogKind {
  Out
  Err
  Daemon
}

///|
/// Whether a log file carries the program's error output, which PM2 colours
/// red.
fn is_error_log(kind : LogKind) -> Bool {
  match kind {
    Err => true
    _ => false
  }
}

///|
/// One file `pm3 logs` reads, with the prefix its lines carry.
priv struct LogFile {
  path : String
  /// The `pm_id|name` label PM2 puts on every line; `PM3` for the daemon.
  label : String
  kind : LogKind
  /// Modification time, used to order the files the way PM2 orders them.
  mtime : Int64
}

///|
/// Modification time as a single number, or 0 when the file cannot be read.
async fn log_mtime(path : String) -> Int64 {
  let (seconds, nanos) = @fs.mtime(path) catch { _ => return 0L }
  seconds * 1_000_000_000L + nanos.to_int64()
}

///|
/// The label PM2 prints in front of a process's log lines.
fn log_label(app : @pm3.App) -> String {
  "\{app.pm_id}|\{app.name}"
}

///|
/// Pad (or cut) a label to `width` so log lines stay aligned, like PM2's
/// `pad()`.
fn pad_label(label : String, width : Int) -> String {
  if label.length() >= width {
    label.view(start_offset=0, end_offset=width).to_owned()
  } else {
    @pm3.pad_right(label, width, ' ')
  }
}

///|
/// The coloured `id|name | ` prefix a log line carries.
fn log_prefix(kind : LogKind, label : String, width : Int) -> String {
  let text = pad_label(label, width) + " | "
  match kind {
    Out => @pm3.style_green(text)
    Err => @pm3.style_red(text)
    Daemon => @pm3.style_blue(text)
  }
}

///|
/// Whether the list already holds a file with this path — PM2 never prints
/// the same log file twice, even when two apps share it.
fn collects_path(files : Array[LogFile], path : String) -> Bool {
  for file in files {
    if file.path == path {
      return true
    }
  }
  false
}

///|
/// Order log files by modification time, oldest first — the order PM2 tails
/// them in. The list is tiny, so a hand-rolled insertion sort is enough.
fn sort_log_files(files : Array[LogFile]) -> Unit {
  let mut i = 1
  while i < files.length() {
    let current = files[i]
    let mut j = i
    while j > 0 && files[j - 1].mtime > current.mtime {
      files[j] = files[j - 1]
      j = j - 1
    }
    files[j] = current
    i = i + 1
  }
}

///|
/// The files `pm3 logs` reads, in the order PM2 shows them: the daemon's own
/// log first (only when everything is being shown, and nothing narrowed the
/// view), then every app log by modification time.
async fn collect_log_files(
  apps : Array[@pm3.App],
  name : String,
  use_out : Bool,
  use_err : Bool,
  raw : Bool,
) -> Array[LogFile] {
  let files : Array[LogFile] = []
  if name.length() == 0 && !use_out && !use_err && !raw {
    let path = @pm3.pm3_daemon_log_path()
    let exists = @fs.exists(path) catch { _ => false }
    if exists {
      files.push({ path, label: "PM3", kind: Daemon, mtime: log_mtime(path), })
    }
  }
  let app_files : Array[LogFile] = []
  for app in apps {
    if !use_err {
      app_files.push({
        path: app.out_log,
        label: log_label(app),
        kind: Out,
        mtime: log_mtime(app.out_log),
      })
    }
    if !use_out && !app.merge_logs {
      app_files.push({
        path: app.err_log,
        label: log_label(app),
        kind: Err,
        mtime: log_mtime(app.err_log),
      })
    }
  }
  sort_log_files(app_files)
  for file in app_files {
    if file.path.length() == 0 || file.path.to_lower() == "/dev/null" {
      continue
    }
    if !collects_path(files, file.path) {
      files.push(file)
    }
  }
  files
}

///|
/// The lines of `bytes`, split at `\n`: the empty segment a trailing newline
/// leaves is dropped, and a last line without a newline is kept. The views
/// point into `bytes`, so no copy is made.
fn byte_lines(bytes : Bytes) -> Array[BytesView] {
  let out : Array[BytesView] = []
  let length = bytes.length()
  let mut start = 0
  let mut i = 0
  while i < length {
    if bytes.unsafe_get(i) == b'\n' {
      out.push(bytes[start:i])
      start = i + 1
    }
    i = i + 1
  }
  if start < length {
    out.push(bytes[start:length])
  }
  out
}

///|
/// Print the last `lines` lines of one log file, each under its `id|name`
/// prefix, the way `pm2 logs --nostream` does.
///
/// Lines are written as the bytes they were, so a log that is not valid UTF-8
/// still shows what the program wrote.
async fn tail_log_file(file : LogFile, lines : Int, raw : Bool) -> Unit {
  let exists = @fs.exists(file.path) catch { _ => false }
  if !exists {
    return
  }
  let data = @fs.read_file(file.path) catch { _ => return }
  let all = byte_lines(data.binary())
  print_line(@pm3.style_gray(file.path + " last \{lines} lines:"))
  let start = if all.length() > lines { all.length() - lines } else { 0 }
  let mut printed = 0
  for i in start..<all.length() {
    write_log_line(file, all[i], 10, raw)
    printed = printed + 1
  }
  if printed > 0 {
    print_line("")
  }
}

///|
/// Write one log line: the bytes as they are under `--raw` (stderr goes to
/// the error stream there, like PM2), or the coloured prefix plus the bytes.
async fn write_log_line(
  file : LogFile,
  line : BytesView,
  width : Int,
  raw : Bool,
) -> Unit {
  if raw {
    if is_error_log(file.kind) {
      @stdio.stderr.write(line)
      @stdio.stderr.write("\n")
    } else {
      @stdio.stdout.write(line)
      @stdio.stdout.write("\n")
    }
  } else {
    @stdio.stdout.write(log_prefix(file.kind, file.label, width))
    @stdio.stdout.write(line)
    @stdio.stdout.write("\n")
  }
}

///|
/// Print every line of `bytes` (which ends with a newline) that has content.
/// Empty lines are skipped, the way `pm2 logs` streams them.
async fn stream_lines(
  file : LogFile,
  bytes : Bytes,
  width : Int,
  raw : Bool,
) -> Unit {
  let length = bytes.length()
  let mut start = 0
  let mut i = 0
  while i < length {
    if bytes.unsafe_get(i) == b'\n' {
      if i > start {
        write_log_line(file, bytes[start:i], width, raw)
      }
      start = i + 1
    }
    i = i + 1
  }
}

///|
/// Index of the last `\n` in `bytes`, when there is one.
fn last_newline(bytes : Bytes) -> Int? {
  let mut index : Int? = None
  for i in 0..<bytes.length() {
    if bytes[i] == b'\n' {
      index = Some(i)
    }
  }
  index
}

///|
/// Follow one log file, printing every line appended after this call under
/// the same prefix the tail used. Lines are assembled from whole reads, so a
/// line split across two read chunks is printed once.
async fn follow_log_file(file : LogFile, width : Int, raw : Bool) -> Unit {
  let mut offset = @fs.file_size(file.path) catch { _ => 0L }
  let mut rest : Bytes = b""
  while true {
    @async.sleep(400)
    let size = @fs.file_size(file.path) catch { _ => continue }
    if size < offset {
      // Rotated or truncated: start over from the top of the new file.
      offset = 0L
      rest = b""
    }
    if size > offset {
      let handle = @fs.open(
        file.path,
        mode=@fs.ReadOnly,
        create_mode=@fs.OpenExisting,
      ) catch {
        _ => continue
      }
      let want = (size - offset).to_int()
      let buf = FixedArray::make(want, b'\x00')
      let got = handle.read_at(buf, position=offset) catch { _ => 0 }
      handle.close()
      if got > 0 {
        offset = offset + got.to_int64()
        let chunk = rest + buf.unsafe_reinterpret_as_bytes()[:got].to_owned()
        match last_newline(chunk) {
          None => rest = chunk
          Some(index) => {
            let complete = chunk[:index + 1].to_owned()
            rest = chunk[index + 1:].to_owned()
            stream_lines(file, complete, width, raw)
          }
        }
      }
    }
  }
}

///|
/// `pm3 logs [name|id] [--lines N] [--follow] [--out|--err] [--raw]`
///
/// The tail is printed the way `pm2 logs` prints it: the daemon's own log
/// first, then every app log under an aligned, colour-coded `id|name` prefix.
/// `--follow` then streams new lines like `pm2 logs` does by default.
async fn cmd_logs(args : Array[String]) -> Unit {
  let mut name = ""
  let mut lines = 20
  let mut follow = false
  let mut use_err = false
  let mut use_out = false
  let mut raw = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--lines" | "-n" =>
        if i + 1 < args.length() {
          match @pm3.parse_non_negative_int(args[i + 1]) {
            Some(value) => lines = value
            None => ()
          }
          i = i + 1
        }
      "--follow" | "-f" => follow = true
      "--err" | "--error" => use_err = true
      "--out" => use_out = true
      "--raw" => raw = true
      "--nostream" => () // tail without following: the default here
      _ =>
        if arg.has_prefix("-") {
          print_error("pm3: unknown option \{arg}")
          return
        } else if name.length() == 0 {
          // PM2 takes a single process name or id here; extra words are
          // ignored, so the first one wins.
          name = arg
        }
    }
    i = i + 1
  }
  let apps = match fetch_apps() {
    Some(apps) => apps
    None => return
  }
  let is_all = name.length() == 0
  let selected : Array[@pm3.App] = []
  for app in apps {
    let by_id = match @pm3.parse_non_negative_int(name) {
      Some(id) => id == app.pm_id
      None => false
    }
    if is_all || app.name == name || by_id {
      selected.push(app)
    }
  }
  if !is_all && selected.length() == 0 {
    print_error("pm3: no matching process")
    return
  }
  let files = collect_log_files(selected, name, use_out, use_err, raw)
  if lines > 0 {
    let display_id = if is_all { "all" } else { name }
    let plural = if is_all { "es" } else { "" }
    print_line(
      @pm3.bold_gray(
        "[TAILING] Tailing last \{lines} lines for [\{display_id}] process\{plural} (change the value with --lines option)",
      ),
    )
    for file in files {
      tail_log_file(file, lines, raw)
    }
  }
  if follow {
    // PM2's streaming prefix grows to fit the longest `id|name`; with the
    // whole list in hand it is known before the first line arrives.
    let mut width = 3
    for file in files {
      if file.label.length() + 1 > width {
        width = file.label.length() + 1
      }
    }
    @async.with_task_group(group => {
      for file in files {
        group.spawn_bg(() => follow_log_file(file, width, raw))
      }
      while true {
        @async.sleep(1000)
      }
    })
  }
}

///|
/// `pm3 flush` / `pm3 reloadLogs`
async fn cmd_simple(command : String) -> Unit {
  let response = call(@pm3.Request::new(command))
  if response.ok {
    print_line(response.msg)
  } else {
    print_error("pm3: \{response.msg}")
  }
}

///|
/// `pm3 logrotate` and `pm3 set logrotate:<key> <value>`
async fn cmd_logrotate(args : Array[String]) -> Unit {
  if args.length() == 0 {
    let response = call(@pm3.Request::new("get_logrotate"))
    if !response.ok {
      print_error("pm3: \{response.msg}")
      return
    }
    let config : @pm3.LogrotateConfig = @json.from_json(response.data) catch {
      _ => @pm3.default_logrotate_config()
    }
    print_line(config.to_display())
    return
  }
  let mut key = args[0]
  let value = if args.length() >= 2 { args[1] } else { "" }
  if key.has_prefix("logrotate:") {
    key = key.view(start_offset=10, end_offset=key.length()).to_owned()
  }
  if value.length() == 0 {
    print_error("pm3: usage: pm3 set logrotate:<key> <value>")
    return
  }
  let response = call(@pm3.Request::with_args("set_logrotate", [key, value]))
  if response.ok {
    print_line(response.msg)
  } else {
    print_error("pm3: \{response.msg}")
  }
}

///|
/// `pm3 set ...` — currently only `logrotate:` keys are recognized.
async fn cmd_set(args : Array[String]) -> Unit {
  if args.length() >= 3 && args[0] == "logrotate" {
    cmd_logrotate([args[1], args[2]])
    return
  }
  if args.length() >= 2 && args[0].has_prefix("logrotate:") {
    cmd_logrotate([args[0], args[1]])
    return
  }
  print_error("pm3: usage: pm3 set logrotate:<key> <value>")
}

///|
/// `pm3 config` — show the active configuration file, or create one with
/// `pm3 config init [toml|json]`.
///
/// This one command deliberately does not talk to the daemon: configuration is
/// on disk, and a user who has a broken config needs to be able to read it
/// before anything else starts.
async fn cmd_config(args : Array[String]) -> Unit {
  if args.length() >= 1 && args[0] == "init" {
    let format = if args.length() >= 2 {
      match args[1] {
        "toml" => @pm3.Toml
        "json" => @pm3.Json
        other => {
          print_error(
            "pm3: unknown config format '\{other}'; expected toml or json",
          )
          return
        }
      }
    } else {
      @pm3.default_config_source().format
    }
    let force = args.contains("--force")
    match @pm3.write_default_config(format, force) {
      Ok(path) => print_line("wrote \{path}")
      Err(message) => print_error("pm3: \{message}")
    }
    return
  }
  if args.length() >= 1 && args[0] == "apps" {
    let rest : Array[String] = []
    for index in 1..<args.length() {
      rest.push(args[index])
    }
    cmd_config_apps(rest)
    return
  }
  let source = @pm3.active_config_source()
  print_line("config file: \{source.path}")
  match @pm3.read_config_file(source.path) {
    Ok(json) => print_line(json.stringify(indent=2))
    Err(_) =>
      print_line(
        @pm3.render_config(@pm3.default_logrotate_config(), source.format),
      )
  }
}

///|
/// `pm3 config apps [--config <file>] [--json]` — show what `pm3 start` would
/// bring up, without starting anything.
///
/// It reads the same file `pm3 start` would, by the same rules, and reports
/// what it finds — so it is both a preview and the way to validate a config
/// file without touching the daemon.
async fn cmd_config_apps(args : Array[String]) -> Unit {
  let json = args.contains("--json")
  let rest : Array[String] = []
  for arg in args {
    if arg != "--json" {
      rest.push(arg)
    }
  }
  let path = match start_config_path(rest) {
    Err(message) => {
      print_error("pm3: \{message}")
      return
    }
    Ok(Some(path)) => path
    Ok(None) => {
      print_line(
        "no config file found in this directory or \{@pm3.pm3_home()};" +
        " pass --config <file> to name one, or write a pm3.toml describing the apps",
      )
      return
    }
  }
  let apps = match @pm3.load_apps_from_file(path) {
    Ok(apps) => apps
    Err(message) => {
      print_error("pm3: \{path}: \{message}")
      return
    }
  }
  if json {
    print_line(@json.to_json(apps).stringify())
    return
  }
  let headers = ["name", "command", "cwd", "memory limit", "autorestart"]
  let rows : Array[Array[String]] = []
  for app in apps {
    rows.push([
      @pm3.truncate_text(app.name, 24),
      @pm3.truncate_text(app.command_display(), 44),
      @pm3.truncate_text(app.cwd, 24),
      if app.max_memory_restart == 0L {
        "-"
      } else {
        @pm3.format_size_pm2(app.max_memory_restart)
      },
      if app.autorestart {
        "yes"
      } else {
        "no"
      },
    ])
  }
  print_line("\{path} declares \{apps.length()} app(s):")
  print_line("")
  print_line(render_table(headers, rows))
  print_line(
    "pm3 start\{if rest.length() > 0 { " --config " + path } else { "" }}   # to start them",
  )
}

///|
/// `pm3 resurrect` — PM2 ends the restore with the list of what came back.
async fn cmd_resurrect() -> Unit {
  let response = call(@pm3.Request::new("resurrect"))
  if response.ok {
    print_line(response.msg)
    cmd_list([])
  } else {
    print_error("pm3: \{response.msg}")
  }
}

///|
/// `pm3 kill` — stop the daemon (leaves child processes stopped).
async fn cmd_kill() -> Unit {
  let response = call(@pm3.Request::new("kill"))
  print_line(response.msg)
}

///|
/// `pm3 update` — restart the daemon so it runs this build, the way
/// `pm2 update` does: save the list, kill the daemon, launch it again and
/// bring the saved processes back online.
async fn cmd_update() -> Unit {
  print_line(
    "Be sure to have the latest version by doing `npm install @tomasko/pm3@latest -g` before doing this procedure.",
  )
  let saved = call(@pm3.Request::new("save"))
  if !saved.ok {
    print_error("pm3: \{saved.msg}")
    return
  }
  print_line(saved.msg)
  let killed = call(@pm3.Request::new("kill"))
  if !killed.ok {
    print_error("pm3: \{killed.msg}")
    return
  }
  wait_for_daemon_exit()
  start_daemon()
  let restored = call(@pm3.Request::new("resurrect"))
  if !restored.ok {
    print_error("pm3: \{restored.msg}")
    return
  }
  print_line(restored.msg)
  print_line(@pm3.blue_bold(">>>>>>>>>> pm3 updated"))
  cmd_list([])
}

///|
/// `pm3 version`
async fn cmd_version() -> Unit {
  print_line("pm3 \{@pm3.pm3_version}")
}

///|
/// `pm3 help`
///
/// The layout follows PM2's: a `Usage:` line, then `Options:` and `Commands:`
/// sections whose two columns are aligned on the longest entry, exactly like
/// commander renders them for `pm2 --help`.
async fn print_help() -> Unit {
  let options : Array[(String, String)] = [
    ("-v, --version", "print the pm3 version"),
    ("-h, --help", "show this help"),
    ("--no-color", "disable colored output"),
  ]
  let commands : Array[(String, String)] = [
    ("start [options] [name|file|config]", "start and daemonize an app"),
    ("list | ls [--json]", "list managed processes"),
    ("describe <name|id>", "describe all parameters of a process"),
    ("desc <name|id>", "(alias) describe all parameters of a process"),
    ("info <name|id>", "(alias) describe all parameters of a process"),
    ("show <name|id>", "(alias) describe all parameters of a process"),
    ("stop [name|id|namespace|all]", "stop one or all processes"),
    ("restart [name|id|namespace|all]", "restart one or all processes"),
    ("delete [name|id|namespace|all]", "stop and delete one or all processes"),
    (
      "logs [name|id] [options]", "tail and stream logs (--follow, --lines N, --out, --err, --raw)",
    ),
    ("flush [name|id]", "empty the logs of one or all processes"),
    ("reloadLogs", "rotate the logs of all processes now"),
    ("logrotate", "show the log rotation policy"),
    ("set logrotate:<key> <value>", "change the log rotation policy"),
    ("config [init|apps] [...]", "show or create the global config file"),
    ("save", "save the process list"),
    ("resurrect", "bring saved processes back up"),
    ("update", "restart the daemon with this pm3 build"),
    ("kill", "kill the pm3 daemon"),
    ("version", "print the pm3 version"),
    ("help", "show this help"),
  ]
  let width = help_width([options, commands])
  let buf = StringBuilder()
  buf.write_string("\n")
  buf.write_string("  Usage: pm3 [cmd] app\n")
  buf.write_string("\n  Options:\n\n")
  buf.write_string(render_help_entries(options, width))
  buf.write_string("\n  Commands:\n\n")
  buf.write_string(render_help_entries(commands, width))
  print_line(buf.to_string().trim_end(chars="\n").to_owned())
}

///|
/// The longest left column over several help groups, so `pm3 --help` aligns
/// options and commands on the same column the way commander does.
fn help_width(groups : Array[Array[(String, String)]]) -> Int {
  let mut width = 0
  for group in groups {
    for entry in group {
      let (left, _) = entry
      if left.length() > width {
        width = left.length()
      }
    }
  }
  width
}

///|
/// Render a two-column help block: four spaces of indent, the left column
/// padded to `width`, two spaces, the description.
fn render_help_entries(
  entries : Array[(String, String)],
  width : Int,
) -> String {
  let buf = StringBuilder()
  for entry in entries {
    let (left, description) = entry
    buf.write_string(
      "    " + @pm3.pad_right(left, width, ' ') + "  " + description + "\n",
    )
  }
  buf.to_string()
}

///|
/// `pm3 start -h` — the options `pm3 start` understands, plus the interpreter
/// rule PM2 applies when none is given.
async fn print_start_help() -> Unit {
  let options : Array[(String, String)] = [
    ("--config <file>", "read the apps from a pm3.toml / pm3.json"),
    ("-n, --name <name>", "process name (default: script basename)"),
    ("--namespace <ns>", "start the app within the given namespace"),
    ("-i, --interpreter <cmd>", "run <script> through <cmd>"),
    (
      "--interpreter-args <arguments>", "arguments passed to the interpreter before the script",
    ),
    ("--node-args <arguments>", "alias of --interpreter-args"),
    ("--cwd <dir>", "working directory"),
    ("--merge-logs", "merge stderr into stdout's log"),
    ("--out-file <path>", "stdout log path"),
    ("--err-file <path>", "stderr log path"),
    ("--log-date-format <fmt>", "(reserved) timestamp format"),
    ("--no-autorestart", "do not restart the process when it exits"),
    ("--max-restarts <n>", "restart budget (0 = unlimited)"),
    ("--restart-delay <ms>", "delay before each restart"),
    ("--min-uptime <ms>", "below this a restart counts as unstable"),
    ("--max-memory-restart <size>", "restart when RSS exceeds <size>"),
    ("--kill-timeout <ms>", "grace period before SIGKILL"),
    ("--kill-signal <signal>", "graceful signal (default: SIGTERM)"),
    ("--stop-exit-codes <a,b>", "exit codes that should not restart"),
    ("-e, --env KEY=VALUE", "set an environment variable (repeatable)"),
  ]
  let buf = StringBuilder()
  buf.write_string("\n")
  buf.write_string("  Usage: start [options] <script> [-- args...]\n")
  buf.write_string("\n  Options:\n\n")
  buf.write_string(render_help_entries(options, help_width([options])))
  buf.write_string("\n")
  buf.write_string(
    "  Every script runs under PM2's interpreter rules: the extension picks it\n" +
    "  (.js -> node, .py -> python, .sh -> bash, ..., text -> node) unless\n" +
    "  --interpreter says otherwise.\n",
  )
  print_line(buf.to_string().trim_end(chars="\n").to_owned())
}

///|
/// The short usage block `pm2` prints when it is run with no command, with
/// pm3's paths.
async fn print_usage() -> Unit {
  print_line("usage: pm3 [options] <command>")
  print_line("")
  print_line(
    "pm3 -h, --help               show all available commands and options",
  )
  print_line("pm3 <command> -h             help on a specific command")
  print_line("pm3 logs <name> --follow     stream a process's logs")
  print_line("")
  print_line("Access pm3 files in \{@pm3.pm3_home()}")
}

///|
/// Entry point of the `pm3` binary.
pub async fn main_cli() -> Unit {
  let argv = @env.args()
  let args : Array[String] = []
  for i in 1..<argv.length() {
    let arg = argv[i]
    if arg == "--no-color" {
      @pm3.set_colors_enabled(false)
    } else {
      args.push(arg)
    }
  }
  if args.length() == 0 {
    print_usage()
    // PM2 exits 1 when it is called without a command; scripts rely on that.
    pm3_exit(1)
    return
  }
  let command = args[0]
  let rest : Array[String] = []
  for i in 1..<args.length() {
    rest.push(args[i])
  }
  match command {
    "daemon" => @daemon.run_daemon()
    "start" =>
      if rest.length() > 0 && (rest[0] == "-h" || rest[0] == "--help") {
        print_start_help()
      } else {
        cmd_start(rest)
      }
    "list" | "ls" | "ps" | "status" => cmd_list(rest)
    "describe" | "desc" | "info" | "show" => cmd_describe(rest)
    "stop" => cmd_lifecycle("stop", rest)
    "restart" => cmd_lifecycle("restart", rest)
    "delete" | "del" | "remove" => cmd_lifecycle("delete", rest)
    "logs" | "log" => cmd_logs(rest)
    "flush" => {
      let request = if rest.length() > 0 {
        @pm3.Request::with_args("flush", [rest[0]])
      } else {
        @pm3.Request::new("flush")
      }
      let response = call(request)
      if response.ok {
        print_line(response.msg)
      } else {
        print_error("pm3: \{response.msg}")
      }
    }
    "reloadLogs" | "reload-logs" => cmd_simple("reloadLogs")
    "save" => cmd_simple("save")
    "resurrect" => cmd_resurrect()
    "update" => cmd_update()
    "logrotate" | "log-rotate" => cmd_logrotate(rest)
    "set" => cmd_set(rest)
    "config" => cmd_config(rest)
    "kill" => cmd_kill()
    "version" | "--version" | "-v" => cmd_version()
    "help" | "--help" | "-h" => print_help()
    _ => {
      print_error("pm3: unknown command '\{command}'")
      print_usage()
    }
  }
  // One process per command, so the exit status is decided here: success
  // prints without ever calling `print_error`.
  pm3_exit(if command_failed.val { 1 } else { 0 })
}
