///|
/// Blackbox tests for the public pm3 API.
/// Run `moon test` to execute and `moon test --update` to refresh snapshots.

///|
test "parse_size handles units" {
  assert_eq(@pm3.parse_size("10M"), Some(10L * 1024L * 1024L))
  assert_eq(@pm3.parse_size("1G"), Some(1024L * 1024L * 1024L))
  assert_eq(@pm3.parse_size("512K"), Some(512L * 1024L))
  assert_eq(@pm3.parse_size("1024"), Some(1024L))
  assert_eq(@pm3.parse_size("1.5M"), Some(1572864L))
  assert_eq(@pm3.parse_size("  2 gb "), Some(2L * 1024L * 1024L * 1024L))
  assert_eq(@pm3.parse_size("0"), Some(0L))
}

///|
test "parse_size rejects garbage" {
  assert_eq(@pm3.parse_size(""), None)
  assert_eq(@pm3.parse_size("M"), None)
  assert_eq(@pm3.parse_size("abc"), None)
  assert_eq(@pm3.parse_size("10X"), None)
  assert_eq(@pm3.parse_size("1.2.3M"), None)
}

///|
test "parse_size_or falls back" {
  assert_eq(@pm3.parse_size_or("", 42L), 42L)
  assert_eq(@pm3.parse_size_or("bad", 42L), 42L)
  assert_eq(@pm3.parse_size_or("1K", 42L), 1024L)
}

///|
test "format_size" {
  assert_eq(@pm3.format_size(512L), "512 B")
  assert_eq(@pm3.format_size(1024L), "1.00 KB")
  assert_eq(@pm3.format_size(1536L), "1.50 KB")
  assert_eq(@pm3.format_size(10L * 1024L * 1024L), "10.00 MB")
}

///|
test "format_timestamp" {
  // 2021-01-01T00:00:00Z
  assert_eq(
    @pm3.format_timestamp(1609459200L, 0, "YYYY-MM-DD_HH-mm-ss"),
    "2021-01-01_00-00-00",
  )
  // 2021-01-01 was a Friday.
  assert_eq(@pm3.weekday_from_days(18628), 5)
  // Offset is applied before formatting.
  assert_eq(@pm3.format_timestamp(1609459200L, 3600, "HH"), "01")
}

///|
test "next_cron_fire basic schedules" {
  // Daily at midnight, from 2021-01-01T00:00:00Z.
  let daily = @pm3.parse_cron("0 0 * * *").unwrap()
  assert_eq(@pm3.next_cron_fire(daily, 1609459200L, 0), Some(1609545600L))
  // Yearly on Jan 1st.
  let yearly = @pm3.parse_cron("@yearly").unwrap()
  assert_eq(@pm3.next_cron_fire(yearly, 1609459200L, 0), Some(1640995200L))
  // Every 15 minutes.
  let quarter = @pm3.parse_cron("*/15 * * * *").unwrap()
  assert_eq(@pm3.next_cron_fire(quarter, 1609459200L, 0), Some(1609460100L))
  // 02:30 every day.
  let at_230 = @pm3.parse_cron("30 2 * * *").unwrap()
  assert_eq(@pm3.next_cron_fire(at_230, 1609459200L, 0), Some(1609468200L))
}

///|
test "next_cron_fire with seconds" {
  let every_ten = @pm3.parse_cron("*/10 * * * * *").unwrap()
  assert_eq(@pm3.next_cron_fire(every_ten, 1609459205L, 0), Some(1609459210L))
  assert_eq(@pm3.next_cron_fire(every_ten, 1609459210L, 0), Some(1609459220L))
}

///|
test "cron rejects impossible and malformed schedules" {
  assert_eq(@pm3.parse_cron("not a cron"), None)
  assert_eq(@pm3.parse_cron("0 0 * *"), None)
  let feb31 = @pm3.parse_cron("0 0 31 2 *").unwrap()
  assert_eq(@pm3.next_cron_fire(feb31, 1609459200L, 0), None)
}

///|
test "civil date round trip" {
  assert_eq(@pm3.days_from_civil(2021, 1, 1), 18628)
  assert_eq(@pm3.civil_from_days(18628), (2021, 1, 1))
  assert_eq(@pm3.civil_from_days(0), (1970, 1, 1))
}

