///|
/// Whitebox tests for the CLI's private helpers: the `start` flag parser, the
/// help layout and the log prefix arithmetic.

///|
test "parse_start records --interpreter-args" {
  let request = parse_start([
    "--interpreter-args", "--trace-warnings --max-old-space-size=512", "app.js",
  ]).unwrap()
  assert_eq(
    request.opts.get("interpreter_args"),
    Some("--trace-warnings --max-old-space-size=512"),
  )
  assert_eq(request.args, ["app.js"])
}

///|
test "parse_start records --node-args as interpreter args" {
  let request = parse_start(["app.js", "--node-args", "--inspect"]).unwrap()
  assert_eq(request.opts.get("interpreter_args"), Some("--inspect"))
  // The last spelling wins when both are given.
  let both = parse_start([
    "--interpreter-args", "--a", "--node-args", "--b", "app.js",
  ]).unwrap()
  assert_eq(both.opts.get("interpreter_args"), Some("--b"))
}

///|
test "parse_start requires a value for --interpreter-args" {
  match parse_start(["--interpreter-args"]) {
    Err(message) =>
      assert_eq(message, "option --interpreter-args requires a value")
    Ok(_) => abort("expected a missing value to be reported")
  }
  match parse_start(["--node-args"]) {
    Err(message) => assert_eq(message, "option --node-args requires a value")
    Ok(_) => abort("expected a missing value to be reported")
  }
}

///|
test "help layout pads both columns to the longest entry" {
  let options : Array[(String, String)] = [("-h, --help", "show this help")]
  let commands : Array[(String, String)] = [
    ("start [options]", "start an app"),
    ("x", "y"),
  ]
  let width = help_width([options, commands])
  assert_eq(width, 15)
  assert_eq(
    render_help_entries(commands, width),
    "    start [options]  start an app\n    x                y\n",
  )
  // Every entry is indented by four spaces with two spaces before its
  // description, like commander renders PM2's help.
  assert_eq(
    render_help_entries(options, width),
    "    -h, --help       show this help\n",
  )
}

///|
test "pad_label pads and cuts like PM2's pad()" {
  assert_eq(pad_label("0|alpha", 10), "0|alpha   ")
  assert_eq(pad_label("PM3", 10), "PM3       ")
  assert_eq(pad_label("123|very-long-name", 10), "123|very-l")
  // Streaming grows the column to one past the longest label.
  assert_eq(pad_label("0|alpha", 8), "0|alpha ")
}

///|
test "byte_lines drops the empty segment a trailing newline leaves" {
  assert_eq(byte_lines(b""), [])
  assert_eq(byte_lines(b"a"), [b"a"])
  assert_eq(byte_lines(b"a\n"), [b"a"])
  assert_eq(byte_lines(b"a\nb\n"), [b"a", b"b"])
  assert_eq(byte_lines(b"a\n\nb"), [b"a", b"", b"b"])
}

///|
test "last_newline finds the last line break" {
  assert_eq(last_newline(b""), None)
  assert_eq(last_newline(b"abc"), None)
  assert_eq(last_newline(b"a\nb"), Some(1))
  assert_eq(last_newline(b"a\nb\n"), Some(3))
}

///|
test "style_status uses PM2's process colours" {
  let before = @pm3.colors_enabled()
  @pm3.set_colors_enabled(true)
  assert_eq(
    style_status("online"),
    "\u{1b}[1m\u{1b}[32monline\u{1b}[39m\u{1b}[22m",
  )
  assert_eq(
    style_status("launching"),
    "\u{1b}[1m\u{1b}[34mlaunching\u{1b}[39m\u{1b}[22m",
  )
  assert_eq(
    style_status("stopped"),
    "\u{1b}[1m\u{1b}[31mstopped\u{1b}[39m\u{1b}[22m",
  )
  // `errored(12)` is a status plus its restart count; the whole cell is red.
  assert_eq(
    style_status("errored(12)"),
    "\u{1b}[1m\u{1b}[31merrored(12)\u{1b}[39m\u{1b}[22m",
  )
  @pm3.set_colors_enabled(before)
}

