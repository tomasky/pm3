///|
/// Finding the daemons that belong to one `PM3_HOME`.
///
/// A daemon renames its argv to `PM3 vX.Y.Z: God Daemon (<home>)`, which is
/// how `ps` shows it and how this scan recognises it. Two daemons for one home
/// is never intended: the loser supervises processes that `pm3 list` cannot
/// show and `pm3 kill` cannot reach, so it holds descriptors and keeps
/// restarting apps forever. `pm3 doctor` reports them.
///
/// The scan works while no daemon is running, which is the point: an orphan is
/// most visible exactly when the `daemon.pid` it should belong to is gone.

///|
/// One daemon process found by scanning `/proc`.
#derive(Eq, Debug)
pub(all) struct DaemonProc {
  pid : Int32
  /// The daemon's `pm3 home`, taken from its title argument.
  home : String
}

///|
pub extend DaemonProc with Eq::{not_equal, equal}

///|
pub extend DaemonProc with Debug::{to_repr}

///|
/// Split a `/proc/<pid>/cmdline` into its arguments. The kernel separates them
/// with NUL, and the daemon's rewrite of its argv keeps that layout.
fn split_cmdline(text : String) -> Array[String] {
  let args : Array[String] = []
  let mut start = 0
  for i in 0..<text.length() {
    guard text.get_char(i) is Some(c) else { break }
    if c == '\u{0}' {
      if i > start {
        args.push(text.exact_view(start~, end=i).to_owned())
      }
      start = i + 1
    }
  }
  if start < text.length() {
    args.push(text.exact_view(start~, end=text.length()).to_owned())
  }
  args
}

///|
/// The `(<home>)` a daemon title ends with, or `None` when the title is
/// something else.
fn home_from_title(title : String) -> String? {
  guard title.has_suffix(")") else { return None }
  guard title.rev_find("(") is Some(open) else { return None }
  Some(title.exact_view(start=open + 1, end=title.length() - 1).to_owned())
}

///|
/// Every daemon whose home is `home`, in pid order.
///
/// A daemon is recognised by the arguments it was spawned with — `pm3 daemon
/// <title>` — so a process that merely mentions the home in its command line
/// is not mistaken for one. A title rewritten through `PM3_DAEMON_TITLE` to
/// something without a `(<home>)` suffix is invisible here; the daemons pm3
/// starts on its own always carry the default title.
pub async fn find_daemons(home : String) -> Array[DaemonProc] {
  let found : Array[DaemonProc] = []
  let names = @fs.readdir("/proc") catch { _ => return found }
  for name in names {
    let pid = match @pm3.parse_non_negative_int(name.clamped_view()) {
      Some(pid) => pid
      None => continue
    }
    let text = @fs.read_file("/proc/\{pid}/cmdline").text() catch {
      _ => continue
    }
    if cmdline_is_daemon_for(split_cmdline(text), home) {
      found.push({ pid, home, })
    }
  }
  found.sort_by((a, b) => a.pid.compare(b.pid))
  found
}

///|
/// Whether a daemon's argument list belongs to `home`.
///
/// Two shapes have to be recognised. Before the daemon rewrites its argv it is
/// `<binary> daemon <title>`, and after the rewrite the whole block is the
/// title alone, so `cmdline` holds a single field and the second shape is what
/// a running daemon actually looks like.
pub fn cmdline_is_daemon_for(args : Array[String], home : String) -> Bool {
  if args.length() == 0 {
    return false
  }
  // Rewritten: argv[0] is the title.
  if home_from_title(args[0]) == Some(home) {
    return true
  }
  // Not yet rewritten: `<binary> daemon <title>`.
  args.length() >= 3 &&
  args[1] == "daemon" &&
  home_from_title(args[2]) == Some(home)
}

///|
/// The daemon `daemon.pid` points at, if that process is still a daemon for
/// this home. `None` means the file is stale or missing, which is normal after
/// a crash and is not by itself a problem.
pub fn current_daemon(
  daemons : Array[DaemonProc],
  pid_file_pid : Int32?,
) -> Int32? {
  match pid_file_pid {
    None => None
    Some(pid) => {
      for daemon in daemons {
        if daemon.pid == pid {
          return Some(pid)
        }
      }
      None
    }
  }
}

///|
/// How a check turned out.
#derive(Eq, Debug)
pub(all) enum CheckState {
  /// Nothing to act on.
  Ok
  /// Works, but something will go wrong later.
  Warn
  /// Something is already broken.
  Fail
}

