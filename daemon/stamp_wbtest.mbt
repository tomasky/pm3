///|
/// Whitebox tests for the log-line stamping the pump applies when an app
/// runs with `--time` / `--log-date-format`.

///|
test "stamp_lines stamps every line start" {
  let stamp = b"T: "
  // A fresh pipe: the very first byte starts a line.
  let (next, out) = stamp_lines(true, b"a\nb", stamp)
  assert_eq(next, false)
  assert_eq(out, b"T: a\nT: b")
  // The same bytes arriving mid-line carry no stamp — the prefix belongs to
  // the line start that was already stamped.
  let (next2, out2) = stamp_lines(false, b"a\nb", stamp)
  assert_eq(next2, false)
  assert_eq(out2, b"a\nT: b")
}

///|
test "stamp_lines tracks the line-start state across chunks" {
  // A chunk that ends on a newline leaves the next chunk at a line start.
  let (next, out) = stamp_lines(true, b"one\n", b"T: ")
  assert_eq(next, true)
  assert_eq(out, b"T: one\n")
  let (next2, out2) = stamp_lines(next, b"two\n", b"T: ")
  assert_eq(next2, true)
  assert_eq(out2, b"T: two\n")
  // Empty chunks change nothing.
  let (next3, out3) = stamp_lines(next2, b"", b"T: ")
  assert_eq(next3, true)
  assert_eq(out3, b"")
}

///|
test "stamp_lines stamps empty lines too" {
  // PM2's ProcessContainer writes the prefix for every write, so a bare
  // `console.log("")` lands as `T: \n`; an interior empty line gets the
  // same treatment.
  let (next, out) = stamp_lines(true, b"a\n\nb\n", b"T: ")
  assert_eq(next, true)
  assert_eq(out, b"T: a\nT: \nT: b\n")
}

///|
test "stamp_lines without a stamp passes bytes through" {
  let data = b"a\nb"
  let (next, out) = stamp_lines(true, data, b"")
  assert_eq(next, false)
  assert_eq(out, data)
}
