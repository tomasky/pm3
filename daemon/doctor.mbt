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