///|
pub extend CheckState with Eq::{not_equal, equal}

///|
pub extend CheckState with Debug::{to_repr}

///|
/// One line of `pm3 doctor`, naming what was checked, how it came out and why.
#derive(Eq, Debug)
pub(all) struct Check {
  name : String
  state : CheckState
  detail : String
}

///|
pub extend Check with Eq::{not_equal, equal}

///|
pub extend Check with Debug::{to_repr}

///|
/// The label shown for a check state.
pub fn check_state_label(state : CheckState) -> String {
  match state {
    Ok => "ok"
    Warn => "warn"
    Fail => "fail"
  }
}

///|
/// Whether any check failed, so `pm3 doctor` can set the exit status.
pub fn checks_failed(checks : Array[Check]) -> Bool {
  for check in checks {
    if check.state == Fail {
      return true
    }
  }
  false
}

///|
/// Whether `dir` is writable, answered by writing to it.
///
/// There is no `stat` in `@fs`, and permission bits would not answer the
/// question that matters anyway: a full disk keeps them intact and still fails
/// the write that saves the process list, which is the failure this check
/// exists to catch before it happens.
pub async fn dir_writable(dir : String) -> Result[Unit, String] {
  let probe = @pm3.path_join(dir, ".pm3-doctor-probe")
  @fs.remove(probe, allow_missing=true)
  @fs.write_file(probe, "probe", create_mode=@fs.CreateNew) catch {
    e => return Err(e.to_string())
  }
  @fs.remove(probe, allow_missing=true) catch {
    _ => ()
  }
  Ok(())
}

///|
/// Whether `path` can be opened for writing without changing its contents.
async fn file_writable(path : String) -> Result[Unit, String] {
  let file = @fs.open(path, mode=@fs.WriteOnly, create_mode=@fs.OpenExisting) catch {
    e => return Err(e.to_string())
  }
  file.close()
  Ok(())
}

///|
/// Keep a detail short enough that one long path cannot stretch the table off
/// the screen. The tail is kept for OS errors, where the reason comes after the
/// path — `... "": No space left on device`.
pub fn clamp_detail(text : String) -> String {
  let limit = 64
  if text.length() <= limit {
    return text
  }
  // Prefer the part after the last `": `, which is where `@fs` puts the cause.
  if text.rev_find("\": ") is Some(index) && index + 3 < text.length() {
    let tail = text.exact_view(start=index + 3, end=text.length()).to_owned()
    if tail.length() <= limit {
      return tail
    }
  }
  text.exact_view(start=0, end=limit - 3).to_owned() + "..."
}

///|
/// Format a byte count for the detail column.
fn short_size(bytes : Int64) -> String {
  if bytes >= 1024L * 1024L {
    "\{@pm3.format_fixed(bytes.to_double() / 1048576.0, 1)} MB"
  } else if bytes >= 1024L {
    "\{@pm3.format_fixed(bytes.to_double() / 1024.0, 1)} KB"
  } else {
    "\{bytes} B"
  }
}

