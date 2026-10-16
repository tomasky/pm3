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

///|
/// Tests for interpreter resolution: the decisions `pm3 start` makes about
/// whether a script runs directly, under node, or under the interpreter its
/// extension names.

///|
async test "which resolves commands on PATH and rejects the rest" {
  assert_true(@daemon.which("sh") is Some(_))
  assert_eq(@daemon.which("pm3-surely-not-a-command"), None)
  assert_eq(@daemon.which(""), None)
  // An absolute path is checked in place, and a directory never counts.
  assert_eq(@daemon.which("/bin/sh"), Some("/bin/sh"))
  assert_eq(@daemon.which("/tmp"), None)
}

///|
async test "resolve_script prefers the working directory, then PATH" {
  // Nothing called `sh` in this directory, so the PATH lookup wins.
  assert_eq(
    @daemon.resolve_script("sh", "/pm3-no-such-dir"),
    @daemon.which("sh"),
  )
  assert_eq(@daemon.resolve_script("no-such-thing", "/pm3-no-such-dir"), None)
  assert_eq(@daemon.resolve_script("/bin/sh", ""), Some("/bin/sh"))
}

///|
async test "resolve_script finds a file relative to the app directory" {
  let dir = "/tmp/pm3-resolve-script-test"
  @fs.mkdir(dir, recursive=true, allow_exist=true) catch {
    _ => ()
  }
  let path = dir + "/worker.sh"
  @fs.write_file(path, "#!/bin/sh\n", create_mode=@fs.CreateOrTruncate) catch {
    _ => abort("cannot write " + path)
  }
  assert_eq(@daemon.resolve_script("worker.sh", dir), Some(path))
  @fs.remove(path) catch {
    _ => ()
  }
  @fs.rmdir(dir) catch {
    _ => ()
  }
}

///|
async test "resolve_start_spec runs a binary directly" {
  let app = @pm3.App::new("echo", "/bin/echo", [])
  assert_true(@daemon.resolve_start_spec(app) is Ok(_))
  assert_eq(app.interpreter, "none")
}

///|
async test "resolve_start_spec reports a missing interpreter in PM2's words" {
  let app = @pm3.App::new("x", "/bin/echo", [])
  app.interpreter = "pm3-no-such-interpreter"
  match @daemon.resolve_start_spec(app) {
    Ok(_) => abort("expected the interpreter to be rejected")
    Err(message) =>
      assert_eq(
        message, "Interpreter pm3-no-such-interpreter is NOT AVAILABLE in PATH. (type 'which pm3-no-such-interpreter' to double check.)",
      )
  }
}

///|
async test "resolve_start_spec reports a missing script in PM2's words" {
  let app = @pm3.App::new("x", "/no/such/script.js", [])
  match @daemon.resolve_start_spec(app) {
    Ok(_) => abort("expected the script to be rejected")
    Err(message) => assert_eq(message, "Script not found: /no/such/script.js")
  }
  // A relative script is reported against the app's working directory.
  let nested = @pm3.App::new("x", "app.js", [])
  nested.cwd = "/srv/app"
  match @daemon.resolve_start_spec(nested) {
    Err(message) => assert_eq(message, "Script not found: /srv/app/app.js")
    Ok(_) => abort("expected the script to be rejected")
  }
}

///|
async test "resolve_start_spec unbuffers python interpreters" {
  match @daemon.which("python3") {
    None => () // no python3 on this machine: nothing to check
    Some(_) => {
      let app = @pm3.App::new("x", "/bin/echo", [])
      app.interpreter = "python3"
      assert_true(@daemon.resolve_start_spec(app) is Ok(_))
      assert_eq(app.env.get("PYTHONUNBUFFERED"), Some("1"))
    }
  }
}
