///|
/// Tests for the daemon-side helpers that do not need a running supervisor.

///|
test "parse_fixed_tz understands common forms" {
  assert_eq(@daemon.parse_fixed_tz(""), Some(0))
  assert_eq(@daemon.parse_fixed_tz("UTC"), Some(0))
  assert_eq(@daemon.parse_fixed_tz("GMT"), Some(0))
  assert_eq(@daemon.parse_fixed_tz("UTC+8"), Some(8 * 3600))
  assert_eq(@daemon.parse_fixed_tz("UTC-5"), Some(-5 * 3600))
  assert_eq(@daemon.parse_fixed_tz("+05:30"), Some(5 * 3600 + 30 * 60))
  assert_eq(@daemon.parse_fixed_tz("-0800"), Some(-8 * 3600))
  assert_eq(@daemon.parse_fixed_tz("GMT+1:15"), Some(3600 + 15 * 60))
}

///|
test "parse_fixed_tz rejects named zones and garbage" {
  assert_eq(@daemon.parse_fixed_tz("America/New_York"), None)
  assert_eq(@daemon.parse_fixed_tz("nonsense"), None)
  assert_eq(@daemon.parse_fixed_tz("UTC+99"), None)
  assert_eq(@daemon.parse_fixed_tz("+5:99"), None)
}

///|
test "signal_number maps names" {
  assert_eq(@daemon.signal_number("SIGTERM"), 15)
  assert_eq(@daemon.signal_number("sigint"), 2)
  assert_eq(@daemon.signal_number("KILL"), 9)
  assert_eq(@daemon.signal_number("unknown"), 15)
}

///|
test "signal_name maps numbers back" {
  assert_eq(@daemon.signal_name(2), "SIGINT")
  assert_eq(@daemon.signal_name(15), "SIGTERM")
  assert_eq(@daemon.signal_name(9), "SIGKILL")
  assert_eq(@daemon.signal_name(11), "SIGSEGV")
  assert_eq(@daemon.signal_name(34), "SIG34")
}

///|
/// Tests for interpreter resolution: the decisions `pm3 start` makes about
/// whether a script runs directly, under node, or under the interpreter its
/// extension names.

///|
async test "which resolves commands on PATH and rejects the rest" {
  assert_true(@daemon.which("sh") is Some(_))
  assert_eq(@daemon.which("pm3-surely-not-a-command"), None)
  assert_eq(@daemon.which(""), None)
  // An absolute path is checked in place, and a directory never counts.
  assert_eq(@daemon.which("/bin/sh"), Some("/bin/sh"))
  assert_eq(@daemon.which("/tmp"), None)
}

///|
async test "resolve_script prefers the working directory, then PATH" {
  // Nothing called `sh` in this directory, so the PATH lookup wins.
  assert_eq(
    @daemon.resolve_script("sh", "/pm3-no-such-dir"),
    @daemon.which("sh"),
  )
  assert_eq(@daemon.resolve_script("no-such-thing", "/pm3-no-such-dir"), None)
  assert_eq(@daemon.resolve_script("/bin/sh", ""), Some("/bin/sh"))
}

///|
async test "resolve_script finds a file relative to the app directory" {
  let dir = "/tmp/pm3-resolve-script-test"
  @fs.mkdir(dir, recursive=true, allow_exist=true) catch {
    _ => ()
  }
  let path = dir + "/worker.sh"
  @fs.write_file(path, "#!/bin/sh\n", create_mode=@fs.CreateOrTruncate) catch {
    _ => abort("cannot write " + path)
  }
  assert_eq(@daemon.resolve_script("worker.sh", dir), Some(path))
  @fs.remove(path) catch {
    _ => ()
  }
  @fs.rmdir(dir) catch {
    _ => ()
  }
}

///|
async test "resolve_start_spec runs a binary directly" {
  let app = @pm3.App::new("echo", "/bin/echo", [])
  assert_true(@daemon.resolve_start_spec(app) is Ok(_))
  assert_eq(app.interpreter, "none")
}

