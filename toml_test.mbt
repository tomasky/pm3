///| Blackbox tests for the TOML reader.
///
/// The reader exists so `config.toml` and `config.json` can share one loader,
/// so the tests focus on the shapes a config file actually uses, plus the
/// corners (multiline strings, every integer base, dotted keys, arrays of
/// tables) that are easy to get subtly wrong.

///|
/// Parse and re-serialise, which is how every other test inspects a document.
fn toml_json(source : String) -> String {
  match @pm3.parse_toml(source) {
    Ok(json) => json.stringify()
    Err(msg) => "error: " + msg
  }
}

///|
test "toml: bare keys and scalars" {
  let src = "name = \"pm3\"\nretain = 30\ncompress = true\nratio = 0.5\nnegative = -3\n# a comment\n"
  assert_eq(
    toml_json(src),
    "{\"name\":\"pm3\",\"retain\":30,\"compress\":true,\"ratio\":0.5,\"negative\":-3}",
  )
}

///|
test "toml: tables and dotted keys" {
  assert_eq(
    toml_json("[logrotate]\nmax_size = \"10M\"\n\n[server]\nport = 0\n"),
    "{\"logrotate\":{\"max_size\":\"10M\"},\"server\":{\"port\":0}}",
  )
  assert_eq(
    toml_json("a.b.c = 1\na.b.d = 2\n"),
    "{\"a\":{\"b\":{\"c\":1,\"d\":2}}}",
  )
  assert_eq(toml_json("[a.b]\nc = 1\n"), "{\"a\":{\"b\":{\"c\":1}}}")
}

///|
test "toml: strings" {
  // Basic escapes.
  assert_eq(
    toml_json("s = \"a\\tb\\nc\\\"d\\\\e\""),
    "{\"s\":\"a\\tb\\nc\\\"d\\\\e\"}",
  )
  // Literal strings take no escapes, so Windows paths survive verbatim.
  assert_eq(toml_json("s = 'C:\\pm3\\logs'"), "{\"s\":\"C:\\\\pm3\\\\logs\"}")
  // Multiline strings drop the newline that follows the opening delimiter.
  assert_eq(
    toml_json("s = \"\"\"\nline1\nline2\"\"\"\n"),
    "{\"s\":\"line1\\nline2\"}",
  )
  assert_eq(toml_json("s = '''\nraw\\n'''\n"), "{\"s\":\"raw\\\\n\"}")
  // Unicode escapes, including one outside the BMP.
  assert_eq(toml_json("s = \"\\u00e9\""), "{\"s\":\"é\"}")
  assert_eq(toml_json("s = \"\\U0001F600\""), "{\"s\":\"😀\"}")
}

///|
test "toml: numbers in every base" {
  assert_eq(toml_json("a = 1_000_000"), "{\"a\":1000000}")
  assert_eq(toml_json("a = 0xFF"), "{\"a\":255}")
  assert_eq(toml_json("a = 0o17"), "{\"a\":15}")
  assert_eq(toml_json("a = 0b1011"), "{\"a\":11}")
  assert_eq(toml_json("a = -0x10"), "{\"a\":-16}")
  assert_eq(toml_json("a = 1e3"), "{\"a\":1000}")
  assert_eq(toml_json("a = +2.5"), "{\"a\":2.5}")
  assert_eq(toml_json("a = 1_0.5_0"), "{\"a\":10.5}")
}

///|
test "toml: datetimes stay strings" {
  // pm3 never does arithmetic on a timestamp, so dates round-trip as text.
  assert_eq(
    toml_json("d = 1979-05-27T07:32:00Z"),
    "{\"d\":\"1979-05-27T07:32:00Z\"}",
  )
  assert_eq(toml_json("d = 1979-05-27"), "{\"d\":\"1979-05-27\"}")
  assert_eq(toml_json("t = 07:32:00"), "{\"t\":\"07:32:00\"}")
}

///|
test "toml: arrays" {
  assert_eq(toml_json("a = [1, 2, 3]"), "{\"a\":[1,2,3]}")
  assert_eq(toml_json("a = []"), "{\"a\":[]}")
  assert_eq(toml_json("a = [1, 2, 3,]"), "{\"a\":[1,2,3]}")
  // Arrays may span lines and carry comments between elements.
  assert_eq(toml_json("a = [\n  1, # one\n  2,\n]\n"), "{\"a\":[1,2]}")
  assert_eq(toml_json("a = [[1, 2], [3]]"), "{\"a\":[[1,2],[3]]}")
  assert_eq(toml_json("a = [\"x\", 'y']"), "{\"a\":[\"x\",\"y\"]}")
}

///|
test "toml: inline tables" {
  assert_eq(
    toml_json("point = { x = 1, y = 2 }"),
    "{\"point\":{\"x\":1,\"y\":2}}",
  )
  assert_eq(toml_json("a = {}"), "{\"a\":{}}")
  assert_eq(
    toml_json("a = { b = { c = true } }"),
    "{\"a\":{\"b\":{\"c\":true}}}",
  )
}

///|
test "toml: arrays of tables" {
  assert_eq(
    toml_json("[[app]]\nname = \"a\"\n\n[[app]]\nname = \"b\"\n"),
    "{\"app\":[{\"name\":\"a\"},{\"name\":\"b\"}]}",
  )
  // A sub-table inside the current array element attaches to that element.
  assert_eq(
    toml_json("[[app]]\nname = \"a\"\n[app.env]\nK = \"V\"\n"),
    "{\"app\":[{\"name\":\"a\",\"env\":{\"K\":\"V\"}}]}",
  )
}

///|
test "toml: quoted keys" {
  assert_eq(toml_json("\"a b\" = 1"), "{\"a b\":1}")
  assert_eq(toml_json("'x-y' = 1"), "{\"x-y\":1}")
}

///|
test "toml: a realistic pm3 config" {
  let src = "[logrotate]\nmax_size = \"10M\"\nretain = 30\ncompress = true\n" +
    "compression_level = 6\nrotate_interval = \"0 0 * * *\"\nworker_interval = 30\n" +
    "min_size = \"1K\"\nmax_age_days = 7\ntz = \"UTC\"\n"
  assert_eq(
    toml_json(src),
    "{\"logrotate\":{\"max_size\":\"10M\",\"retain\":30,\"compress\":true," +
    "\"compression_level\":6,\"rotate_interval\":\"0 0 * * *\",\"worker_interval\":30," +
    "\"min_size\":\"1K\",\"max_age_days\":7,\"tz\":\"UTC\"}}",
  )
}

///|
test "toml: errors carry a line number" {
  match @pm3.parse_toml("a = \"unterminated\n") {
    Ok(_) => fail("expected a failure")
    Err(msg) => assert_true(msg.contains("line 1"))
  }
  match @pm3.parse_toml("a = 1\nb 2\n") {
    Ok(_) => fail("expected a failure")
    Err(msg) => assert_true(msg.contains("line 2"))
  }
  match @pm3.parse_toml("a = 0xZZ") {
    Ok(_) => fail("expected a failure")
    Err(msg) => assert_true(msg.contains("base-16"))
  }
  match @pm3.parse_toml("[a\n") {
    Ok(_) => fail("expected a failure")
    Err(msg) => assert_true(msg.contains("']'"))
  }
}