///|
/// Everything `pm3 doctor` examines about the state directory.
///
/// The checks are the failures that are silent by nature: a write to a full
/// disk loses the process list on the next restart, a stale `daemon.port`
/// sends every command to nothing, and a leftover start lock can keep a client
/// waiting. None of them announce themselves at the moment they happen.
pub async fn run_checks(home : String, survivor : Int32?) -> Array[Check] {
  let checks : Array[Check] = []
  let daemons = find_daemons(home)
  let current = survivor
  // The daemon itself: none is fine, more than one is not.
  checks.push(
    if daemons.length() == 0 {
      {
        name: "daemon",
        state: Ok,
        detail: "not running; pm3 starts it on demand",
      }
    } else if daemons.length() == 1 {
      {
        name: "daemon",
        state: Ok,
        detail: "pid \{daemons[0].pid}, reachable through daemon.port",
      }
    } else {
      {
        name: "daemon",
        state: Fail,
        detail: "\{daemons.length()} daemons share this home; only one is reachable, run `pm3 doctor --fix`",
      }
    },
  )
  // Orphans, when the pid file names none of the live daemons.
  if daemons.length() > 1 {
    let orphans : Array[String] = []
    for daemon in daemons {
      if current != Some(daemon.pid) {
        orphans.push(daemon.pid.to_string())
      }
    }
    checks.push({
      name: "orphans",
      state: Fail,
      detail: "pid " + orphans.join(", "),
    })
  }
  // daemon.pid: a stale one is harmless, a missing one with a daemon running
  // means the next scan cannot tell which daemon is current.
  let pid_file_pid = @pm3.parse_non_negative_int(
    (@fs.read_file(@pm3.pm3_pid_path()).text() catch { _ => "" }).trim(),
  )
  let pid_exists = (@fs.file_size(@pm3.pm3_pid_path()) catch { _ => -1L }) >= 0L
  checks.push(
    if daemons.length() == 0 {
      {
        name: "daemon.pid",
        state: if pid_exists {
          Warn
        } else {
          Ok
        },
        detail: if pid_exists {
          "left behind by a stopped daemon"
        } else {
          "absent, no daemon to describe"
        },
      }
    } else if current is Some(pid) {
      {
        name: "daemon.pid",
        state: if pid_file_pid == Some(pid) {
          Ok
        } else {
          Warn
        },
        detail: if pid_file_pid == Some(pid) {
          "matches the running daemon"
        } else {
          "does not name the daemon on daemon.port; rewritten on the next command"
        },
      }
    } else {
      {
        name: "daemon.pid",
        state: Fail,
        detail: "names no live daemon; every command reads it",
      }
    },
  )
  // daemon.port: the file every command goes through.
  let port_exists = (@fs.file_size(@pm3.pm3_port_path()) catch { _ => -1L }) >=
    0L
  checks.push(
    if daemons.length() == 0 {
      {
        name: "daemon.port",
        state: if port_exists {
          Warn
        } else {
          Ok
        },
        detail: if port_exists {
          "left behind by a stopped daemon"
        } else {
          "absent, no daemon to reach"
        },
      }
    } else if port_exists {
      { name: "daemon.port", state: Ok, detail: "present", }
    } else {
      {
        name: "daemon.port",
        state: Fail,
        detail: "missing while a daemon runs; commands cannot find it",
      }
    },
  )
  // The saved process list: readable, writable, and not empty.
  let dump_path = @pm3.pm3_dump_path()
  let dump_size = @fs.file_size(dump_path) catch { _ => -1L }
  if dump_size < 0L {
    checks.push({
      name: "dump.json",
      state: Warn,
      detail: "not written yet; `pm3 save` creates it",
    })
  } else {
    match file_writable(dump_path) {
      Ok(_) =>
        checks.push({
          name: "dump.json",
          state: Ok,
          detail: "writable, \{short_size(dump_size)}",
        })
      Err(message) =>
        checks.push({
          name: "dump.json",
          state: Fail,
          detail: clamp_detail("not writable: " + message),
        })
    }
  }
  // The state directory itself, which is where the dump and the two files
  // above are written.
  let home_dir = @pm3.pm3_home()
  let home_exists = try {
    ignore(@fs.readdir(home_dir))
    true
  } catch {
    _ => false
  }
  if !home_exists {
    // Nothing has needed the directory yet; the client creates it on the first
    // command, so this is not a fault.
    checks.push({
      name: "state dir",
      state: Warn,
      detail: "missing; created on first use",
    })
  } else {
    match dir_writable(home_dir) {
      Ok(_) =>
        checks.push({ name: "state dir", state: Ok, detail: "writable", })
      Err(message) =>
        checks.push({
          name: "state dir",
          state: Fail,
          detail: clamp_detail("not writable: " + message),
        })
    }
  }
  // Where application logs are created; a missing one is created on demand.
  let log_dir = @pm3.pm3_log_dir()
  match dir_writable(log_dir) {
    Ok(_) => checks.push({ name: "log dir", state: Ok, detail: "writable", })
    Err(_) =>
      checks.push({
        name: "log dir",
        state: Warn,
        detail: "missing or not writable; created when a process starts",
      })
  }
  // A lock left behind by a crash delays the next start by half a second.
  let lock_path = @pm3.pm3_start_lock_path()
  if (@fs.file_size(lock_path) catch { _ => -1L }) >= 0L {
    let text = @fs.read_file(lock_path).text() catch { _ => "" }
    checks.push({
      name: "start lock",
      state: if @pm3.parse_non_negative_int(text.trim()) is Some(_) {
        Warn
      } else {
        Ok
      },
      detail: "held by pid \{text.trim()}; replaced automatically",
    })
  } else {
    checks.push({ name: "start lock", state: Ok, detail: "free", })
  }
  checks
}
