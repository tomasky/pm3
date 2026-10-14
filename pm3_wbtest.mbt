///|
/// Whitebox tests for pm3 internals. Public behaviour is covered by
/// `pm3_test.mbt`; the interesting internals here are the small parsers.

///|
test "cron_atom resolves names and numbers" {
  assert_eq(cron_atom("jan", 0), Some(1))
  assert_eq(cron_atom("DEC", 0), Some(12))
  assert_eq(cron_atom("mon", 1), Some(1))
  assert_eq(cron_atom("SUN", 1), Some(0))
  assert_eq(cron_atom("7", -1), Some(7))
  assert_eq(cron_atom("nope", 1), None)
}

///|
test "size_unit_factor" {
  assert_eq(size_unit_factor("k"), Some(1024L))
  assert_eq(size_unit_factor("MiB"), Some(1024L * 1024L))
  assert_eq(size_unit_factor("TB"), Some(1024L * 1024L * 1024L * 1024L))
  assert_eq(size_unit_factor("bogus"), None)
}

///|
test "parse_size_number keeps fractions" {
  assert_eq(parse_size_number("1.5"), Some(1.5))
  assert_eq(parse_size_number("0.25"), Some(0.25))
  assert_eq(parse_size_number("1.2.3"), None)
  assert_eq(parse_size_number(""), None)
}
