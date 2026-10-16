///|
/// The process supervisor.
///
/// One coroutine per managed app runs the spawn → wait → (maybe) restart
/// loop. Child stdout/stderr are pipes pumped into the app's `LogSink`s, which
/// is what lets the daemon rotate logs without touching the child.

///|
/// Insert `stamp` before every line of `data`, given whether the first byte
/// of `data` starts a line. Returns the line-start state for the next chunk
/// — true when `data` ends with a newline — and the stamped bytes.
///
/// This is the pump's approximation of PM2's ProcessContainer, which stamps
/// each `write()` call; the pump only sees pipe chunks, so it stamps each
/// line, which is the same thing for one-line-per-write logging.
fn stamp_lines(
  at_line_start : Bool,
  data : Bytes,
  stamp : Bytes,
) -> (Bool, Bytes) {
  let n = data.length()
  if n == 0 {
    return (at_line_start, data)
  }
  let ends_with_newline = data.unsafe_get(n - 1) == b'\n'
  let stamp_len = stamp.length()
  if stamp_len == 0 {
    return (ends_with_newline, data)
  }
  // One stamp per line start: position 0 when the previous chunk ended on a
  // newline, plus one after every newline that is followed by more bytes.
  let mut count = if at_line_start { 1 } else { 0 }
  for i in 1..<n {
    if data.unsafe_get(i - 1) == b'\n' {
      count = count + 1
    }
  }
  let out = FixedArray::make(n + count * stamp_len, b'\x00')
  let mut j = 0
  for i in 0..<n {
    if (i == 0 && at_line_start) || (i > 0 && data.unsafe_get(i - 1) == b'\n') {
      for k in 0..<stamp_len {
        out[j + k] = stamp.unsafe_get(k)
      }
      j = j + stamp_len
    }
    out[j] = data.unsafe_get(i)
    j = j + 1
  }
  (ends_with_newline, out.unsafe_reinterpret_as_bytes())
}

///|
/// Copy a child pipe into a log sink until EOF.
///
/// When `log_date_format` is set — PM2's `--time` / `--log-date-format` —
/// every line is written with the formatted wall-clock time in front of it
/// (`2026-10-16T06:07:52: message`), the way PM2's ProcessContainer does.
async fn pump(
  reader : @process.ReadFromProcess,
  sink : LogSink,
  log_date_format : String,
) -> Unit {
  defer reader.close()
  let stamping = log_date_format.length() > 0
  let mut at_line_start = true
  while true {
    match reader.read_some(max_len=65536) {
      None => break
      Some(bytes) => {
        if !stamping {
          sink.write(bytes)
          continue
        }
        let now = @async.now() / 1000L
        let stamp = @utf8.encode(
          @pm3.format_timestamp(now, pm3_local_offset(now), log_date_format) +
          ": ",
        )
        let (next_start, stamped) = stamp_lines(at_line_start, bytes, stamp)
        at_line_start = next_start
        sink.write(stamped)
      }
    }
  }
}

///|
/// Sleep for `total_ms`, waking early when a stop is requested.
async fn interruptible_sleep(app : @pm3.App, total_ms : Int) -> Unit {
  let mut waited = 0
  while waited < total_ms && !app.wants_stop() {
    let step = if total_ms - waited < 50 { total_ms - waited } else { 50 }
    @async.sleep(step)
    waited = waited + step
  }
}

///|
/// PM2's exit line for `App::exit_code` observation:
/// `App [name:id] exited with code [c] via signal [s]`.
///
/// `code` is what the supervisor's `wait()` returned; negative means the
/// process died to a signal, and PM2 prints `0` for those because the JS
/// exit code is `null`. Natural exits print their code and PM2's
/// `kill_signal || 'SIGINT'` fallback.
fn app_exit_line(app : @pm3.App, code : Int) -> String {
  let (shown_code, signal) = if code < 0 {
    (0, signal_name(-code))
  } else {
    (code, "SIGINT")
  }
  "App [\{app.name}:\{app.pm_id}] exited with code [\{shown_code}] via signal [\{signal}]"
}

