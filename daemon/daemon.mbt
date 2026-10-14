///|
/// The pm3 daemon: socket bootstrap, request dispatch and shutdown.

///|
/// Write a small text file, creating parent directories as needed.
async fn write_text_file(path : String, text : String) -> Unit {
  @fs.write_file(path, text, create_mode=@fs.CreateOrTruncate) catch {
    _ => ()
  }
}

///|
/// Ensure the pm3 home and log directories exist.
async fn ensure_dirs() -> Unit {
  @fs.mkdir(@pm3.pm3_state_dir(), recursive=true, allow_exist=true) catch {
    _ => ()
  }
  @fs.mkdir(@pm3.pm3_log_dir(), recursive=true, allow_exist=true) catch {
    _ => ()
  }
}

///|
/// Read the persisted rotation policy, falling back to defaults.
pub async fn load_logrotate_config() -> @pm3.LogrotateConfig {
  let config = @pm3.default_logrotate_config()
  let path = @pm3.pm3_logrotate_config_path()
  let exists = @fs.exists(path) catch { _ => false }
  if !exists {
    return config
  }
  let text = @fs.read_file(path).text() catch { _ => return config }
  let stored : @pm3.LogrotateConfig = @json.from_json(@json.parse(text)) catch {
    _ => return config
  }
  stored
}

///|
/// Persist the rotation policy.
pub async fn save_logrotate_config(config : @pm3.LogrotateConfig) -> Unit {
  let text = @json.to_json(config).stringify()
  @fs.write_file(
    @pm3.pm3_logrotate_config_path(),
    text,
    create_mode=@fs.CreateOrTruncate,
  ) catch {
    _ => ()
  }
}

///|
/// Derive a default app name from a script path.
fn derive_app_name(script : String) -> String {
  let base = @pm3.path_basename(script)
  match base.rev_find(".") {
    Some(index) if index > 0 =>
      base.view(start_offset=0, end_offset=index).to_owned()
    _ => base
  }
}

///|
/// Boolean option with a default.
fn opt_bool(value : String, fallback : Bool) -> Bool {
  match @pm3.parse_bool_value(value) {
    Some(v) => v
    None => fallback
  }
}

///|
/// Integer option with a default.
fn opt_int(value : String, fallback : Int) -> Int {
  match @pm3.parse_non_negative_int(value) {
    Some(v) => v
    None => fallback
  }
}

///|
/// Size option with a default.
fn opt_size(value : String, fallback : Int64) -> Int64 {
  match @pm3.parse_size(value) {
    Some(v) => v
    None => fallback
  }
}

///|
/// Apply the `opts` of a `start` request to an app record.
fn apply_start_opts(app : @pm3.App, opts : Map[String, String]) -> Unit {
  for key, value in opts {
    match key {
      "interpreter" => app.interpreter = value
      "cwd" => app.cwd = value
      "out_log" => app.out_log = value
      "err_log" => app.err_log = value
      "merge_logs" => app.merge_logs = opt_bool(value, false)
      "log_date_format" => app.log_date_format = value
      "autorestart" => app.autorestart = opt_bool(value, true)
      "max_restarts" => app.max_restarts = opt_int(value, 16)
      "restart_delay" => app.restart_delay = opt_int(value, 0)
      "min_uptime" => app.min_uptime = opt_int(value, 1000)
      "max_memory_restart" => app.max_memory_restart = opt_size(value, 0L)
      "kill_timeout" => app.kill_timeout = opt_int(value, 1600)
      "kill_signal" => app.kill_signal = value
      "stop_exit_codes" => {
        let codes : Array[Int] = []
        for part in value.split(",") {
          match @pm3.parse_non_negative_int(part) {
            Some(code) => codes.push(code)
            None => ()
          }
        }
        app.stop_exit_codes = codes
      }
      "env_json" => {
        let env : Map[String, String] = @json.from_json(@json.parse(value)) catch {
          _ => Map([])
        }
        app.env = env
      }
      _ => ()
    }
  }
}

///|
/// The application arguments carried by a `start` request (everything after
/// the script).
fn process_args_of(request : @pm3.Request) -> Array[String] {
  let out : Array[String] = []
  for i in 1..<request.args.length() {
    out.push(request.args[i])
  }
  out
}