///|
async test "resolve_start_spec reports a missing interpreter in PM2's words" {
  let app = @pm3.App::new("x", "/bin/echo", [])
  app.interpreter = "pm3-no-such-interpreter"
  match @daemon.resolve_start_spec(app) {
    Ok(_) => abort("expected the interpreter to be rejected")
    Err(message) =>
      assert_eq(
        message, "Interpreter pm3-no-such-interpreter is NOT AVAILABLE in PATH. (type 'which pm3-no-such-interpreter' to double check.)",
      )
  }
}

///|
async test "resolve_start_spec reports a missing script in PM2's words" {
  let app = @pm3.App::new("x", "/no/such/script.js", [])
  match @daemon.resolve_start_spec(app) {
    Ok(_) => abort("expected the script to be rejected")
    Err(message) => assert_eq(message, "Script not found: /no/such/script.js")
  }
  // A relative script is reported against the app's working directory.
  let nested = @pm3.App::new("x", "app.js", [])
  nested.cwd = "/srv/app"
  match @daemon.resolve_start_spec(nested) {
    Err(message) => assert_eq(message, "Script not found: /srv/app/app.js")
    Ok(_) => abort("expected the script to be rejected")
  }
}

///|
async test "resolve_start_spec unbuffers python interpreters" {
  match @daemon.which("python3") {
    None => () // no python3 on this machine: nothing to check
    Some(_) => {
      let app = @pm3.App::new("x", "/bin/echo", [])
      app.interpreter = "python3"
      assert_true(@daemon.resolve_start_spec(app) is Ok(_))
      assert_eq(app.env.get("PYTHONUNBUFFERED"), Some("1"))
    }
  }
}

///|
/// Process-tree helpers: the `starttime` parsing, and killing what a shell
/// wrapper spawned rather than only the process pm3 started.
test "parse_proc_stat reads ppid and starttime past a parenthesised name" {
  let text = "999 (my (weird) proc) R 42 999 999 0 -1 4194560 100 0 0 0 7 8 0 0 20 0 3 0 123456 0 0"
  assert_eq(
    @daemon.parse_proc_stat(text, 999),
    Some({ pid: 999, ppid: 42, state: 'R', start: 123456L, }),
  )
  assert_eq(@daemon.parse_proc_stat("garbage", 1), None)
  assert_eq(@daemon.parse_proc_stat("1 (short) R 2", 1), None)
}

///|
/// `merge_trees` keeps the first snapshot's identity for a pid and appends the
/// children that only the second one saw.
test "merge_trees keeps the earliest identity per pid" {
  let first : Array[@daemon.ProcStat] = [
    { pid: 10, ppid: 1, state: 'S', start: 100L, },
    { pid: 11, ppid: 10, state: 'S', start: 101L, },
  ]
  let second : Array[@daemon.ProcStat] = [
    { pid: 10, ppid: 1, state: 'S', start: 900L, },
    { pid: 12, ppid: 10, state: 'S', start: 102L, },
  ]
  let merged = @daemon.merge_trees(first, second)
  assert_eq(merged.length(), 3)
  assert_eq(merged[0], first[0])
  assert_eq(merged[2].pid, 12)
}

///|
/// The whole point of the tree walk: a `sh -c '… & … & wait'` wrapper is the
/// shape of every shell script pm3 manages, and the real work is in its
/// children.
async test "snapshot_tree lists the whole tree, children before the root" {
  let pid = @process.spawn_orphan("sh", ["-c", "sleep 30 & sleep 30 & wait"])
  @async.sleep(300)
  match @daemon.snapshot_tree(pid) {
    None => () // no /proc on this host: nothing to assert
    Some(tree) => {
      assert_eq(tree.length(), 3)
      assert_eq(tree[tree.length() - 1].pid, pid)
    }
  }
  ignore(@daemon.kill_tree(pid, @daemon.sig_kill))
  ignore(@process.wait_pid(pid))
}

