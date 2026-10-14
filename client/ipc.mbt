///|
/// Client side of the pm3 IPC protocol: find (or start) the daemon and send
/// it one request.

///|
/// The port published by a running daemon, if any.
async fn read_port_file() -> Int? {
  let path = @pm3.pm3_port_path()
  let exists = @fs.exists(path) catch { _ => false }
  if !exists {
    return None
  }
  let text = @fs.read_file(path).text() catch { _ => return None }
  @pm3.parse_non_negative_int(text.trim())
}

///|
/// One best-effort request/response round trip. Returns `None` when the
/// daemon is unreachable.
async fn try_call(request : @pm3.Request) -> @pm3.Response? {
  let port = match read_port_file() {
    Some(p) => p
    None => return None
  }
  let addr = @socket.Addr::parse("127.0.0.1:\{port}") catch { _ => return None }
  let conn = @socket.Tcp::connect(addr) catch { _ => return None }
  defer conn.close()
  let sent = try {
    conn.write(@pm3.encode_request(request))
    true
  } catch {
    _ => false
  }
  if !sent {
    return None
  }
  let line = conn.read_until("\n") catch { _ => return None }
  match line {
    None => None
    Some(text) => @pm3.decode_response(text)
  }
}

///|
/// Launch the daemon detached, with its output redirected to `~/.pm3/pm3.log`.
pub async fn start_daemon() -> Unit {
  @fs.mkdir(@pm3.pm3_state_dir(), recursive=true, allow_exist=true) catch {
    _ => ()
  }
  let exe = @fs.realpath("/proc/self/exe") catch { _ => return }
  let log = @pm3.pm3_daemon_log_path()
  let out = @process.redirect_to_file(
    log,
    append=true,
    create_mode=@fs.OpenOrCreate,
  ) catch {
    _ => return
  }
  let err = @process.redirect_to_file(
    log,
    append=true,
    create_mode=@fs.OpenOrCreate,
  ) catch {
    _ => return
  }
  ignore(@process.spawn_orphan(exe, ["daemon"], stdout=out, stderr=err)) catch {
    _ => return
  }
  for _ in 0..<100 {
    @async.sleep(100)
    if read_port_file() is Some(_) {
      // Give the accept loop a moment to come up.
      @async.sleep(150)
      return
    }
  }
}

///|
/// Send a request, starting the daemon on first use.
pub async fn call(request : @pm3.Request) -> @pm3.Response {
  match @async.with_timeout_opt(10000, () => try_call(request)) {
    Some(Some(response)) => response
    _ => {
      start_daemon()
      match @async.with_timeout_opt(10000, () => try_call(request)) {
        Some(Some(response)) => response
        _ => @pm3.Response::failure("cannot reach the pm3 daemon")
      }
    }
  }
}