///|
/// Handle `start`.
async fn handle_start(
  group : @async.TaskGroup[Unit],
  state : DaemonState,
  request : @pm3.Request,
) -> @pm3.Response {
  if request.args.length() == 0 {
    return @pm3.Response::failure("start: missing script")
  }
  let script = request.args[0]
  let name = match request.opts.get("name") {
    Some(n) if n.length() > 0 => n
    _ => derive_app_name(script)
  }
  match state.find_by_name(name) {
    Some(managed) => {
      if managed.app.is_online() {
        return @pm3.Response::failure(
          "\{name} is already online (pm_id \{managed.app.pm_id})",
        )
      }
      managed.app.script = script
      managed.app.args = process_args_of(request)
      apply_start_opts(managed.app, request.opts)
      // An explicit start is a fresh chance: clear the old restart budget.
      managed.app.restarts = 0
      managed.app.unstable_restarts = 0
      start_managed(group, state, managed)
      state.save()
      @pm3.Response::success("started \{name} (pm_id \{managed.app.pm_id})")
    }
    None => {
      let app = @pm3.App::new(name, script, process_args_of(request))
      apply_start_opts(app, request.opts)
      let managed = state.add(app)
      start_managed(group, state, managed)
      state.save()
      @pm3.Response::success("started \{name} (pm_id \{managed.app.pm_id})")
    }
  }
}

///|
/// Resolve an optional name argument to a list of managed apps.
fn select_apps(state : DaemonState, request : @pm3.Request) -> Array[Managed] {
  if request.args.length() == 0 {
    return state.ordered()
  }
  let name = request.args[0]
  match state.find_by_name(name) {
    Some(managed) => [managed]
    None => []
  }
}

///|
/// Dispatch one decoded request.
async fn dispatch(
  group : @async.TaskGroup[Unit],
  state : DaemonState,
  request : @pm3.Request,
) -> @pm3.Response {
  match request.cmd {
    "ping" => @pm3.Response::success("pong")
    "list" => {
      let apps : Array[@pm3.App] = []
      for managed in state.ordered() {
        apps.push(managed.app)
      }
      @pm3.Response::success_data("", @json.to_json(apps))
    }
    "describe" => {
      let apps = select_apps(state, request)
      if apps.length() == 0 {
        @pm3.Response::failure("no such process")
      } else {
        let records : Array[@pm3.App] = []
        for managed in apps {
          records.push(managed.app)
        }
        @pm3.Response::success_data("", @json.to_json(records))
      }
    }
    "start" => handle_start(group, state, request)
    "stop" => {
      let apps = select_apps(state, request)
      if apps.length() == 0 {
        @pm3.Response::failure("no such process")
      } else {
        for managed in apps {
          stop_managed(state, managed)
        }
        state.save()
        @pm3.Response::success("stopped \{apps.length()} process(es)")
      }
    }
    "restart" => {
      let apps = select_apps(state, request)
      if apps.length() == 0 {
        @pm3.Response::failure("no such process")
      } else {
        for managed in apps {
          // A manual restart resets the restart budget, like PM2.
          managed.app.restarts = 0
          managed.app.unstable_restarts = 0
          restart_managed(group, state, managed)
        }
        state.save()
        @pm3.Response::success("restarted \{apps.length()} process(es)")
      }
    }
    "delete" => {
      let apps = select_apps(state, request)
      if apps.length() == 0 {
        @pm3.Response::failure("no such process")
      } else {
        for managed in apps {
          delete_managed(state, managed)
        }
        @pm3.Response::success("deleted \{apps.length()} process(es)")
      }
    }
    "flush" =>
      if request.args.length() == 0 {
        for _, sink in state.sinks {
          sink.flush()
        }
        @pm3.Response::success("flushed all logs")
      } else {
        let apps = select_apps(state, request)
        if apps.length() == 0 {
          @pm3.Response::failure("no such process")
        } else {
          for managed in apps {
            let app = managed.app
            match state.sinks.get(app.out_log) {
              Some(sink) => sink.flush()
              None => ()
            }
            if !app.merge_logs {
              match state.sinks.get(app.err_log) {
                Some(sink) => sink.flush()
                None => ()
              }
            }
          }
          @pm3.Response::success("flushed \{apps.length()} process log(s)")
        }
      }
    "reloadLogs" => {
      for _, sink in state.sinks {
        sink.request_rotate()
      }
      @pm3.Response::success("log rotation requested")
    }
    "save" => {
      state.save()
      @pm3.Response::success("saved process list to \{@pm3.pm3_dump_path()}")
    }
    "resurrect" => {
      let mut started = 0
      for _, managed in state.ordered() {
        let app = managed.app
        if app.desired_state == @pm3.status_online && !app.is_online() {
          // Clear an orphan left behind by a hard daemon death so we do not
          // end up with two copies of the same service.
          if app.pid > 0 && pid_alive(app.pid) {
            send_signal(app.pid, sig_term)
            @async.sleep(200)
            if pid_alive(app.pid) {
              send_signal(app.pid, sig_kill)
            }
          }
          start_managed(group, state, managed)
          started = started + 1
        }
      }
      state.save()
      @pm3.Response::success("resurrected \{started} process(es)")
    }
    "get_logrotate" =>
      @pm3.Response::success_data("", @json.to_json(state.config))
    "set_logrotate" => {
      if request.args.length() < 2 {
        return @pm3.Response::failure("usage: set logrotate:<key> <value>")
      }
      match state.config.set_field(request.args[0], request.args[1]) {
        Ok(_) => {
          save_logrotate_config(state.config)
          @pm3.Response::success("\{request.args[0]} = \{request.args[1]}")
        }
        Err(message) => @pm3.Response::failure(message)
      }
    }
    "reset" => {
      for _, managed in state.ordered() {
        stop_managed(state, managed)
      }
      state.apps = Map([])
      state.next_id = 0
      state.save()
      @pm3.Response::success("reset: all processes removed")
    }
    "kill" => {
      state.running = false
      @pm3.Response::success("pm3 daemon shutting down")
    }
    _ => @pm3.Response::failure("unknown command '\{request.cmd}'")
  }
}