///|
test "log_prefix colours the whole id|name column" {
  let before = @pm3.colors_enabled()
  @pm3.set_colors_enabled(true)
  assert_eq(log_prefix(Out, "0|alpha", 10), "\u{1b}[32m0|alpha    | \u{1b}[39m")
  assert_eq(log_prefix(Err, "0|alpha", 10), "\u{1b}[31m0|alpha    | \u{1b}[39m")
  assert_eq(log_prefix(Daemon, "PM3", 10), "\u{1b}[34mPM3        | \u{1b}[39m")
  @pm3.set_colors_enabled(false)
  assert_eq(log_prefix(Out, "0|alpha", 10), "0|alpha    | ")
  assert_eq(log_prefix(Daemon, "PM3", 10), "PM3        | ")
  @pm3.set_colors_enabled(before)
}

///|
/// The stale-daemon warning keeps PM2's shape — the two `>>>>` lines in red,
/// the versions in blue — because users look for the `$ pm3 update` line.
test "version skew warning follows PM2's shape" {
  let before = @pm3.colors_enabled()
  @pm3.set_colors_enabled(false)
  assert_eq(
    version_skew_warning("0.1.2", "0.1.4"),
    "\n>>>> In-memory pm3 is out-of-date, do:\n" +
    ">>>> $ pm3 update\n" +
    "In memory pm3 version: 0.1.2\n" +
    "Local pm3 version: 0.1.4\n\n",
  )
  @pm3.set_colors_enabled(true)
  let coloured = version_skew_warning("0.1.2", "0.1.4")
  assert_true(
    coloured.contains(
      "\u{1b}[1m\u{1b}[31m>>>> In-memory pm3 is out-of-date, do:\u{1b}[39m\u{1b}[22m",
    ),
  )
  assert_true(coloured.contains("\u{1b}[1m\u{1b}[34m0.1.2\u{1b}[39m\u{1b}[22m"))
  @pm3.set_colors_enabled(before)
}

///|
/// PM2 caps the name column at 38 characters of content and cuts a longer
/// name with a single-character ellipsis (`fitColumn` in pm2-ls.js).
test "fit_name_pm2 cuts long names like PM2's fitColumn" {
  assert_eq(fit_name_pm2("worker"), "worker")
  let buf = StringBuilder()
  for _ in 0..<38 {
    buf.write_char('a')
  }
  let width_38 = buf.to_string()
  assert_eq(fit_name_pm2(width_38), width_38)
  let buf39 = StringBuilder()
  for _ in 0..<39 {
    buf39.write_char('a')
  }
  let buf37 = StringBuilder()
  for _ in 0..<37 {
    buf37.write_char('a')
  }
  assert_eq(fit_name_pm2(buf39.to_string()), buf37.to_string() + "…")
}

///|
/// A start lock naming a live pid is honoured; one naming a dead pid or
/// holding something that is not a pid is stale, so a client that died
/// mid-spawn cannot wedge every later command.
async test "lock_is_stale reads the pid in the lock file" {
  let dir = "/tmp/pm3-lock-test"
  @fs.mkdir(dir, recursive=true, allow_exist=true) catch {
    _ => ()
  }
  let path = dir + "/daemon.lock"
  // A pid that no longer exists (the pid space does not reach this far).
  @fs.write_file(path, "999999", create_mode=@fs.CreateOrTruncate) catch {
    _ => abort("cannot write lock")
  }
  assert_true(lock_is_stale(path))
  // Something that is not a pid at all is equally stale.
  @fs.write_file(path, "not-a-pid", create_mode=@fs.CreateOrTruncate) catch {
    _ => abort("cannot write lock")
  }
  assert_true(lock_is_stale(path))
  // Our own pid is alive, so the lock is held by a running client.
  @fs.write_file(
    path,
    @daemon.pm3_getpid().to_string(),
    create_mode=@fs.CreateOrTruncate,
  ) catch {
    _ => abort("cannot write lock")
  }
  assert_false(lock_is_stale(path))
  // A missing lock is stale, which is how the very first client sees it.
  @fs.remove(path, allow_missing=true)
  assert_true(lock_is_stale(path))
  @fs.rmdir(dir) catch {
    _ => ()
  }
}

