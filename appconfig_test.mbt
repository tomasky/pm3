///| Blackbox tests for pm3's own application config.
///
/// The config file is what a project checks in, so the details that matter are
/// the ones a reader would not guess: that `[defaults]` really is inherited,
/// that a relative `script` is resolved against the config file rather than
/// the daemon's working directory, and that a bare command name is left for
/// `PATH`. Each of those is a bug that would only show up on someone else's
/// machine.

///|
/// Parse a TOML document, reporting the error as a test failure.
fn config_toml_json(source : String) -> Json {
  match @pm3.parse_toml(source) {
    Ok(json) => json
    Err(message) => abort("unexpected TOML error: \{message}")
  }
}

///|
/// Parse a config document, reporting the error as a test failure.
fn config_apps(source : String, base_dir : String) -> Array[@pm3.App] {
  match @pm3.apps_from_json(config_toml_json(source), base_dir) {
    Ok(apps) => apps
    Err(message) => abort("unexpected config error: \{message}")
  }
}

///|
/// The error a config document is rejected with.
fn config_error(source : String, base_dir : String) -> String {
  match @pm3.apps_from_json(config_toml_json(source), base_dir) {
    Ok(_) => abort("expected the config to be rejected")
    Err(message) => message
  }
}

///|
test "app config: a minimal app gets the defaults" {
  let apps = config_apps(
    "[[app]]\nname = \"worker\"\nscript = \"./worker.py\"\n", "/srv/app",
  )
  assert_eq(apps.length(), 1)
  let app = apps[0]
  assert_eq(app.name, "worker")
  assert_eq(app.script, "/srv/app/worker.py")
  assert_eq(app.args.length(), 0)
  assert_eq(app.interpreter, "")
  // `cwd` falls back to the config file's directory, not the daemon's.
  assert_eq(app.cwd, "/srv/app")
  assert_eq(app.autorestart, true)
  assert_eq(app.max_restarts, 16)
  assert_eq(app.min_uptime, 1000)
  assert_eq(app.kill_timeout, 1600)
  assert_eq(app.kill_signal, "SIGTERM")
  assert_eq(app.max_memory_restart, 0L)
  assert_eq(app.merge_logs, false)
}

///|
test "app config: [defaults] is inherited and overridden per app" {
  let source = "[defaults]\n" +
    "max_restarts = 3\n" +
    "max_memory_restart = \"200M\"\n" +
    "restart_delay = 500\n" +
    "interpreter = \"python3\"\n" +
    "env = { REGION = \"eu\" }\n" +
    "\n" +
    "[[app]]\n" +
    "name = \"a\"\n" +
    "script = \"./a.py\"\n" +
    "\n" +
    "[[app]]\n" +
    "name = \"b\"\n" +
    "script = \"./b.py\"\n" +
    "max_restarts = 9\n" +
    "env = { REGION = \"us\", EXTRA = \"1\" }\n"
  let apps = config_apps(source, "/srv")
  assert_eq(apps.length(), 2)
  assert_eq(apps[0].max_restarts, 3)
  assert_eq(apps[0].max_memory_restart, 200L * 1024L * 1024L)
  assert_eq(apps[0].restart_delay, 500)
  assert_eq(apps[0].interpreter, "python3")
  assert_eq(apps[0].env.get("REGION"), Some("eu"))
  // The second app overrides two fields and keeps the rest.
  assert_eq(apps[1].max_restarts, 9)
  assert_eq(apps[1].max_memory_restart, 200L * 1024L * 1024L)
  assert_eq(apps[1].env.get("REGION"), Some("us"))
  assert_eq(apps[1].env.get("EXTRA"), Some("1"))
  // App order is the file's order.
  assert_eq(apps[0].name, "a")
  assert_eq(apps[1].name, "b")
}

///|
test "app config: a bare command name is left for PATH" {
  // `sh` is not a file next to the config, so it stays a command name.
  let apps = config_apps(
    "[[app]]\nname = \"p\"\nscript = \"sh\"\nargs = [\"-c\", \"sleep 1\"]\n", "/srv/app",
  )
  assert_eq(apps[0].script, "sh")
  assert_eq(apps[0].args, ["-c", "sleep 1"])
  // A name with a slash is a path even when it does not exist.
  let nested = config_apps(
    "[[app]]\nname = \"q\"\nscript = \"bin/server\"\n", "/srv/app",
  )
  assert_eq(nested[0].script, "/srv/app/bin/server")
  // An absolute path is never rewritten.
  let absolute = config_apps(
    "[[app]]\nname = \"r\"\nscript = \"/usr/bin/env\"\n", "/srv/app",
  )
  assert_eq(absolute[0].script, "/usr/bin/env")
}

