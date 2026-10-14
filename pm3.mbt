///|
/// pm3 — a language-agnostic process manager with built-in log rotation.
///
/// This package is the pure, target-independent core:
///
/// - [`size`] / [`format`] — human-readable sizes, durations and table text
/// - [`timefmt`] — civil-date arithmetic and `moment`-style timestamps
/// - [`cron`] — the cron engine that schedules forced rotations
/// - [`paths`] — the `~/.pm3` directory layout
/// - [`logrotate`] — the rotation policy and retention planner
/// - [`model`] — the [`App`] record shared by the daemon and the CLI
/// - [`ipc`] — the line-delimited JSON protocol
///
/// The daemon and the CLI live in the `daemon` and `client` sub-packages;
/// they are the only parts that depend on `moonbitlang/async` and on a native
/// target.