///|
/// Signalling a snapshot whose `starttime` no longer matches must leave the
/// process alone: that pid belongs to someone else now (PM2's stale
/// `_tree_pids` bug).
async test "signal_members refuses a pid whose starttime does not match" {
  let pid = @process.spawn_orphan("sleep", ["30"])
  @async.sleep(300)
  let stale : Array[@daemon.ProcStat] = [
    { pid, ppid: 0, state: 'S', start: 1L, },
  ]
  assert_eq(@daemon.signal_members(stale, @daemon.sig_kill), 0)
  assert_true(@daemon.pid_alive(pid))
  ignore(@daemon.kill_tree(pid, @daemon.sig_kill))
  ignore(@process.wait_pid(pid))
}

///|
/// `kill_tree` takes the children down too, instead of leaving them running
/// with the port they were serving.
async test "kill_tree kills the children, not only the root" {
  let pid = @process.spawn_orphan("sh", ["-c", "sleep 30 & sleep 30 & wait"])
  @async.sleep(300)
  let tree = match @daemon.snapshot_tree(pid) {
    Some(tree) => tree
    None => []
  }
  let children = tree.filter(fn(entry) { entry.pid != pid })
  assert_true(children.length() >= 1)
  assert_true(@daemon.kill_tree(pid, @daemon.sig_kill) >= 1)
  ignore(@process.wait_pid(pid))
  @async.sleep(200)
  for child in children {
    // A killed child may linger as a zombie under a PID 1 that does not reap;
    // it is gone as far as the service is concerned (no port, no fds).
    assert_false(@daemon.pid_is_running(child.pid))
  }
}

///|
/// `.ts` is no longer bun-only: with bun installed it stays bun, and on a
/// bun-less host it falls back to node's type stripping, or fails with PM2's
/// message when node is too old.
async test ".ts resolves to bun or to node's type stripping" {
  let dir = "/tmp/pm3-ts-test"
  @fs.mkdir(dir, recursive=true, allow_exist=true) catch {
    _ => ()
  }
  let path = dir + "/worker.ts"
  @fs.write_file(
    path,
    "const answer: number = 42\n",
    create_mode=@fs.CreateOrTruncate,
  ) catch {
    _ => abort("cannot write " + path)
  }
  let app = @pm3.App::new("ts", path, [])
  match @daemon.resolve_start_spec(app) {
    Ok(_) => {
      assert_true(app.interpreter == "bun" || app.interpreter == "node")
      // Only a node between 22.6 and 22.18 needs the flag.
      assert_true(app.interpreter_args.length() <= 1)
      if app.interpreter_args.length() == 1 {
        assert_eq(app.interpreter_args[0], "--experimental-strip-types")
      }
    }
    Err(message) =>
      assert_eq(
        message, "TypeScript apps require bun, Node.js >= 22.18 (native type stripping) or a custom interpreter (e.g. --interpreter ts-node)",
      )
  }
  @fs.remove(path) catch {
    _ => ()
  }
  @fs.rmdir(dir) catch {
    _ => ()
  }
}

///|
/// A runtime pinned by name is resolved through its other binary names when
/// the canonical one is missing, which is what `node` means on Debian.
async test "which_runtime accepts the canonical names" {
  assert_true(@daemon.which_runtime("node") is Some(_))
  assert_eq(@daemon.which_runtime("pm3-no-such-runtime"), None)
}

///|
/// `--out-file /dev/null` must not end up as a rotated file named
/// `null__<stamp>.log`, with a regular file where the device used to be.
async test "a /dev/null sink is discarded, never opened or rotated" {
  let state = @daemon.DaemonState::new(
    @pm3.default_logrotate_config(),
    @pm3.default_config_source(),
  )
  let sink = state.sink_for("/dev/null")
  assert_true(sink.discard)
  // Nothing to write to, and nothing cached: the sink owns no descriptor.
  sink.write(@utf8.encode("hello\n"))
  sink.maybe_rotate()
  sink.flush()
  sink.close()
  assert_eq(state.sinks.length(), 0)
  assert_eq(@fs.kind("/dev/null") catch { _ => @fs.Unknown }, @fs.CharDevice)
}
