///|
/// Whitebox tests for reading `App` records written by another pm3 build.

///|
/// The payload a v0.1.2 daemon answers `list` with, captured from a real
/// daemon: every field of the record as the current build writes it, minus
/// `interpreter_args`, which did not exist yet.
let v012_list_payload : String = "[{\"pm_id\":0,\"name\":\"sifone\",\"script\":\"sifone.js\",\"args\":[]," +
  "\"interpreter\":\"\",\"cwd\":\"\",\"env\":{},\"out_log\":\"/home/dev/.pm3/logs/sifone-out.log\"," +
  "\"err_log\":\"/home/dev/.pm3/logs/sifone-err.log\",\"merge_logs\":false,\"log_date_format\":\"\"," +
  "\"autorestart\":true,\"max_restarts\":16,\"restart_delay\":0,\"min_uptime\":1000," +
  "\"max_memory_restart\":\"0\",\"kill_timeout\":1600,\"kill_signal\":\"SIGTERM\",\"stop_exit_codes\":[]," +
  "\"status\":\"errored\",\"desired_state\":\"online\",\"pid\":0,\"restarts\":0,\"unstable_restarts\":0," +
  "\"created_at\":\"1792144471531\",\"started_at\":\"0\",\"stopped_at\":\"1792144471533\",\"exit_code\":-1," +
  "\"out_log_size\":\"0\",\"err_log_size\":\"0\",\"memory\":\"0\",\"cpu\":0,\"last_start_ms\":\"0\"}]"

///|
/// A record written before `interpreter_args` existed still decodes, with the
/// field backfilled: this is the difference between `pm3 list` showing the
/// table and claiming the daemon manages nothing.
test "app_records_from_json backfills fields an older daemon did not write" {
  let json = @json.parse(v012_list_payload) catch {
    _ => abort("the captured payload must parse")
  }
  let apps = match app_records_from_json(json) {
    Some(apps) => apps
    None => abort("an older daemon's list must decode")
  }
  assert_eq(apps.length(), 1)
  let app = apps[0]
  assert_eq(app.name, "sifone")
  assert_eq(app.pm_id, 0)
  assert_eq(app.status, "errored")
  assert_eq(app.exit_code, -1)
  assert_eq(app.interpreter_args, [])
  // Fields that grew later than v0.1.2 are backfilled with their defaults.
  assert_eq(app.app_namespace, "default")
  assert_eq(app.version, "N/A")
  // The pid identity did not exist yet either: `resurrect` then refuses to
  // signal the pid rather than trusting it.
  assert_eq(app.pid_start, 0L)
}

///|
/// An empty list is a legitimate answer ("nothing is running"), not a decode
/// failure.
test "app_records_from_json accepts an empty list" {
  let json = @json.parse("[]") catch { _ => abort("must parse") }
  match app_records_from_json(json) {
    Some(apps) => assert_eq(apps.length(), 0)
    None => abort("an empty list must decode")
  }
}

///|
/// A payload that is not a list of readable records reports failure, so the
/// CLI can print an error instead of an empty table.
test "app_records_from_json rejects what it cannot read" {
  for payload in ["\"nope\"", "{\"pm_id\":0}", "[{\"pm_id\":\"two\"}]"] {
    let json = @json.parse(payload) catch { _ => abort("must parse") }
    assert_true(app_records_from_json(json) is None)
  }
}

///|
/// `pm3 start` resolves paths the way PM2's CLI does, so the daemon's working
/// directory cannot change what a saved record means.
test "resolve_start_path follows PM2's CLI rules" {
  let base = "/tmp/pm3-resolve-start-path"
  @fs.create_dir(base) catch { _ => () }
  @fs.write_string_to_file(base + "/app.js", "// x") catch { _ => () }
  // A file argument becomes absolute and records the CLI's directory as cwd.
  assert_eq(
    resolve_start_path("app.js", None, base),
    (base + "/app.js", Some(base)),
  )
  // `./` is folded away, and a relative --cwd is resolved too.
  assert_eq(
    resolve_start_path("./app.js", Some("./run"), base),
    (base + "/app.js", Some(base + "/run")),
  )
  // An absolute cwd is kept as it is.
  assert_eq(
    resolve_start_path("app.js", Some("/srv"), base),
    (base + "/app.js", Some("/srv")),
  )
  // A bare name is left alone: it may be a managed process (`pm3 start
  // worker`) or a command looked up on PATH.
  assert_eq(resolve_start_path("worker", None, base), ("worker", None))
  assert_eq(
    resolve_start_path("worker", Some("/srv"), base),
    ("worker", Some("/srv")),
  )
  // So is a path that names no file: the daemon reports it as missing.
  assert_eq(resolve_start_path("/nope/x.js", None, base), ("/nope/x.js", None))
}