///|
test "rotated_path" {
  assert_eq(
    @pm3.rotated_path("/var/log/api-out.log", "2021-01-01_00-00-00", false),
    "/var/log/api-out__2021-01-01_00-00-00.log",
  )
  assert_eq(
    @pm3.rotated_path("/var/log/api-out.log", "2021-01-01_00-00-00", true),
    "/var/log/api-out__2021-01-01_00-00-00.log.gz",
  )
}

///|
test "parse_rotated_stamp is exact" {
  let log = "/var/log/api-out.log"
  assert_eq(
    @pm3.parse_rotated_stamp(log, "api-out__2021-01-01_00-00-00.log"),
    Some("2021-01-01_00-00-00"),
  )
  assert_eq(
    @pm3.parse_rotated_stamp(log, "api-out__2021-01-01_00-00-00.log.gz"),
    Some("2021-01-01_00-00-00"),
  )
  // The original indexOf()-based check would wrongly match these.
  assert_eq(@pm3.parse_rotated_stamp(log, "api-out-backup.log"), None)
  assert_eq(@pm3.parse_rotated_stamp(log, "other-api-out__x.log"), None)
  assert_eq(@pm3.parse_rotated_stamp(log, "api-out__x.txt"), None)
}

///|
test "rotation_due respects limits" {
  let config = @pm3.default_logrotate_config()
  ignore(config.set_field("max_size", "1K"))
  assert_true(@pm3.rotation_due(2048L, config))
  assert_false(@pm3.rotation_due(512L, config))
  assert_false(@pm3.rotation_due(0L, config))
  ignore(config.set_field("min_size", "4K"))
  assert_false(@pm3.rotation_due(2048L, config))
  ignore(config.set_field("max_size", "0"))
  assert_false(@pm3.rotation_due(999999L, config))
}

///|
test "select_for_deletion keeps newest and prunes by age" {
  let now = 1_000_000_000L
  let day = 86400L
  let files : Array[@pm3.RotatedFile] = [
    { name: "a", mtime: now - 3L * day, },
    { name: "b", mtime: now - 1L * day, },
    { name: "c", mtime: now - 2L * day, },
  ]
  // Keep two newest: c and b survive, a is deleted.
  assert_eq(@pm3.select_for_deletion(files, 2, 0, now), ["a"])
  // Age cap of one day also removes the three-day-old file.
  assert_eq(@pm3.select_for_deletion(files, 3, 2, now), ["a"])
}

///|
test "logrotate set_field validates" {
  let config = @pm3.default_logrotate_config()
  assert_true(config.set_field("max_size", "2M") is Ok(_))
  assert_eq(config.max_size, 2L * 1024L * 1024L)
  assert_true(config.set_field("retain", "7") is Ok(_))
  assert_eq(config.retain, 7)
  assert_true(config.set_field("compress", "true") is Ok(_))
  assert_true(config.compress)
  assert_true(config.set_field("retain", "-1") is Err(_))
  assert_true(config.set_field("compression_level", "12") is Err(_))
  assert_true(config.set_field("rotate_interval", "nope") is Err(_))
  assert_true(config.set_field("nope", "1") is Err(_))
}

///|
test "cron day-of-week names" {
  let mondays = @pm3.parse_cron("0 0 * * MON").unwrap()
  // From Friday 2021-01-01, next Monday is 2021-01-04.
  assert_eq(@pm3.next_cron_fire(mondays, 1609459200L, 0), Some(1609718400L))
}

///|
test "text helpers" {
  assert_eq(@pm3.pad_right("ab", 5, '.'), "ab...")
  assert_eq(@pm3.pad_right("abcdef", 3, '.'), "abcdef")
  assert_eq(@pm3.pad_left_text("ab", 5, '0'), "000ab")
  assert_eq(@pm3.truncate_text("abcdefgh", 6), "abc...")
  assert_eq(@pm3.truncate_text("abc", 6), "abc")
  assert_eq(@pm3.truncate_text("abcdefgh", 3), "abc")
}

///|
test "format_duration" {
  assert_eq(@pm3.format_duration(0L), "-")
  assert_eq(@pm3.format_duration(5_000L), "5s")
  assert_eq(@pm3.format_duration(90_000L), "1m")
  assert_eq(@pm3.format_duration(3_600_000L), "1h0m")
  assert_eq(@pm3.format_duration(90_000_000L), "1d1h")
}

