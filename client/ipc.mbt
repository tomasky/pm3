///|
/// Client side of the pm3 IPC protocol: find (or start) the daemon and send
/// it one request.

///|
/// The port published by a running daemon, if any.
async fn read_port_file() -> Int32? {
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
/// Whether the process `pid` is still alive, asked without a signal.
async fn is_alive(pid : Int32) -> Bool {
  (@fs.kind("/proc/\{pid}") catch { _ => @fs.Unknown }) == @fs.Directory
}

///|
/// Take the start lock, or report that another client already holds it.
///
/// `CreateNew` is the atomic part: exactly one of two racing clients creates
/// the file and the other fails. A lock left behind by a client that died
/// mid-spawn names a pid; once that pid is gone the lock is stale and is
/// replaced, so a crash cannot wedge every later command.
///
/// `path` exists so the tests can race over a scratch directory instead of the
/// real state directory; callers use the default.
async fn take_start_lock(path? : String) -> Bool {
  let path = match path {
    Some(path) => path
    None => @pm3.pm3_start_lock_path()
  }
  let write_lock = () => {
    try {
      @fs.write_file(
        path,
        @daemon.pm3_getpid().to_string(),
        create_mode=@fs.CreateNew,
      )
      true
    } catch {
      _ => false
    }
  }
  if write_lock() {
    return true
  }
  if !lock_is_stale(path) {
    return false
  }
  // Replacing a stale lock is itself a race, so it goes through the same
  // atomic create: whoever recreates it first owns the spawn.
  @fs.remove(path, allow_missing=true)
  write_lock()
}

///|
/// Whether the lock at `path` was left by a process that no longer exists.
///
/// The `CreateNew` that takes the lock and the write of the pid into it are
/// two syscalls, so a second client can read the file while it is still empty.
/// Reading that as "stale" let the second client delete a lock a live client
/// had just taken and spawn a second daemon, which is the whole race the lock
/// exists to prevent — observed once in twelve runs of eight concurrent
/// clients.
///
/// Unparseable content is therefore retried for a short window: a winner
/// fills the file within microseconds, while a lock left by a client killed
/// mid-spawn never becomes readable and is still stolen, after half a second.
async fn lock_is_stale(path : String) -> Bool {
  for attempt in 0..<10 {
    let text = @fs.read_file(path).text() catch { _ => return true }
    match @pm3.parse_non_negative_int(text.trim()) {
      Some(pid) => return !is_alive(pid)
      None =>
        // Empty or garbage. An empty file is a lock being taken right now;
        // give the winner time to write its pid before assuming it is dead.
        if attempt < 9 {
          @async.sleep(50)
        }
    }
  }
  true
}

///|
/// Whether a daemon is already reachable, checked while holding the start
/// lock.
///
/// The port file can appear at any moment, including between this client's
/// failed first request and the point where it acquires the lock. Spawning
/// then would leave a second daemon that nobody can see, so the file is
/// re-read here and a `ping` settles whether the process behind it is alive.
/// A port file left by a daemon that was killed answers nothing, which is the
/// case that must still spawn.
async fn daemon_already_running() -> Bool {
  if read_port_file() is None {
    return false
  }
  for _ in 0..<20 {
    match
      @async.with_timeout_opt(1000, () => {
        try_call(@pm3.Request::new(@pm3.cmd_ping))
      }) {
      Some(Some(response)) => return response.ok
      _ => @async.sleep(100)
    }
  }
  false
}

///|
/// Launch the daemon detached, with its output redirected to `~/.pm3/pm3.log`.
pub async fn start_daemon() -> Unit {
  @fs.mkdir(@pm3.pm3_state_dir(), recursive=true, allow_exist=true) catch {
    _ => ()
  }
  let exe = @fs.realpath("/proc/self/exe") catch { _ => return }
  let log = @pm3.pm3_daemon_log_path()
  // Whoever takes the lock spawns; everyone else waits for the port file the
  // winner's daemon publishes. Without this, two clients that both miss
  // `daemon.port` spawn two daemons, and the loser becomes an orphan nothing
  // can list or stop.
  if !take_start_lock() {
    for _ in 0..<100 {
      @async.sleep(100)
      if read_port_file() is Some(_) {
        @async.sleep(150)
        return
      }
    }
    return
  }
  defer (@fs.remove(@pm3.pm3_start_lock_path(), allow_missing=true) catch {
    _ => ()
  })
  // The lock only excludes clients that reach it at the same time. A client
  // whose first request failed may acquire it just after the previous holder
  // released it, so re-check under the lock: a daemon that is already
  // answering means this client has nothing to spawn.
  if daemon_already_running() {
    return
  }
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
  // The daemon renames itself for `ps` by overwriting its argv block, so the
  // title rides along as an argument: that reserves room for titles longer
  // than `<binary> daemon`, the way PM2's `node …/Daemon.js` command line
  // reserves room for `PM2 v7.0.4: God Daemon (…)`.
  ignore(
    @process.spawn_orphan(
      exe,
      ["daemon", @pm3.daemon_process_title()],
      stdout=out,
      stderr=err,
    ),
  ) catch {
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
/// Whether this client already compared its build with the daemon's. The
/// daemon cannot change version under a running command, so one check is
/// enough.
let daemon_version_checked : Ref[Bool] = Ref(false)

///|
/// PM2's warning for a daemon left over from another build, with pm3's
/// wording and the command that fixes it.
fn version_skew_warning(remote : String, own : String) -> String {
  let outdated = ">>>> In-memory pm3 is out-of-date, do:"
  let fix = ">>>> $ pm3 update"
  let buf = StringBuilder()
  buf.write_string("\n")
  buf.write_string(if colors() { @pm3.red_bold(outdated) } else { outdated })
  buf.write_string("\n")
  buf.write_string(if colors() { @pm3.red_bold(fix) } else { fix })
  buf.write_string("\n")
  buf.write_string(
    "In memory pm3 version: " +
    (if colors() { @pm3.blue_bold(remote) } else { remote }),
  )
  buf.write_string("\n")
  buf.write_string(
    "Local pm3 version: " + (if colors() { @pm3.blue_bold(own) } else { own }),
  )
  buf.write_string("\n\n")
  buf.to_string()
}

///|
/// Warn, the way PM2 does, when the daemon answering requests comes from a
/// different build: an old daemon silently ignores options it does not know,
/// and this client may not be able to read every field of its answers. Never
/// starts a daemon — one this client launches is its own build — and gives up
/// quietly when nothing answers.
async fn warn_if_daemon_is_stale() -> Unit {
  if daemon_version_checked.val {
    return
  }
  daemon_version_checked.val = true
  let request = @pm3.Request::new(@pm3.cmd_version)
  match @async.with_timeout_opt(10000, () => try_call(request)) {
    Some(Some(response)) => {
      // A daemon old enough to not know `version` answers with a failure.
      let remote = if response.ok { response.msg } else { "unknown" }
      if remote != @pm3.pm3_version {
        @stdio.stdout.write(version_skew_warning(remote, @pm3.pm3_version))
      }
    }
    _ => ()
  }
}

///|
/// Block until the daemon stops answering, used after `kill` so a new daemon
/// does not race the old one for the home.
async fn wait_for_daemon_exit() -> Unit {
  for _ in 0..<50 {
    match
      @async.with_timeout_opt(1000, () => {
        try_call(@pm3.Request::new(@pm3.cmd_ping))
      }) {
      Some(None) => return
      _ => @async.sleep(100)
    }
  }
}

///|
/// Send a request, starting the daemon on first use. A daemon left over from
/// another build is announced before the request goes out (except for `kill`,
/// which is already on its way to that daemon).
pub async fn call(request : @pm3.Request) -> @pm3.Response {
  if request.cmd != @pm3.cmd_kill {
    warn_if_daemon_is_stale()
  }
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
