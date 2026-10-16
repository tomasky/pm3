///|
/// The command line the daemon renames itself to, the way PM2 shows its God
/// daemon as `PM2 v7.0.4: God Daemon (/home/me/.pm2)`.
///
/// `PM3_DAEMON_TITLE` wins, then PM2's own variable, so a drop-in environment
/// keeps working; an empty value falls through, matching the falsy check in
/// PM2's `process.env.PM2_DAEMON_TITLE || …`.
pub fn daemon_process_title() -> String {
  for name in ["PM3_DAEMON_TITLE", "PM2_DAEMON_TITLE"] {
    match @env.get_env_var(name) {
      Some(value) if value.length() > 0 => return value
      _ => ()
    }
  }
  "PM3 v\{pm3_version}: God Daemon (\{pm3_home()})"
}