///|
test "format_uptime_pm2" {
  // Below a minute: plain seconds.
  assert_eq(@pm3.format_uptime_pm2(0L), "0s")
  assert_eq(@pm3.format_uptime_pm2(59_000L), "59s")
  // The largest unit is only used once it would be used more than once,
  // which is what PM2's `timeSince` does: 60s..119m stay in the unit below.
  assert_eq(@pm3.format_uptime_pm2(60_000L), "60s")
  assert_eq(@pm3.format_uptime_pm2(119_000L), "119s")
  assert_eq(@pm3.format_uptime_pm2(120_000L), "2m")
  assert_eq(@pm3.format_uptime_pm2(3_599_000L), "59m")
  assert_eq(@pm3.format_uptime_pm2(3_600_000L), "60m")
  assert_eq(@pm3.format_uptime_pm2(7_199_000L), "119m")
  assert_eq(@pm3.format_uptime_pm2(7_200_000L), "2h")
  assert_eq(@pm3.format_uptime_pm2(172_800_000L), "2D")
  assert_eq(@pm3.format_uptime_pm2(5_184_000_000L), "2M")
  assert_eq(@pm3.format_uptime_pm2(63_072_000_000L), "2Y")
}

///|
test "parse_bool_value and parse_non_negative_int" {
  assert_eq(@pm3.parse_bool_value("TRUE"), Some(true))
  assert_eq(@pm3.parse_bool_value("0"), Some(false))
  assert_eq(@pm3.parse_bool_value("yes"), Some(true))
  assert_eq(@pm3.parse_bool_value("maybe"), None)
  assert_eq(@pm3.parse_non_negative_int(" 42 "), Some(42))
  assert_eq(@pm3.parse_non_negative_int("-1"), None)
  assert_eq(@pm3.parse_non_negative_int("4x"), None)
}

///|
test "cron month and weekday names" {
  // JAN is month 1, not 0.
  let jan_first = @pm3.parse_cron("0 0 1 JAN *").unwrap()
  assert_eq(@pm3.next_cron_fire(jan_first, 1609459200L, 0), Some(1640995200L))
  // DEC is month 12.
  let dec = @pm3.parse_cron("0 0 25 DEC *").unwrap()
  assert_eq(@pm3.next_cron_fire(dec, 1609459200L, 0), Some(1640390400L))
}

///|
test "render_box draws PM2's borders" {
  let table = @pm3.render_box(Some(["id", "name"]), [
    ["0", "worker"],
    ["1", "digest"],
  ])
  assert_eq(
    table,
    "┌────┬────────┐\n" +
    "│ id │ name   │\n" +
    "├────┼────────┤\n" +
    "│ 0  │ worker │\n" +
    "│ 1  │ digest │\n" +
    "└────┴────────┘\n",
  )
}

///|
test "render_box without a header is the shape `pm3 show` prints" {
  let table = @pm3.render_box(None, [["status", "online"], ["name", "worker"]])
  assert_eq(
    table,
    "┌────────┬────────┐\n" +
    "│ status │ online │\n" +
    "│ name   │ worker │\n" +
    "└────────┴────────┘\n",
  )
}

///|
test "render_box pads short rows and survives empty input" {
  // A row with fewer cells than there are columns is padded, not shifted.
  let ragged = @pm3.render_box(Some(["a", "b", "c"]), [["1"], ["1", "2"]])
  assert_eq(
    ragged,
    "┌───┬───┬───┐\n" +
    "│ a │ b │ c │\n" +
    "├───┼───┼───┤\n" +
    "│ 1 │   │   │\n" +
    "│ 1 │ 2 │   │\n" +
    "└───┴───┴───┘\n",
  )
  assert_eq(@pm3.render_box(None, []), "")
  assert_eq(@pm3.render_box(Some([]), []), "")
  // A single column still gets both vertical borders.
  assert_eq(
    @pm3.render_box(Some(["x"]), [["1"]]),
    "┌───┐\n│ x │\n├───┤\n│ 1 │\n└───┘\n",
  )
}

///|
test "format_cpu_percent matches PM2's Math.round(cpu * 10) / 10" {
  // Every expectation below is what node prints for
  // `Math.round(v * 10) / 10 + '%'`, so the two tools report the same number.
  let cases : Array[(Double, String)] = [
    (0.0, "0%"),
    (0.04, "0%"),
    (0.05, "0.1%"),
    (0.44, "0.4%"),
    (0.45, "0.5%"),
    (1.0, "1%"),
    (12.34, "12.3%"),
    (12.35, "12.4%"),
    (85.44, "85.4%"),
    (85.45, "85.5%"),
    (99.94, "99.9%"),
    (99.95, "100%"),
    (100.0, "100%"),
    (1234.5, "1234.5%"),
  ]
  for case in cases {
    let (value, expected) = case
    assert_eq(@pm3.format_cpu_percent(value), expected)
  }
}

