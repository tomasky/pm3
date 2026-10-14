///| Blackbox tests for configuration loading and saving.
///
/// Config files are the one place where a silent mistake is expensive: a size
/// that rounds on the way out, or a key that is quietly ignored, changes
/// behaviour long after the typo. These tests pin the round trip and the
/// loud-failure behaviour.

///|
test "format_size_exact never loses precision" {
  assert_eq(@pm3.format_size_exact(0L), "0")
  assert_eq(@pm3.format_size_exact(1L), "1")
  assert_eq(@pm3.format_size_exact(1000L), "1000")
  assert_eq(@pm3.format_size_exact(1024L), "1K")
  assert_eq(@pm3.format_size_exact(1572864L), "1536K")
  assert_eq(@pm3.format_size_exact(10L * 1024L * 1024L), "10M")
  assert_eq(@pm3.format_size_exact(2L * 1024L * 1024L * 1024L), "2G")
  // Every rendered value must parse back to the number it came from.
  for value in [0L, 1L, 999L, 1000L, 1023L, 1024L, 1025L, 1572864L, 10485760L] {
    assert_eq(@pm3.parse_size(@pm3.format_size_exact(value)), Some(value))
  }
}

///|
test "config_format_of accepts only toml and json" {
  assert_eq(@pm3.config_format_of("/x/config.toml"), Some(@pm3.Toml))
  assert_eq(@pm3.config_format_of("/x/config.json"), Some(@pm3.Json))
  assert_eq(@pm3.config_format_of("/x/config.yaml"), None)
  assert_eq(@pm3.config_format_of("/x/config"), None)
  assert_eq(@pm3.config_format_of("/x/config.TOML"), None)
}

///|
test "toml config: [logrotate] section" {
  let src = "[logrotate]\nmax_size = \"2M\"\nretain = 7\ncompress = true\n" +
    "tz = \"UTC+8\"\nmax_age_days = 3\n"
  let json = @pm3.parse_toml(src)
  assert_true(json is Ok(_))
  match json {
    Ok(value) =>
      match @pm3.logrotate_from_json(value) {
        Ok(config) => {
          assert_eq(config.max_size, 2L * 1024L * 1024L)
          assert_eq(config.retain, 7)
          assert_eq(config.compress, true)
          assert_eq(config.tz, "UTC+8")
          assert_eq(config.max_age_days, 3)
          // Untouched keys keep their defaults.
          assert_eq(config.compression_level, 6)
        }
        Err(msg) => fail("expected a config, got: " + msg)
      }
    Err(msg) => fail("expected valid TOML, got: " + msg)
  }
}

///|
test "json config: nested and legacy flat shapes" {
  let nested = @pm3.parse_config_text(
    "{\"logrotate\":{\"retain\":4}}",
    @pm3.Json,
  )
  match nested {
    Ok(value) =>
      match @pm3.logrotate_from_json(value) {
        Ok(config) => assert_eq(config.retain, 4)
        Err(msg) => fail("nested: " + msg)
      }
    Err(msg) => fail("nested parse: " + msg)
  }
  // The legacy logrotate.json is the policy itself, with sizes as digit strings.
  let flat = @pm3.parse_config_text(
    "{\"max_size\":\"10485760\",\"retain\":9}",
    @pm3.Json,
  )
  match flat {
    Ok(value) =>
      match @pm3.logrotate_from_json(value) {
        Ok(config) => {
          assert_eq(config.max_size, 10485760L)
          assert_eq(config.retain, 9)
        }
        Err(msg) => fail("flat: " + msg)
      }
    Err(msg) => fail("flat parse: " + msg)
  }
}

///|
test "config: bad values are reported, not ignored" {
  let cases = [
    ("[logrotate]\nmaxsize = \"1M\"\n", "unknown logrotate setting"),
    ("[logrotate]\nmax_size = \"nonsense\"\n", "must be a size"),
    ("[logrotate]\nretain = \"many\"\n", "must be an integer"),
    ("[logrotate]\ncompress = 1\n", "must be true or false"),
    ("[logrotate]\ncompression_level = 42\n", "between 1 and 9"),
    ("[logrotate]\nworker_interval = 0\n", "at least 1 second"),
    ("logrotate = 3\n", "must be a table or object"),
  ]
  for entry in cases {
    let (src, needle) = entry
    match @pm3.parse_toml(src) {
      Ok(value) =>
        match @pm3.logrotate_from_json(value) {
          Ok(_) => fail("expected a failure for: " + src)
          Err(msg) => assert_true(msg.contains(needle))
        }
      Err(msg) => fail("unexpected TOML error for '" + src + "': " + msg)
    }
  }
}

///|
test "config round trip: toml" {
  let original = @pm3.default_logrotate_config()
  ignore(original.set_field("max_size", "3M"))
  ignore(original.set_field("min_size", "1000"))
  ignore(original.set_field("retain", "12"))
  ignore(original.set_field("compress", "true"))
  ignore(original.set_field("compression_level", "9"))
  ignore(original.set_field("date_format", "YYYY-MM-DD"))
  ignore(original.set_field("worker_interval", "5"))
  ignore(original.set_field("rotate_interval", "0 3 * * *"))
  ignore(original.set_field("tz", "UTC-5"))
  ignore(original.set_field("rotate_module", "false"))
  ignore(original.set_field("max_age_days", "2"))
  let text = @pm3.render_config(original, @pm3.Toml)
  match @pm3.parse_config_text(text, @pm3.Toml) {
    Ok(value) =>
      match @pm3.logrotate_from_json(value) {
        Ok(reloaded) => assert_eq(reloaded, original)
        Err(msg) => fail("reload: " + msg)
      }
    Err(msg) => fail("reparse: " + msg)
  }
}

///|
test "config round trip: json" {
  let original = @pm3.default_logrotate_config()
  ignore(original.set_field("max_size", "1500"))
  ignore(original.set_field("retain", "3"))
  ignore(original.set_field("compress", "true"))
  let text = @pm3.render_config(original, @pm3.Json)
  match @pm3.parse_config_text(text, @pm3.Json) {
    Ok(value) =>
      match @pm3.logrotate_from_json(value) {
        Ok(reloaded) => assert_eq(reloaded, original)
        Err(msg) => fail("reload: " + msg)
      }
    Err(msg) => fail("reparse: " + msg)
  }
}
