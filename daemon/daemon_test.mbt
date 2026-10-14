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