///|
test "format_size_pm2 matches PM2's bytesToSize(bytes, 1)" {
  // Expectations are node's `bytesToSize(b, 1)`, minus the trailing space PM2
  // appends. Note that 1048575 stays in `kb`: PM2 picks the unit by comparing
  // against the next threshold, so it prints `1024.0kb` rather than `1.0mb`.
  let cases : Array[(Int64, String)] = [
    (0L, "0b"),
    (1L, "1b"),
    (512L, "512b"),
    (1023L, "1023b"),
    (1024L, "1.0kb"),
    (1025L, "1.0kb"),
    (1536L, "1.5kb"),
    (1048575L, "1024.0kb"),
    (1048576L, "1.0mb"),
    (1572864L, "1.5mb"),
    (10485760L, "10.0mb"),
    (1073741824L, "1.0gb"),
    (1610612736L, "1.5gb"),
    (1099511627776L, "1.0tb"),
    (-5L, "-5b"),
  ]
  for case in cases {
    let (value, expected) = case
    assert_eq(@pm3.format_size_pm2(value), expected)
  }
  assert_eq(@pm3.format_size_pm2(1536L, precision=0), "2kb")
}

///|
test "split_shell_words splits interpreter arguments like PM2" {
  assert_eq(@pm3.split_shell_words(""), [])
  assert_eq(@pm3.split_shell_words("   "), [])
  assert_eq(
    @pm3.split_shell_words("--trace-warnings --max-old-space-size=4096"),
    ["--trace-warnings", "--max-old-space-size=4096"],
  )
  // Quotes group a run of spaces into one argument, and are not kept.
  assert_eq(@pm3.split_shell_words("--require \"lib/setup file.js\" -x"), [
    "--require", "lib/setup file.js", "-x",
  ])
  assert_eq(@pm3.split_shell_words("'one two'"), ["one two"])
  assert_eq(@pm3.split_shell_words("--title=\"my app\""), ["--title=my app"])
  // Tabs and newlines separate like spaces.
  assert_eq(@pm3.split_shell_words("a\tb\nc"), ["a", "b", "c"])
}

///|
test "script_extension follows node's path.extname" {
  assert_eq(@pm3.script_extension("app.js"), ".js")
  assert_eq(@pm3.script_extension("/srv/app/worker.py"), ".py")
  assert_eq(@pm3.script_extension("archive.tar.gz"), ".gz")
  // A leading dot is part of the name, not an extension.
  assert_eq(@pm3.script_extension(".bashrc"), "")
  assert_eq(@pm3.script_extension("/srv/.hidden"), "")
  assert_eq(@pm3.script_extension("Makefile"), "")
  assert_eq(@pm3.script_extension("dir/"), "")
  assert_eq(@pm3.script_extension("file."), ".")
}

///|
test "interpreter_for_extension is PM2's interpreter.json" {
  assert_eq(@pm3.interpreter_for_extension(".sh"), Some("bash"))
  assert_eq(@pm3.interpreter_for_extension(".py"), Some("python"))
  assert_eq(@pm3.interpreter_for_extension(".rb"), Some("ruby"))
  assert_eq(@pm3.interpreter_for_extension(".php"), Some("php"))
  assert_eq(@pm3.interpreter_for_extension(".pl"), Some("perl"))
  assert_eq(@pm3.interpreter_for_extension(".js"), Some("node"))
  assert_eq(@pm3.interpreter_for_extension(".coffee"), Some("coffee"))
  assert_eq(@pm3.interpreter_for_extension(".ls"), Some("lsc"))
  assert_eq(@pm3.interpreter_for_extension(".ts"), Some("bun"))
  assert_eq(@pm3.interpreter_for_extension(".tsx"), Some("bun"))
  assert_eq(@pm3.interpreter_for_extension(".txt"), None)
  assert_eq(@pm3.interpreter_for_extension(""), None)
}

