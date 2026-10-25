///|
/// Killing a process tree, without `ps`.
///
/// PM2 builds the tree with one `ps -e -o pid=,ppid=` call and kills it
/// bottom-up; when `ps` is missing (slim Docker images) it can only signal the
/// root pid. pm3 already reads `/proc` for its resource monitor, so the tree
/// is available on Linux without spawning anything, and the `ps`-less case
/// degrades the same way PM2 does: signal the root, warn once, leave the
/// children to whatever reparents them.
///
/// Every entry is recorded with the kernel's `starttime` as well as its pid.
/// A pid alone is not an identity — the kernel recycles them — and signalling
/// a recycled pid kills a stranger. PM2 learned this the hard way (`stale
/// _tree_pids`, 7.0.0-7.0.4), so an entry is only signalled while `starttime`
/// still matches the snapshot.

///|
/// One process's identity, as `/proc/<pid>/stat` describes it.
///
/// `start` is field 22, `starttime`, in clock ticks since boot: together with
/// the pid it names one process for the lifetime of the machine.
pub(all) struct ProcStat {
  pid : Int
  ppid : Int
  /// Field 3, the scheduler state. `Z` is a zombie: it has exited and only
  /// waits to be reaped, so it holds no port, descriptor or memory worth
  /// killing.
  state : Char
  start : Int64
} derive(Eq, Debug)

pub extend ProcStat with Eq::{not_equal, equal}

pub extend ProcStat with Debug::{to_repr}

///|
/// Parse `/proc/<pid>/stat`.
///
/// The second field is the executable name in parentheses and may itself
/// contain spaces and parentheses, so the fields are counted from the last
/// `)`. Field N of the record is index N - 3 of what follows, because the
/// remainder starts at field 3 (`state`).
pub fn parse_proc_stat(text : String, pid : Int) -> ProcStat? {
  let close = match text.rev_find(")") {
    Some(index) => index
    None => return None
  }
  let rest = text.view(start_offset=close + 1, end_offset=text.length())
  let tokens : Array[String] = []
  for token in rest.split(" ") {
    if token.length() > 0 {
      tokens.push(token.to_owned())
    }
  }
  // ppid is field 4, starttime field 22: 18 tokens between them.
  if tokens.length() < 20 {
    return None
  }
  let state = match tokens[0].get_char(0) {
    Some(state) => state
    None => return None
  }
  let ppid = match first_integer(tokens[1]) {
    Some(value) => value.to_int()
    None => return None
  }
  let start = match first_integer(tokens[19]) {
    Some(value) => value
    None => return None
  }
  Some({ pid, ppid, state, start })
}

///|
/// Read the identity of `pid`, or `None` when it is gone or `/proc` is not
/// mounted.
async fn read_proc_stat(pid : Int) -> ProcStat? {
  if pid <= 0 {
    return None
  }
  let text = @fs.read_file("/proc/\{pid}/stat").text() catch {
    _ => return None
  }
  parse_proc_stat(text, pid)
}

///|
/// Whether `pid` still has a process able to run behind it. A zombie has
/// exited: it holds no port, descriptor or memory, and signalling it does
/// nothing. `/proc/<pid>/stat` keeps listing it until its parent reaps it,
/// which in a container whose PID 1 does not reap can be forever.
pub async fn pid_is_running(pid : Int) -> Bool {
  match read_proc_stat(pid) {
    Some(stat) => stat.state != 'Z'
    None => false
  }
}

///|
/// Whether the process at `pid` is still the one whose `starttime` was
/// `start`. An entry recorded without a start time (an old dump, or a host
/// with no `/proc`) cannot be verified and answers `false`: never signal a pid
/// whose owner cannot be proven.
async fn pid_is(pid : Int, start : Int64) -> Bool {
  if pid <= 0 || start <= 0L {
    return false
  }
  match read_proc_stat(pid) {
    Some(stat) => stat.start == start
    None => false
  }
}

///|
/// Set once, when the tree walk turns out to be impossible: a missing `/proc`
/// would otherwise repeat the warning on every stop.
let no_proc_warned : Ref[Bool] = Ref(false)

///|
/// Report the degraded tree kill, once per daemon.
async fn warn_no_proc() -> Unit {
  if no_proc_warned.val {
    return
  }
  no_proc_warned.val = true
  daemon_log(
    "process tree walk unavailable (/proc is not mounted): only the root pid is signalled, children may be orphaned",
  )
}