///|
test "app config: a name is derived from the script when absent" {
  assert_eq(@pm3.derive_config_app_name("/srv/app/worker.py"), "worker")
  assert_eq(@pm3.derive_config_app_name("worker.py"), "worker")
  assert_eq(@pm3.derive_config_app_name("./bin/server"), "server")
  assert_eq(@pm3.derive_config_app_name("plain"), "plain")
  assert_eq(@pm3.derive_config_app_name(".hidden"), ".hidden")
  let apps = config_apps("[[app]]\nscript = \"./digest.py\"\n", "/srv")
  assert_eq(apps[0].name, "digest")
  // The derived name decides the default log paths.
  assert_eq(apps[0].out_log, @pm3.default_log_path("digest", "out"))
  assert_eq(apps[0].err_log, @pm3.default_log_path("digest", "err"))
}

///|
test "app config: log paths resolve, or follow the name" {
  let apps = config_apps(
    "[[app]]\nname = \"w\"\nscript = \"sh\"\nout_log = \"logs/w.out\"\nerr_log = \"/var/log/w.err\"\n",
    "/srv",
  )
  assert_eq(apps[0].out_log, "/srv/logs/w.out")
  assert_eq(apps[0].err_log, "/var/log/w.err")
}

///|
test "app config: the JSON form produces the same apps" {
  let source = "{\n" +
    "  \"defaults\": { \"max_restarts\": 4 },\n" +
    "  \"app\": [\n" +
    "    { \"name\": \"w\", \"script\": \"./w.py\", \"interpreter\": \"python3\",\n" +
    "      \"args\": [\"--x\"], \"env\": { \"PORT\": \"80\" },\n" +
    "      \"max_memory_restart\": \"64M\", \"stop_exit_codes\": [0, 3],\n" +
    "      \"merge_logs\": true }\n" +
    "  ]\n" +
    "}"
  let json = @json.parse(source) catch { _ => fail("invalid JSON") }
  let apps = match @pm3.apps_from_json(json, "/srv") {
    Ok(apps) => apps
    Err(message) => fail("unexpected config error: \{message}")
  }
  assert_eq(apps.length(), 1)
  let app = apps[0]
  assert_eq(app.name, "w")
  assert_eq(app.script, "/srv/w.py")
  assert_eq(app.interpreter, "python3")
  assert_eq(app.args, ["--x"])
  assert_eq(app.env.get("PORT"), Some("80"))
  assert_eq(app.max_memory_restart, 64L * 1024L * 1024L)
  assert_eq(app.max_restarts, 4)
  assert_eq(app.stop_exit_codes, [0, 3])
  assert_eq(app.merge_logs, true)
}

///|
test "app config: numbers may be written as strings" {
  let apps = config_apps(
    "[[app]]\nname = \"w\"\nscript = \"sh\"\nmax_restarts = \"5\"\nstop_exit_codes = [\"0\", 2]\n",
    "/srv",
  )
  assert_eq(apps[0].max_restarts, 5)
  assert_eq(apps[0].stop_exit_codes, [0, 2])
}