///|
/// Read one request line and answer it.
async fn handle_connection(
  group : @async.TaskGroup[Unit],
  state : DaemonState,
  conn : @socket.Tcp,
) -> Unit {
  defer conn.close()
  let line = conn.read_until("\n")
  let text = match line {
    None => return
    Some(text) => text
  }
  let response = match @pm3.decode_request(text) {
    None => @pm3.Response::failure("malformed request")
    Some(request) => dispatch(group, state, request)
  }
  conn.write(@pm3.encode_response(response))
}

///|
/// Accept connections until the daemon stops.
async fn accept_loop(
  group : @async.TaskGroup[Unit],
  state : DaemonState,
  server : @socket.TcpServer,
) -> Unit {
  while state.running {
    let (conn, _) = server.accept()
    group.spawn_bg(() => handle_connection(group, state, conn))
  }
}

///|
/// A freshly loaded process table describes what *was* running. Nothing can
/// reattach to a child's pipes, so every app starts out stopped; `pm3
/// resurrect` brings the ones that were desired online back, killing any
/// orphan that outlived a hard daemon death first.
fn normalize_loaded_state(state : DaemonState) -> Unit {
  for _, managed in state.ordered() {
    let app = managed.app
    if app.is_online() {
      app.status = @pm3.status_stopped
      app.pid = 0
    }
  }
}

///|
/// Entry point of the detached daemon.
pub async fn run_daemon() -> Unit {
  ignore(pm3_setsid())
  ensure_dirs()
  @stdio.stderr.write(
    "pm3 daemon starting (pid \{pm3_getpid()}, home \{@pm3.pm3_state_dir()})\n",
  ) catch {
    _ => ()
  }
  let config = load_logrotate_config()
  let state = DaemonState::new(config)
  state.load()
  normalize_loaded_state(state)
  @async.with_task_group(group => {
    let addr = @socket.Addr::parse("127.0.0.1:0") catch { _ => return }
    let server = @socket.TcpServer::TcpServer(addr, reuse_addr=true)
    state.port = server.addr.port()
    write_text_file(@pm3.pm3_port_path(), state.port.to_string())
    write_text_file(@pm3.pm3_pid_path(), pm3_getpid().to_string())
    group.spawn_bg(() => run_logrotate_loop(state))
    group.spawn_bg(() => run_compress_loop(state))
    group.spawn_bg(() => run_monitor_loop(group, state))
    group.spawn_bg(() => accept_loop(group, state, server))
    // The accept loop flips `running` when `pm3 kill` arrives.
    while state.running {
      @async.sleep(200)
    }
    for _, managed in state.ordered() {
      halt_managed(state, managed)
    }
    state.save()
    server.close()
    @fs.remove(@pm3.pm3_port_path()) catch {
      _ => ()
    }
    @fs.remove(@pm3.pm3_pid_path()) catch {
      _ => ()
    }
    group.return_immediately(())
  })
}
