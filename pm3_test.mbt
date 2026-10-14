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
