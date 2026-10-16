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
