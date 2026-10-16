///|
/// Whitebox tests for resolving a command's target: name, pm_id, namespace,
/// or the `all` keyword.

///|
/// Build an app row for the selection tests.
fn sel_app(name : String) -> @pm3.App {
  @pm3.App::new(name, "/bin/true", [])
}

///|
/// A state whose table holds `apps`, numbered from zero.
fn sel_state(apps : Array[@pm3.App]) -> DaemonState {
  let state = DaemonState::new(
    @pm3.default_logrotate_config(),
    @pm3.default_config_source(),
  )
  for app in apps {
    let _ = state.add(app)
  }
  state
}

///|
test "selection: lifecycle commands take a name, an id, a namespace or all" {
  let alpha = sel_app("alpha")
  let beta = sel_app("beta")
  beta.app_namespace = "prod"
  let gamma = sel_app("gamma")
  gamma.app_namespace = "prod"
  let named_all = sel_app("all")
  let state = sel_state([alpha, beta, gamma, named_all])
  // No target takes the whole table.
  assert_eq(select_lifecycle_apps(state, @pm3.Request::new("stop")).length(), 4)
  // A name takes that one process.
  let by_name = select_lifecycle_apps(
    state,
    @pm3.Request::with_args("stop", ["beta"]),
  )
  assert_eq(by_name.length(), 1)
  assert_eq(by_name[0].app.name, "beta")
  // A number is a pm_id.
  let by_id = select_lifecycle_apps(
    state,
    @pm3.Request::with_args("stop", ["2"]),
  )
  assert_eq(by_id.length(), 1)
  assert_eq(by_id[0].app.name, "gamma")
  // A namespace takes every process in it.
  let by_namespace = select_lifecycle_apps(
    state,
    @pm3.Request::with_args("restart", ["prod"]),
  )
  assert_eq(by_namespace.length(), 2)
  // `all` is a keyword: it wins over a process that is called `all`.
  let everything = select_lifecycle_apps(
    state,
    @pm3.Request::with_args("restart", ["all"]),
  )
  assert_eq(everything.length(), 4)
  // A miss selects nothing.
  assert_eq(
    select_lifecycle_apps(state, @pm3.Request::with_args("stop", ["ghost"])).length(),
    0,
  )
}

///|
test "selection: a numeric name still resolves when no process carries that id" {
  let state = sel_state([sel_app("7")])
  let found = select_lifecycle_apps(state, @pm3.Request::with_args("stop", ["7"]))
  assert_eq(found.length(), 1)
  assert_eq(found[0].app.name, "7")
}

///|
test "selection: describe takes a name or an id" {
  let state = sel_state([sel_app("alpha"), sel_app("beta")])
  let by_name = select_apps(state, @pm3.Request::with_args("describe", ["alpha"]))
  assert_eq(by_name.length(), 1)
  assert_eq(by_name[0].app.pm_id, 0)
  let by_id = select_apps(state, @pm3.Request::with_args("describe", ["1"]))
  assert_eq(by_id.length(), 1)
  assert_eq(by_id[0].app.name, "beta")
  assert_eq(
    select_apps(state, @pm3.Request::with_args("describe", ["ghost"])).length(),
    0,
  )
  // No target still means the whole table.
  assert_eq(select_apps(state, @pm3.Request::new("flush")).length(), 2)
}

///|
test "selection: the miss message distinguishes an empty table from a bad target" {
  assert_eq(lifecycle_miss(@pm3.Request::new("stop")), "no process found")
  assert_eq(
    lifecycle_miss(@pm3.Request::with_args("stop", ["all"])),
    "no process found",
  )
  assert_eq(
    lifecycle_miss(@pm3.Request::with_args("stop", ["ghost"])),
    "no such process",
  )
}
