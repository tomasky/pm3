///|
/// The process supervisor.
///
/// One coroutine per managed app runs the spawn → wait → (maybe) restart
/// loop. Child stdout/stderr are pipes pumped into the app's `LogSink`s, which
/// is what lets the daemon rotate logs without touching the child.

///|
/// Copy a child pipe into a log sink until EOF.
async fn pump(reader : @process.ReadFromProcess, sink : LogSink) -> Unit {
  defer reader.close()
  while true {
    match reader.read_some(max_len=65536) {
      None => break
      Some(bytes) => sink.write(bytes)
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
    let (cmd, argv) = app.command_line()
    let cwd : StringView? = if app.cwd.length() > 0 {
      Some(app.cwd)
    } else {
      None
    }
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
        app.status = @pm3.status_errored
        app.exit_code = -1
        app.stopped_at = @async.now()
        app.pid = 0
        break
      }
    }
    app.mark_started(proc.pid)
    managed.proc = Some(proc)
    // Reset the CPU sample baseline: a new pid has a fresh tick counter.
    managed.last_cpu_ticks = 0L
    managed.last_cpu_at = 0L
    group.spawn_bg(() => pump(read_out, out_sink))
    group.spawn_bg(() => pump(read_err, err_sink))
    let code = proc.wait()
    app.mark_exited(code)
    managed.proc = None
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
/// Stop `managed` gracefully (SIGTERM, then SIGKILL after `kill_timeout`) and
/// wait for the supervisor to observe the exit.
pub async fn stop_managed(state : DaemonState, managed : Managed) -> Unit {
  let app = managed.app
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
              send_signal(pid, sig_kill)
              ignore(@async.with_timeout_opt(2000, () => task.wait())) catch {
                _ => ()
              }
            }
          }
        }
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