///|
test "is_binary_content follows isbinaryfile's rule" {
  assert_false(@pm3.is_binary_content(b""))
  assert_false(@pm3.is_binary_content(b"#!/bin/sh\necho hi\n"))
  // UTF-8 text, with or without a BOM, is text.
  assert_false(@pm3.is_binary_content(b"h\xc3\xa9llo w\xc3\xb6rld"))
  assert_false(@pm3.is_binary_content(b"\xef\xbb\xbfhello"))
  // A NUL byte is a decision, not a ratio.
  assert_true(@pm3.is_binary_content(b"abc\x00def"))
  // An ELF header.
  assert_true(@pm3.is_binary_content(b"\x7fELF\x02\x01\x01\x00"))
  // More than 10% of the sample being non-text decides, too.
  let mostly_text = b"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\x01"
  assert_false(@pm3.is_binary_content(mostly_text))
  let mostly_bytes : Bytes = b"\x01".repeat(40)
  assert_true(@pm3.is_binary_content(mostly_bytes))
}

///|
test "is_python_interpreter sees through paths" {
  assert_true(@pm3.is_python_interpreter("python"))
  assert_true(@pm3.is_python_interpreter("python3"))
  assert_true(@pm3.is_python_interpreter("/usr/bin/python3.11"))
  assert_false(@pm3.is_python_interpreter("node"))
  assert_false(@pm3.is_python_interpreter(""))
}

///|
test "visible_width does not count ANSI escapes" {
  assert_eq(@pm3.visible_width("abc"), 3)
  assert_eq(@pm3.visible_width(""), 0)
  assert_eq(@pm3.visible_width("\u{1b}[1m\u{1b}[36mabc\u{1b}[39m\u{1b}[22m"), 3)
  assert_eq(@pm3.visible_width("a\u{1b}[90m│\u{1b}[39mb"), 3)
}

///|
test "pad_visible pads on visible width" {
  assert_eq(@pm3.pad_visible("ab", 4, ' '), "ab  ")
  assert_eq(@pm3.pad_visible("abcd", 2, ' '), "abcd")
  let colored = "\u{1b}[32mab\u{1b}[39m"
  assert_eq(@pm3.pad_visible(colored, 4, ' '), colored + "  ")
}

///|
test "styles emit PM2's escape sequences" {
  let before = @pm3.colors_enabled()
  @pm3.set_colors_enabled(true)
  assert_eq(@pm3.bold_cyan("id"), "\u{1b}[1m\u{1b}[36mid\u{1b}[39m\u{1b}[22m")
  assert_eq(
    @pm3.green_bold("online"),
    "\u{1b}[1m\u{1b}[32monline\u{1b}[39m\u{1b}[22m",
  )
  assert_eq(
    @pm3.red_bold("errored"),
    "\u{1b}[1m\u{1b}[31merrored\u{1b}[39m\u{1b}[22m",
  )
  assert_eq(
    @pm3.blue_bold("launching"),
    "\u{1b}[1m\u{1b}[34mlaunching\u{1b}[39m\u{1b}[22m",
  )
  assert_eq(
    @pm3.yellow_bold("restarting"),
    "\u{1b}[1m\u{1b}[33mrestarting\u{1b}[39m\u{1b}[22m",
  )
  assert_eq(
    @pm3.bold_gray("[TAILING]"),
    "\u{1b}[1m\u{1b}[90m[TAILING]\u{1b}[39m\u{1b}[22m",
  )
  assert_eq(
    @pm3.bold_inverse(" Describing process "),
    "\u{1b}[1m\u{1b}[7m Describing process \u{1b}[27m\u{1b}[22m",
  )
  assert_eq(@pm3.style_gray("│"), "\u{1b}[90m│\u{1b}[39m")
  assert_eq(@pm3.style_green("out"), "\u{1b}[32mout\u{1b}[39m")
  assert_eq(@pm3.style_red("err"), "\u{1b}[31merr\u{1b}[39m")
  assert_eq(@pm3.style_blue("PM3"), "\u{1b}[34mPM3\u{1b}[39m")
  // Turning colours off leaves the text alone.
  @pm3.set_colors_enabled(false)
  assert_eq(@pm3.bold_cyan("id"), "id")
  assert_eq(@pm3.style_gray("│"), "│")
  assert_eq(@pm3.bold_gray("[TAILING]"), "[TAILING]")
  @pm3.set_colors_enabled(before)
}