///|
test "app config: mistakes are reported, not guessed at" {
  assert_eq(
    config_error("[[app]]\nname = \"w\"\nscript = \"sh\"\nwat = 1\n", "/srv"),
    "unknown app setting 'wat'; expected one of " +
    @pm3.app_field_names().join(", "),
  )
  assert_eq(
    config_error("[[app]]\nname = \"w\"\n", "/srv"),
    "every app needs a 'script'",
  )
  assert_eq(
    config_error("[defaults]\nwat = 1\n[[app]]\nscript = \"sh\"\n", "/srv"),
    "unknown default 'wat'; expected one of " +
    @pm3.app_field_names().join(", "),
  )
  assert_eq(
    config_error(
      "[[app]]\nname = \"w\"\nscript = \"sh\"\nmax_memory_restart = \"12 bananas\"\n",
      "/srv",
    ),
    "'max_memory_restart' must be a size such as 10M, 1G or 512K, got '12 bananas'",
  )
  assert_eq(
    config_error(
      "[[app]]\nname = \"w\"\nscript = \"sh\"\nmax_restarts = -1\n", "/srv",
    ),
    "'max_restarts' must not be negative",
  )
  assert_eq(
    config_error(
      "[[app]]\nname = \"w\"\nscript = \"sh\"\nargs = \"nope\"\n", "/srv",
    ),
    "'args' must be an array of strings",
  )
  assert_eq(
    config_error("[[app]]\nname = \"w\"\nscript = \"sh\"\nenv = 3\n", "/srv"),
    "'env' must be a table or object of scalars",
  )
  assert_eq(
    config_error("app = 3\n", "/srv"),
    "'app' must be an array of tables: [[app]]",
  )
  assert_eq(
    config_error("[logrotate]\nmax_size = \"1M\"\n", "/srv"),
    "no applications declared; add one with [[app]] and a 'script'",
  )
  // An empty table is still an app table, so it fails on the missing script.
  assert_eq(config_error("[[app]]\n", "/srv"), "every app needs a 'script'")
  // A scalar in the list is not an app at all. TOML cannot express that, so
  // this is checked through the JSON reader.
  let json = @json.parse("{\"app\": [3]}") catch { _ => fail("invalid JSON") }
  match @pm3.apps_from_json(json, "/srv") {
    Ok(_) => fail("expected a non-table app entry to be refused")
    Err(message) => assert_eq(message, "every [[app]] entry must be a table")
  }
}

///|
test "app config: has_apps distinguishes a config file from other documents" {
  assert_true(@pm3.has_apps(config_toml_json("[[app]]\nscript = \"sh\"\n")))
  assert_false(
    @pm3.has_apps(config_toml_json("[logrotate]\nmax_size = \"1M\"\n")),
  )
  // The JSON spelling `apps` is accepted too.
  let plural = @json.parse("{\"apps\":[{\"script\":\"sh\"}]}") catch {
    _ => fail("invalid JSON")
  }
  assert_true(@pm3.has_apps(plural))
}

///|
test "app config: a config file on disk is read, and only toml or json are" {
  let dir = "/tmp/pm3_appconfig_test"
  ignore(@fs.create_dir(dir)) catch {
    _ => ()
  }
  let path = "\{dir}/pm3.toml"
  @fs.write_string_to_file(
    path, "[[app]]\nname = \"ondisk\"\nscript = \"sh\"\nargs = [\"-c\", \"true\"]\n",
  )
  assert_true(@pm3.is_app_config_file(path))
  assert_false(@pm3.is_app_config_file("\{dir}/pm3.yaml"))
  match @pm3.load_apps_from_file(path) {
    Ok(apps) => {
      assert_eq(apps.length(), 1)
      assert_eq(apps[0].name, "ondisk")
      // The paths are resolved against the file's own directory.
      assert_eq(apps[0].cwd, dir)
    }
    Err(message) => fail("unexpected config error: \{message}")
  }
  // The rotation policy is global, so a local `[logrotate]` table is refused
  // rather than silently ignored.
  let local_rotate = "\{dir}/local-rotate.toml"
  @fs.write_string_to_file(
    local_rotate, "[logrotate]\nmax_size = \"1M\"\n\n[[app]]\nscript = \"sh\"\n",
  )
  match @pm3.load_apps_from_file(local_rotate) {
    Ok(_) => fail("expected a local [logrotate] table to be refused")
    Err(message) =>
      assert_true(message.contains("log rotation is configured globally"))
  }
  ignore(@fs.remove_file(local_rotate)) catch {
    _ => ()
  }
  // A file whose syntax pm3 does not read is refused loudly.
  let yaml = "\{dir}/pm3.yaml"
  @fs.write_string_to_file(yaml, "app:\n  - script: sh\n")
  match @pm3.load_apps_from_file(yaml) {
    Ok(_) => fail("expected a YAML file to be refused")
    Err(message) => assert_true(message.contains("toml"))
  }
  ignore(@fs.remove_file(path)) catch {
    _ => ()
  }
  ignore(@fs.remove_file(yaml)) catch {
    _ => ()
  }
}