///|
/// Snapshot `root` and its live descendants, deepest first — the order to
/// signal in, so a parent cannot respawn a child that is not dead yet.
///
/// `None` means the tree cannot be walked at all (no `/proc`). A root that has
/// already exited comes back as one entry with no start time: it cannot be
/// verified any more, so nothing signals it.
pub async fn snapshot_tree(root : Int) -> Array[ProcStat]? {
  if root <= 0 {
    return Some([])
  }
  let names = @fs.readdir("/proc") catch { _ => return None }
  let children : Map[Int, Array[Int]] = Map([])
  let stats : Map[Int, ProcStat] = Map([])
  for name in names {
    let pid = match @pm3.parse_non_negative_int(name.view()) {
      Some(pid) => pid
      None => continue
    }
    let stat = match read_proc_stat(pid) {
      Some(stat) => stat
      None => continue
    }
    stats.set(pid, stat)
    match children.get(stat.ppid) {
      Some(list) => list.push(pid)
      None => children.set(stat.ppid, [pid])
    }
  }
  // Post-order walk: a node is appended only after every child was pushed, so
  // children always come before their parent in the result.
  let order : Array[Int] = []
  let seen : Array[Int] = []
  let stack : Array[(Int, Bool)] = [(root, false)]
  while order.length() < 65536 {
    let next = stack.pop()
    match next {
      None => break
      Some((pid, expanded)) =>
        if expanded {
          order.push(pid)
        } else if !seen.contains(pid) {
          seen.push(pid)
          stack.push((pid, true))
          match children.get(pid) {
            Some(list) =>
              for child in list {
                stack.push((child, false))
              }
            None => ()
          }
        }
    }
  }
  let tree : Array[ProcStat] = []
  for pid in order {
    match stats.get(pid) {
      Some(stat) => tree.push(stat)
      // The root may already be gone; a synthetic entry with no start time is
      // then harmless: it cannot be verified, so it is never signalled.
      None => tree.push({ pid, ppid: 0, state: '?', start: 0L })
    }
  }
  Some(tree)
}

///|
/// Signal the members of `tree` that are still the processes they were
/// snapshotted as. Returns how many were signalled.
pub async fn signal_members(tree : Array[ProcStat], sig : Int) -> Int {
  let mut signalled = 0
  for entry in tree {
    // No recorded identity means the pid may already belong to someone else;
    // a host with no `/proc` sends its graceful signal to the root directly
    // instead of going through a snapshot.
    if entry.pid <= 0 || entry.start <= 0L {
      continue
    }
    if !pid_is(entry.pid, entry.start) {
      // The pid was recycled (or the process exited): not ours to kill.
      continue
    }
    send_signal(entry.pid, sig)
    signalled = signalled + 1
  }
  signalled
}

///|
/// Poll until no entry in `tree` is still running, or `timeout_ms` elapses.
///
/// A shell's asynchronous children can inherit `SIG_IGN` for `SIGINT`, so the
/// root exiting is not the tree exiting: the graceful signal has to be given
/// the same grace period the root gets, and what is left afterwards is what the
/// SIGKILL is for.
pub async fn wait_members_gone(
  tree : Array[ProcStat],
  timeout_ms : Int,
) -> Bool {
  let mut waited = 0
  while true {
    let mut alive = false
    for entry in tree {
      if entry.pid <= 0 {
        continue
      }
      match read_proc_stat(entry.pid) {
        Some(stat) =>
          if stat.state != 'Z' &&
            (entry.start <= 0L || stat.start == entry.start) {
            alive = true
          }
        None => ()
      }
    }
    if !alive {
      return true
    }
    if waited >= timeout_ms {
      return false
    }
    @async.sleep(50)
    waited = waited + 50
  }
  false
}

///|
/// Union of two snapshots, one entry per pid.
///
/// The first snapshot wins: a pid that appears in both is still the process
/// captured there, and the later entry for the same pid may already describe a
/// recycled stranger. Entries that only the second snapshot has are children
/// spawned after the first look, which are still ours to kill.
pub fn merge_trees(
  first : Array[ProcStat],
  second : Array[ProcStat],
) -> Array[ProcStat] {
  let merged = first.copy()
  for entry in second {
    let mut known = false
    for existing in first {
      if existing.pid == entry.pid {
        known = true
        break
      }
    }
    if !known {
      merged.push(entry)
    }
  }
  merged
}

///|
/// Send `sig` to `root` and every descendant. Returns how many processes were
/// signalled; `0` when the root is already gone.
pub async fn kill_tree(root : Int, sig : Int) -> Int {
  match snapshot_tree(root) {
    None => {
      warn_no_proc()
      if root > 0 {
        send_signal(root, sig)
        1
      } else {
        0
      }
    }
    Some(tree) => signal_members(tree, sig)
  }
}