///|
test "render_box colors borders, header and keys the way PM2 does" {
  let before = @pm3.colors_enabled()
  @pm3.set_colors_enabled(true)
  let gray = fn(text : String) { "\u{1b}[90m" + text + "\u{1b}[39m" }
  let head = fn(text : String) {
    "\u{1b}[1m\u{1b}[36m" + text + "\u{1b}[39m\u{1b}[22m"
  }
  assert_eq(
    @pm3.render_box(Some(["id", "name"]), [["0", "worker"]], style=true),
    gray("┌────┬────────┐") +
    "\n" +
    gray("│") +
    head(" id ") +
    gray("│") +
    head(" name   ") +
    gray("│") +
    "\n" +
    gray("├────┼────────┤") +
    "\n" +
    gray("│") +
    " 0  " +
    gray("│") +
    " worker " +
    gray("│") +
    "\n" +
    gray("└────┴────────┘") +
    "\n",
  )
  // The headerless shape colours its key column instead of a header row.
  assert_eq(
    @pm3.render_box(None, [["status", "online"]], style=true),
    gray("┌────────┬────────┐") +
    "\n" +
    gray("│") +
    head(" status ") +
    gray("│") +
    " online " +
    gray("│") +
    "\n" +
    gray("└────────┴────────┘") +
    "\n",
  )
  // With colours off, `style` changes nothing.
  @pm3.set_colors_enabled(false)
  assert_eq(
    @pm3.render_box(Some(["id"]), [["0"]], style=true),
    @pm3.render_box(Some(["id"]), [["0"]]),
  )
  @pm3.set_colors_enabled(before)
}

///|
/// The version column follows PM2: the `version` of the nearest package.json
/// at or above the script, and `N/A` when there is none.
test "find_package_version walks up to package.json" {
  let base = "/tmp/pm3-find-version"
  @fs.create_dir(base) catch { _ => () }
  @fs.create_dir(base + "/with") catch { _ => () }
  @fs.create_dir(base + "/with/sub") catch { _ => () }
  @fs.write_string_to_file(
    base + "/with/package.json",
    "{\"version\": \"1.2.3\"}",
  ) catch {
    _ => ()
  }
  assert_eq(@pm3.find_package_version(base + "/with/app.js", ""), "1.2.3")
  assert_eq(@pm3.find_package_version(base + "/with/sub/app.js", ""), "1.2.3")
  // A relative script is resolved against the app's cwd.
  assert_eq(@pm3.find_package_version("app.js", base + "/with"), "1.2.3")
  // A package.json without a version stops the walk with `N/A`, the way
  // PM2's finder does.
  @fs.create_dir(base + "/nover") catch { _ => () }
  @fs.write_string_to_file(base + "/nover/package.json", "{\"name\": \"x\"}") catch {
    _ => ()
  }
  assert_eq(@pm3.find_package_version(base + "/nover/app.js", ""), "N/A")
  // An unparsable package.json is skipped, so a valid one further up wins.
  @fs.create_dir(base + "/broken") catch { _ => () }
  @fs.create_dir(base + "/broken/inner") catch { _ => () }
  @fs.write_string_to_file(
    base + "/broken/package.json",
    "{\"version\": \"9.9.9\"}",
  ) catch {
    _ => ()
  }
  @fs.write_string_to_file(base + "/broken/inner/package.json", "{not json") catch {
    _ => ()
  }
  assert_eq(@pm3.find_package_version(base + "/broken/inner/app.js", ""), "9.9.9")
  // Nothing above the script at all.
  @fs.create_dir(base + "/none") catch { _ => () }
  assert_eq(@pm3.find_package_version(base + "/none/app.js", ""), "N/A")
}

///|
/// A fresh record carries the namespace, version and user columns of the
/// table.
test "a new app starts in the default namespace" {
  let app = @pm3.App::new("worker", "/srv/worker.js", [])
  assert_eq(app.app_namespace, "default")
  assert_eq(app.version, "N/A")
  assert_true(app.username.length() > 0)
}

///|
/// A process that stopped does not report the memory it held while running:
/// PM2's monitor answers `0` for anything that is not up.
test "mark_exited clears the resource samples" {
  let app = @pm3.App::new("worker", "/srv/worker.js", [])
  app.desired_state = @pm3.status_online
  app.status = @pm3.status_online
  app.pid = 4242
  app.memory = 10L * 1024L * 1024L
  app.cpu = 12.5
  app.mark_exited(3)
  assert_eq(app.pid, 0)
  assert_eq(app.memory, 0L)
  assert_eq(app.cpu, 0.0)
  assert_eq(app.exit_code, 3)
  assert_eq(app.status, "errored")
}
