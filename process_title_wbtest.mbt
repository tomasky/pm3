///|
/// Whitebox tests for the daemon's `ps` title: the fallback chain mirrors
/// PM2's `process.env.PM2_DAEMON_TITLE || 'PM2 v…: God Daemon (…)'`.

///|
test "daemon_process_title defaults to PM2's shape" {
  let saved3 = @env.get_env_var("PM3_DAEMON_TITLE")
  let saved2 = @env.get_env_var("PM2_DAEMON_TITLE")
  @env.unset_env_var("PM3_DAEMON_TITLE")
  @env.unset_env_var("PM2_DAEMON_TITLE")
  assert_eq(
    daemon_process_title(),
    "PM3 v\{pm3_version}: God Daemon (\{pm3_home()})",
  )
  @env.set_env_var("PM2_DAEMON_TITLE", "PM2 v9.9.9: God Daemon (/legacy)")
  assert_eq(daemon_process_title(), "PM2 v9.9.9: God Daemon (/legacy)")
  @env.set_env_var("PM3_DAEMON_TITLE", "pm3 test title")
  assert_eq(daemon_process_title(), "pm3 test title")
  // PM2's `||` treats an empty override as unset, so it falls through.
  @env.set_env_var("PM3_DAEMON_TITLE", "")
  assert_eq(daemon_process_title(), "PM2 v9.9.9: God Daemon (/legacy)")
  match saved3 {
    Some(v) => @env.set_env_var("PM3_DAEMON_TITLE", v)
    None => @env.unset_env_var("PM3_DAEMON_TITLE")
  }
  match saved2 {
    Some(v) => @env.set_env_var("PM2_DAEMON_TITLE", v)
    None => @env.unset_env_var("PM2_DAEMON_TITLE")
  }
}
