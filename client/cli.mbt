///|
/// The pm3 command-line interface.

///|
let cli_version : String = "0.1.0"

///|
async fn print_line(text : String) -> Unit {
  @stdio.stdout.write(text + "\n")
}

///|
async fn print_error(text : String) -> Unit {
  @stdio.stderr.write(text + "\n")
}

///|
/// Render a simple aligned table.
fn render_table(headers : Array[String], rows : Array[Array[String]]) -> String {
  let cols = headers.length()
  let widths : Array[Int] = []
  for i in 0..<cols {
    widths.push(headers[i].length())
  }
  for row in rows {
    for i in 0..<cols {
      if i < row.length() && row[i].length() > widths[i] {
        widths[i] = row[i].length()
      }
    }
  }
  let buf = StringBuilder()
  for i in 0..<cols {
    if i > 0 {
      buf.write_string("  ")
    }
    buf.write_string(@pm3.pad_right(headers[i], widths[i], ' '))
  }
  buf.write_string("\n")
  for i in 0..<cols {
    if i > 0 {
      buf.write_string("  ")
    }
    for _ in 0..<widths[i] {
      buf.write_char('-')
    }
  }
  buf.write_string("\n")
  for row in rows {
    for i in 0..<cols {
      if i > 0 {
        buf.write_string("  ")
      }
      let cell = if i < row.length() { row[i] } else { "" }
      buf.write_string(@pm3.pad_right(cell, widths[i], ' '))
    }
    buf.write_string("\n")
  }
  buf.to_string()
}

///|
/// Fetch the process list from the daemon.
async fn fetch_apps() -> Array[@pm3.App] {
  let response = call(@pm3.Request::new("list"))
  if !response.ok {
    return []
  }
  @json.from_json(response.data) catch {
    _ => []
  }
}