///|
/// Two clients racing for the lock: `CreateNew` lets exactly one win, and the
/// loser is told to wait rather than spawning a second daemon.
async test "take_start_lock admits one client at a time" {
  let home = @pm3.pm3_state_dir()
  @fs.mkdir(home, recursive=true, allow_exist=true) catch {
    _ => ()
  }
  let path = @pm3.pm3_start_lock_path()
  @fs.remove(path, allow_missing=true)
  assert_true(take_start_lock())
  // The second attempt finds a lock owned by this live process.
  assert_false(take_start_lock())
  @fs.remove(path, allow_missing=true)
  // Once the holder is gone the lock is released and can be taken again.
  assert_true(take_start_lock())
  @fs.remove(path, allow_missing=true)
}

///|
/// The invariant the start lock exists for: however many clients race, exactly
/// one of them may go on to spawn a daemon. The loser would otherwise become
/// an orphan — the daemon picks an arbitrary port, so only the winner's port
/// reaches `daemon.port` and the other daemon can never be listed or stopped.
async test "only one of many racing clients takes the start lock" {
  let dir = "/tmp/pm3-lock-race"
  @fs.mkdir(dir, recursive=true, allow_exist=true) catch {
    _ => ()
  }
  let path = dir + "/daemon.lock"
  @fs.remove(path, allow_missing=true)
  let winners = []
  let attempts = 8
  @async.with_task_group() <| group => {
    for _ in 0..<attempts {
      group.spawn_bg() <| () => {
        if take_start_lock(path~) {
          winners.push(())
        }
      }
    }
  }
  assert_eq(winners.length(), 1)
  // The winner is a live process, so a later client must still be refused.
  assert_false(take_start_lock(path~))
  @fs.remove(path, allow_missing=true)
  @fs.rmdir(dir) catch {
    _ => ()
  }
}

///|
/// A daemon that dies while holding the lock must not block the next command,
/// which is what makes a crash during startup survivable.
async test "a lock left by a dead client is replaced" {
  let dir = "/tmp/pm3-lock-dead"
  @fs.mkdir(dir, recursive=true, allow_exist=true) catch {
    _ => ()
  }
  let path = dir + "/daemon.lock"
  @fs.write_file(path, "999999", create_mode=@fs.CreateOrTruncate) catch {
    _ => abort("cannot write lock")
  }
  assert_true(take_start_lock(path~))
  @fs.remove(path, allow_missing=true)
  @fs.rmdir(dir) catch {
    _ => ()
  }
}

///|
/// A lock that is mid-write must not be stolen. Taking the lock is the atomic
/// `CreateNew` followed by writing the pid, so a second client can read the
/// file while it is still empty. Treating that as stale let it delete a live
/// lock and spawn a second daemon — about one duplicate in twelve runs of
/// eight concurrent clients — so the reader retries rather than stealing.
async test "a lock being written is not stolen" {
  let dir = "/tmp/pm3-lock-empty"
  @fs.mkdir(dir, recursive=true, allow_exist=true) catch {
    _ => ()
  }
  let path = dir + "/daemon.lock"
  // The winner has taken the lock but has not written its pid yet.
  @fs.write_file(path, "", create_mode=@fs.CreateOrTruncate) catch {
    _ => abort("cannot write lock")
  }
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      @async.sleep(100)
      @fs.write_file(
        path,
        @daemon.pm3_getpid().to_string(),
        create_mode=@fs.CreateOrTruncate,
      ) catch {
        _ => ()
      }
    }
    // The reader sees an empty file, waits, then sees a live pid.
    assert_false(take_start_lock(path~))
  }
  @fs.remove(path, allow_missing=true)
  @fs.rmdir(dir) catch {
    _ => ()
  }
}

///|
/// A lock that nothing ever fills is still stolen, after the retry window, so a
/// client killed between `CreateNew` and the pid write cannot wedge the daemon.
async test "a lock that is never filled is stolen" {
  let dir = "/tmp/pm3-lock-garbage"
  @fs.mkdir(dir, recursive=true, allow_exist=true) catch {
    _ => ()
  }
  let path = dir + "/daemon.lock"
  @fs.write_file(path, "not-a-pid", create_mode=@fs.CreateOrTruncate) catch {
    _ => abort("cannot write lock")
  }
  assert_true(lock_is_stale(path))
  assert_true(take_start_lock(path~))
  @fs.remove(path, allow_missing=true)
  @fs.rmdir(dir) catch {
    _ => ()
  }
}
