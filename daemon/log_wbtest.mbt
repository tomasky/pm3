///|
/// Whitebox tests for the daemon log: the PM2-shaped line prefix, the field
/// layout and the startup banner.

///|
test "daemon_line matches PM2's console wrapper" {
  assert_eq(
    daemon_line(1609459200L, 0, "YYYY-MM-DDTHH:mm:ss", "hello"),
    "2021-01-01T00:00:00: PM3 log: hello\n",
  )
  // PM2's PM2_LOG_DATE_FORMAT is a whole format; pm3 reuses
  // `format_timestamp` for it, so the richer tokens work too.
  assert_eq(
    daemon_line(1609459200L, 3600, "HH:mm", "hello"),
    "01:00: PM3 log: hello\n",
  )
  // An empty format disables the prefix entirely, the way an empty
  // PM2_LOG_DATE_FORMAT does.
  assert_eq(daemon_line(1609459200L, 0, "", "hello"), "hello\n")
}

///|
test "daemon_field pads keys to 20 columns" {
  assert_eq(daemon_field("Time", "now"), "Time                 : now")
  assert_eq(
    daemon_field("Application log path", "/tmp"),
    "Application log path : /tmp",
  )
  // Keys longer than the field are not truncated.
  assert_eq(
    daemon_field("a-very-long-key-name-here", "x"),
    "a-very-long-key-name-here : x",
  )
}

///|
test "daemon_banner_lines mirror PM2's banner shape" {
  let lines = daemon_banner_lines(1609459200L, 0, "/usr/bin/pm3")
  assert_eq(lines.length(), 14)
  // The separator and title lines are 79 columns, like PM2's fmt.sep() and
  // fmt.title(), and the banner is framed by the separator.
  assert_eq(lines[0], lines[13])
  assert_eq(lines[0].length(), 79)
  assert_eq(lines[1].length(), 79)
  assert_true(lines[1].has_prefix("--- New PM3 Daemon started "))
  assert_eq(
    lines[2],
    "Time                 : Fri Jan 01 2021 00:00:00 GMT+0000",
  )
  assert_eq(lines[3], "PM3 version          : " + @pm3.pm3_version)
  assert_true(lines[4].has_prefix("Current arch         : "))
  assert_eq(lines[5], "PM3 home             : " + @pm3.pm3_state_dir())
  assert_eq(lines[6], "PM3 PID file         : " + @pm3.pm3_pid_path())
  assert_eq(lines[7], "PM3 port file        : " + @pm3.pm3_port_path())
  assert_eq(lines[8], "Application log path : " + @pm3.pm3_log_dir())
  assert_eq(lines[9], "Worker Interval      : 2000")
  assert_eq(lines[10], "Process dump file    : " + @pm3.pm3_dump_path())
  assert_eq(lines[11], "SIGTERM timeout      : 1600")
  assert_eq(lines[12], "Runtime Binary       : /usr/bin/pm3")
}

///|
test "app_exit_line matches PM2's exit wording" {
  let app = @pm3.App::new("tick", "/bin/true", [])
  app.pm_id = 0
  // A signal death prints code 0 the way PM2's `code || 0` does.
  assert_eq(
    app_exit_line(app, -2),
    "App [tick:0] exited with code [0] via signal [SIGINT]",
  )
  assert_eq(
    app_exit_line(app, -9),
    "App [tick:0] exited with code [0] via signal [SIGKILL]",
  )
  // A natural exit keeps its code and falls back to PM2's SIGINT default.
  assert_eq(
    app_exit_line(app, 3),
    "App [tick:0] exited with code [3] via signal [SIGINT]",
  )
}