///|
/// `pm3 list`
async fn cmd_list(args : Array[String]) -> Unit {
  let json = args.contains("--json")
  let response = call(@pm3.Request::new("list"))
  if !response.ok {
    print_error("pm3: \{response.msg}")
    return
  }
  if json {
    print_line(response.data.stringify())
    return
  }
  let apps : Array[@pm3.App] = @json.from_json(response.data) catch { _ => [] }
  if apps.length() == 0 {
    print_line("no processes managed by pm3")
    return
  }
  let now = @async.now()
  let headers = [
    "id", "name", "status", "cpu", "mem", "restarts", "uptime", "command",
  ]
  let rows : Array[Array[String]] = []
  for app in apps {
    let uptime = if app.is_online() {
      @pm3.format_duration(now - app.started_at)
    } else {
      "-"
    }
    let status = if app.status == @pm3.status_errored {
      "errored(\{app.exit_code})"
    } else {
      app.status
    }
    rows.push([
      app.pm_id.to_string(),
      @pm3.truncate_text(app.name, 24),
      status,
      @pm3.format_fixed(app.cpu, 1) + "%",
      @pm3.format_size(app.memory, precision=0),
      app.restarts.to_string(),
      uptime,
      @pm3.truncate_text(app.command_display(), 40),
    ])
  }
  print_line(render_table(headers, rows))
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
  let apps : Array[@pm3.App] = @json.from_json(response.data) catch { _ => [] }
  for app in apps {
    let now = @async.now()
    let lines : Array[(String, String)] = [
      ("pm_id", app.pm_id.to_string()),
      ("name", app.name),
      ("status", app.status),
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
          @pm3.format_size(app.max_memory_restart)
        } else {
          "<disabled>"
        },
      ),
      ("memory", @pm3.format_size(app.memory)),
      ("cpu", @pm3.format_fixed(app.cpu, 1) + "%"),
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
    print_line("")
    for entry in lines {
      let (key, value) = entry
      print_line("  " + @pm3.pad_right(key, 20, ' ') + value)
    }
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
      "--name", "-n", "--interpreter", "-i", "--cwd", "--out-file", "--err-file",
      "--log-date-format", "--max-restarts", "--restart-delay", "--min-uptime", "--max-memory-restart",
      "--kill-timeout", "--kill-signal", "--stop-exit-codes", "--env", "-e",
    ]
    if needs_value.contains(arg) {
      if i + 1 >= args.length() {
        return Err("option \{arg} requires a value")
      }
      let value = args[i + 1]
      match arg {
        "--name" | "-n" => request.opts.set("name", value)
        "--interpreter" | "-i" => request.opts.set("interpreter", value)
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
    if arg.has_prefix("-") && script.length() > 0 {
      return Err("unknown option \{arg}")
    }
    if script.length() == 0 {
      script = arg
    } else {
      process_args.push(arg)
    }
    i = i + 1
  }
  if script.length() == 0 {
    return Err("start: missing script")
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
/// `pm3 start ...`
async fn cmd_start(args : Array[String]) -> Unit {
  let request = match parse_start(args) {
    Ok(request) => request
    Err(message) => {
      print_error("pm3: \{message}")
      return
    }
  }
  let response = call(request)
  if response.ok {
    print_line(response.msg)
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
  } else {
    print_error("pm3: \{response.msg}")
  }
}

///|
/// Print the last `lines` lines of a file.
async fn tail_lines(path : String, lines : Int) -> Unit {
  let text = @fs.read_file(path).text() catch { _ => return }
  let all : Array[String] = []
  for line in text.split("\n") {
    all.push(line.to_owned())
  }
  // Drop the empty string produced by a trailing newline.
  if all.length() > 0 && all[all.length() - 1].length() == 0 {
    ignore(all.pop())
  }
  let start = if all.length() > lines { all.length() - lines } else { 0 }
  for i in start..<all.length() {
    print_line(all[i])
  }
}

///|
/// Follow a file, printing bytes appended after the initial position.
async fn follow_file(path : String) -> Unit {
  let mut offset = @fs.file_size(path) catch { _ => 0L }
  while true {
    @async.sleep(400)
    let size = @fs.file_size(path) catch { _ => continue }
    if size < offset {
      offset = 0L
    }
    if size > offset {
      let file = @fs.open(path, mode=@fs.ReadOnly, create_mode=@fs.OpenExisting) catch {
        _ => continue
      }
      let want = (size - offset).to_int()
      let buf = FixedArray::make(want, b'\x00')
      let got = file.read_at(buf, position=offset) catch { _ => 0 }
      file.close()
      if got > 0 {
        offset = offset + got.to_int64()
        @stdio.stdout.write(buf.unsafe_reinterpret_as_bytes()[:got])
      }
    }
  }
}

///|
/// `pm3 logs [name] [--lines N] [--follow] [--err]`
async fn cmd_logs(args : Array[String]) -> Unit {
  let mut name = ""
  let mut lines = 20
  let mut follow = false
  let mut use_err = false
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
      _ =>
        if arg.has_prefix("-") {
          print_error("pm3: unknown option \{arg}")
          return
        } else {
          name = arg
        }
    }
    i = i + 1
  }
  let apps = fetch_apps()
  let selected : Array[@pm3.App] = []
  for app in apps {
    if name.length() == 0 || app.name == name {
      selected.push(app)
    }
  }
  if selected.length() == 0 {
    print_error("pm3: no matching process")
    return
  }
  for app in selected {
    let path = if use_err && !app.merge_logs {
      app.err_log
    } else {
      app.out_log
    }
    if selected.length() > 1 {
      print_line("====> \{app.name} (\{path})")
    }
    tail_lines(path, lines)
    if follow {
      follow_file(path)
    }
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
/// `pm3 kill` — stop the daemon (leaves child processes stopped).
async fn cmd_kill() -> Unit {
  let response = call(@pm3.Request::new("kill"))
  print_line(response.msg)
}

///|
/// `pm3 version`
async fn cmd_version() -> Unit {
  print_line("pm3 \{cli_version}")
}

///|
/// `pm3 help`
async fn print_help() -> Unit {
  let text =
    #|pm3 - a language-agnostic process manager with built-in log rotation
    #|
    #|Usage: pm3 <command> [options]
    #|
    #|Processes:
    #|  start <script> [options] [-- args...]   start a process
    #|  list | ls                               list managed processes
    #|  describe <name>                         show one process in detail
    #|  stop [name]                             stop one or all processes
    #|  restart [name]                          restart one or all processes
    #|  delete [name] | del                     stop and remove processes
    #|
    #|Logs:
    #|  logs [name] [--lines N] [--follow]      show (and follow) logs
    #|  flush                                   truncate all managed logs
    #|  reloadLogs                              rotate all managed logs now
    #|
    #|Log rotation:
    #|  logrotate                               show the rotation policy
    #|  set logrotate:<key> <value>             change the rotation policy
    #|
    #|Daemon:
    #|  save                                    persist the process list
    #|  resurrect                               start saved processes
    #|  kill                                    stop the daemon
    #|  version                                 print the version
    #|
    #|start options:
    #|  -n, --name <name>              process name (default: script basename)
    #|  -i, --interpreter <cmd>        run <script> through <cmd>
    #|      --cwd <dir>                working directory
    #|      --merge-logs               merge stderr into stdout's log
    #|      --out-file <path>          stdout log path
    #|      --err-file <path>          stderr log path
    #|      --log-date-format <fmt>    (reserved) timestamp format
    #|      --no-autorestart           do not restart on exit
    #|      --max-restarts <n>         restart budget (0 = unlimited)
    #|      --restart-delay <ms>       delay before restarting
    #|      --min-uptime <ms>          below this the restart is "unstable"
    #|      --max-memory-restart <size> restart when RSS exceeds this
    #|      --kill-timeout <ms>        SIGKILL grace period
    #|      --kill-signal <signal>     graceful signal (default SIGTERM)
    #|      --stop-exit-codes <a,b>    exit codes that stop restarts
    #|  -e, --env KEY=VALUE            set an environment variable
    #|
    #|Log rotation options (pm3 set logrotate:<key> <value>):
    #|  max_size, min_size, retain, max_age_days, compress, compression_level,
    #|  date_format, worker_interval, rotate_interval, tz, rotate_module
    #|
  print_line(text)
}

///|
/// Entry point of the `pm3` binary.
pub async fn main_cli() -> Unit {
  let argv = @env.args()
  let args : Array[String] = []
  for i in 1..<argv.length() {
    args.push(argv[i])
  }
  if args.length() == 0 {
    print_help()
    return
  }
  let command = args[0]
  let rest : Array[String] = []
  for i in 1..<args.length() {
    rest.push(args[i])
  }
  match command {
    "daemon" => @daemon.run_daemon()
    "start" => cmd_start(rest)
    "list" | "ls" | "ps" | "status" => cmd_list(rest)
    "describe" | "desc" | "show" => cmd_describe(rest)
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
    "resurrect" => cmd_simple("resurrect")
    "logrotate" | "log-rotate" => cmd_logrotate(rest)
    "set" => cmd_set(rest)
    "kill" => cmd_kill()
    "version" | "--version" | "-v" => cmd_version()
    "help" | "--help" | "-h" => print_help()
    _ => {
      print_error("pm3: unknown command '\{command}'")
      print_help()
    }
  }
}