///|
/// The spawn/wait/restart loop for one app. Returns when the app is stopped,
/// deleted, or has exhausted its restart budget.
async fn supervise(
  group : @async.TaskGroup[Unit],
  state : DaemonState,
  id : Int,
) -> Unit {
  while state.running {
    let managed = match state.get(id) {
      None => break
      Some(m) => m
    }
    let app = managed.app
    if app.wants_stop() {
      break
    }
    let out_sink = state.sink_for(app.out_log)
    let err_sink = if app.merge_logs {
      out_sink
    } else {
      state.sink_for(app.err_log)
    }
    let (read_out, write_out) = @process.read_from_process()
    let (read_err, write_err) = @process.read_from_process()
    // PM2 recomputes `version` from the app's package.json on every launch,
    // so a redeploy that bumps the version is reflected on the next restart.
    let base = if app.cwd.length() > 0 {
      app.cwd
    } else {
      match @env.current_dir() {
        Some(dir) => dir
        None => ""
      }
    }
    app.version = @pm3.find_package_version(app.script, base)
    app.username = @pm3.current_username()
    let (cmd, argv) = app.command_line()
    let cwd : StringView? = if app.cwd.length() > 0 {
      Some(app.cwd)
    } else {
      None
    }
    daemon_log("App [\{app.name}:\{app.pm_id}] starting in -fork mode-")
    let proc = @process.spawn(
      group,
      cmd,
      argv,
      extra_env=app.env,
      stdout=write_out,
      stderr=write_err,
      cwd?,
      cancel_handler=@process.graceful_cancel(timeout=app.kill_timeout),
      no_wait=true,
    ) catch {
      _ => {
        read_out.close()
        read_err.close()
        // A launch that never got a process: the record is dead from birth,
        // the way an app that execs-and-fails lands in PM2.
        app.mark_exited(-1)
        break
      }
    }
    app.mark_started(proc.pid)
    managed.proc = Some(proc)
    daemon_log("App [\{app.name}:\{app.pm_id}] online")
    // Reset the CPU sample baseline: a new pid has a fresh tick counter.
    managed.last_cpu_ticks = 0L
    managed.last_cpu_at = 0L
    group.spawn_bg(() => pump(read_out, out_sink, app.log_date_format))
    group.spawn_bg(() => pump(read_err, err_sink, app.log_date_format))
    let code = proc.wait()
    app.mark_exited(code)
    managed.proc = None
    daemon_log(app_exit_line(app, code))
    if app.should_restart(code) {
      app.record_restart()
      state.save()
      if app.restart_delay > 0 {
        interruptible_sleep(app, app.restart_delay)
      }
      continue
    }
    // The process will not be restarted, either because the user asked for a
    // stop or because the restart budget is exhausted. Either way it is no
    // longer *desired* to be online, so a later `pm3 resurrect` leaves it be.
    app.desired_state = @pm3.status_stopped
    state.save()
    break
  }
}

///|
/// Begin supervising `managed`. Idempotent in the sense that it replaces any
/// previous supervisor task.
pub fn start_managed(
  group : @async.TaskGroup[Unit],
  state : DaemonState,
  managed : Managed,
) -> Unit {
  let app = managed.app
  app.desired_state = @pm3.status_online
  app.status = @pm3.status_launching
  let task = group.spawn(no_wait=true, () => supervise(group, state, app.pm_id))
  managed.task = Some(task)
}

///|
/// Stop `managed` gracefully (`kill_signal`, then SIGKILL after
/// `kill_timeout`) and wait for the supervisor to observe the exit.
pub async fn stop_managed(state : DaemonState, managed : Managed) -> Unit {
  let app = managed.app
  let was_online = app.is_online()
  if was_online {
    daemon_log("Stopping app:\{app.name} id:\{app.pm_id}")
  }
  app.desired_state = @pm3.status_stopped
  if app.status == @pm3.status_online || app.status == @pm3.status_launching {
    app.status = @pm3.status_stopping
  }
  match managed.proc {
    None => ()
    Some(proc) => {
      let pid = proc.pid
      send_signal(pid, signal_number(app.kill_signal))
      match managed.task {
        None => ()
        Some(task) => {
          let finished = @async.with_timeout_opt(app.kill_timeout, () => {
            task.wait()
          }) catch {
            _ => Some(())
          }
          match finished {
            Some(_) => ()
            None => {
              daemon_log(
                "Process with pid \{pid} still alive after \{app.kill_timeout}ms, sending SIGKILL to 1 remaining pids...",
              )
              send_signal(pid, sig_kill)
              ignore(@async.with_timeout_opt(2000, () => task.wait())) catch {
                _ => ()
              }
            }
          }
        }
      }
      if was_online {
        daemon_log("pid=\{pid} msg=process tree killed (1 pids)")
      }
    }
  }
  app.status = @pm3.status_stopped
  app.pid = 0
  managed.proc = None
  state.save()
}

///|
/// Stop `managed` but keep its `desired_state`, so that the next daemon boot
/// (or `pm3 resurrect`) brings it back. Used when the daemon itself shuts down.
pub async fn halt_managed(state : DaemonState, managed : Managed) -> Unit {
  let desired = managed.app.desired_state
  stop_managed(state, managed)
  managed.app.desired_state = desired
}

///|
/// Stop and start again, counting a restart.
pub async fn restart_managed(
  group : @async.TaskGroup[Unit],
  state : DaemonState,
  managed : Managed,
) -> Unit {
  stop_managed(state, managed)
  managed.app.restarts = managed.app.restarts + 1
  start_managed(group, state, managed)
}

///|
/// Stop, then drop the app from the table.
pub async fn delete_managed(state : DaemonState, managed : Managed) -> Unit {
  stop_managed(state, managed)
  managed.task = None
  state.remove(managed.app.pm_id)
  state.save()
}
