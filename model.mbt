///|
/// The managed-application model.
///
/// `App` doubles as the launch specification and the live runtime record,
/// mirroring PM2's `pm2_env`. It is serialized verbatim to `dump.json` so a
/// restart of the daemon can resurrect the process list.

///|
pub let status_online : String = "online"

///|
pub let status_stopped : String = "stopped"

///|
pub let status_stopping : String = "stopping"

///|
pub let status_launching : String = "launching"

///|
pub let status_errored : String = "errored"

///|
/// A process managed by pm3.
pub(all) struct App {
  // --- identity ---
  mut pm_id : Int
  mut name : String
  /// The namespace the app belongs to — PM2's `pm2_env.namespace`. `default`
  /// unless `--namespace` (or the config file) says otherwise. The field is
  /// named `app_namespace` because `namespace` is a reserved word in MoonBit;
  /// the option and the config key keep PM2's spelling.
  mut app_namespace : String
  // --- launch ---
  mut script : String
  mut args : Array[String]
  /// Empty means "execute `script` directly"; otherwise `script` is passed as
  /// the first argument to this interpreter (e.g. `python3`, `node`, `bash`).
  mut interpreter : String
  /// Arguments passed to the interpreter, before the script — PM2's
  /// `node_args` / `interpreter_args`. For example `["--harmony"]` turns
  /// `node script.js` into `node --harmony script.js`.
  mut interpreter_args : Array[String]
  mut cwd : String
  mut env : Map[String, String]
  // --- logs ---
  mut out_log : String
  mut err_log : String
  /// Send both stdout and stderr to `out_log`.
  mut merge_logs : Bool
  /// Optional `moment`-style prefix stamped onto every log line.
  mut log_date_format : String
  // --- supervision ---
  mut autorestart : Bool
  mut max_restarts : Int
  /// Delay before a restart, in milliseconds.
  mut restart_delay : Int
  /// A process that dies sooner than this is considered unstable.
  mut min_uptime : Int
  /// Restart when RSS exceeds this many bytes. `0` disables the check.
  mut max_memory_restart : Int64
  /// Grace period before SIGKILL, in milliseconds.
  mut kill_timeout : Int
  /// Signal used for graceful shutdown.
  mut kill_signal : String
  /// Exit codes that should *not* trigger an automatic restart.
  mut stop_exit_codes : Array[Int]
  // --- runtime state ---
  mut status : String
  /// The app's own version — the `version` of the nearest `package.json` at
  /// or above its script, PM2's `pm2_env.version`. `N/A` when there is none.
  mut version : String
  /// Login name of the user that started the app, PM2's `pm2_env.username`.
  mut username : String
  /// What the user asked for: `online` or `stopped`.
  mut desired_state : String
  mut pid : Int
  /// The kernel's `starttime` for `pid` (clock ticks since boot, `/proc/<pid>/stat`
  /// field 22), recorded when the process was started. A pid alone does not
  /// name a process — the kernel recycles them — so this is what lets
  /// `resurrect` tell its own orphan from a stranger that inherited the pid,
  /// which is the bug PM2's stale `_tree_pids` caused. `0` means "unknown",
  /// and an unknown pid is never signalled.
  mut pid_start : Int64
  mut restarts : Int
  mut unstable_restarts : Int
  mut created_at : Int64
  mut started_at : Int64
  mut stopped_at : Int64
  mut exit_code : Int
  mut out_log_size : Int64
  mut err_log_size : Int64
  mut memory : Int64
  mut cpu : Double
  mut last_start_ms : Int64
} derive(Eq, Debug, ToJson, FromJson)

///|
/// Default log path for a stream (`out` or `err`) of an application.
pub fn default_log_path(name : String, stream : String) -> String {
  path_join(pm3_log_dir(), "\{name}-\{stream}.log")
}

///|
/// The login name of the user running pm3 — PM2's `pm2_env.username`, taken
/// from `Common.getCurrentUsername`: the passwd entry of the effective user
/// comes first, the usual environment variables are the fallback.
pub fn current_username() -> String {
  match passwd_username() {
    Some(name) => return name
    None => ()
  }
  for key in ["USER", "LNAME", "USERNAME", "SUDO_USER", "C9_USER", "LOGNAME"] {
    match @env.get_env_var(key) {
      Some(value) if value.length() > 0 => return value
      _ => ()
    }
  }
  ""
}

///|
/// `getuid(2)` from the C library.
extern "C" fn pm3_uid() -> Int = "pm3_uid"

///|
/// Resolve `/etc/passwd` for the uid this process runs as.
fn passwd_username() -> String? {
  let uid = pm3_uid()
  if uid < 0 {
    return None
  }
  let text = @fs.read_file_to_string("/etc/passwd") catch { _ => return None }
  for line in text.split("\n") {
    let fields : Array[StringView] = []
    for field in line.split(":") {
      fields.push(field)
    }
    if fields.length() >= 3 {
      match parse_non_negative_int(fields[2]) {
        Some(id) if id == uid => return Some(fields[0].to_owned())
        _ => ()
      }
    }
  }
  None
}

///|
/// The signal `pm3 stop` sends before `kill_timeout` expires. PM2 v7's
/// daemon uses its `KILL_SIGNAL` constant — `PM2_KILL_SIGNAL` when set,
/// `SIGINT` otherwise — so pm3 starts from the same default while still
/// letting each app override it.
pub fn default_kill_signal() -> String {
  match @env.get_env_var("PM2_KILL_SIGNAL") {
    Some(value) if value.length() > 0 => value
    _ => "SIGINT"
  }
}

///|
/// The default grace period before escalating to `SIGKILL`, matching PM2's
/// `KILL_TIMEOUT`.
pub let default_kill_timeout_ms : Int = 1600

///|
/// Build a new application with conservative defaults.
pub fn App::new(name : String, script : String, args : Array[String]) -> App {
  let now = @env.now().reinterpret_as_int64()
  {
    pm_id: -1,
    name,
    app_namespace: "default",
    script,
    args,
    interpreter: "",
    interpreter_args: [],
    cwd: "",
    env: Map([]),
    out_log: default_log_path(name, "out"),
    err_log: default_log_path(name, "err"),
    merge_logs: false,
    log_date_format: "",
    autorestart: true,
    max_restarts: 16,
    restart_delay: 0,
    min_uptime: 1000,
    max_memory_restart: 0L,
    kill_timeout: default_kill_timeout_ms,
    kill_signal: default_kill_signal(),
    stop_exit_codes: [],
    status: status_stopped,
    version: "N/A",
    username: current_username(),
    desired_state: status_stopped,
    pid: 0,
    pid_start: 0L,
    restarts: 0,
    unstable_restarts: 0,
    created_at: now,
    started_at: 0L,
    stopped_at: 0L,
    exit_code: 0,
    out_log_size: 0L,
    err_log_size: 0L,
    memory: 0L,
    cpu: 0.0,
    last_start_ms: 0L,
  }
}

///|
/// The argv pm3 will execute for this app: the interpreter (if any), its
/// arguments, then the script and the script's own arguments.
pub fn App::command_line(self : App) -> (String, Array[String]) {
  if self.interpreter.length() > 0 && self.interpreter != "none" {
    let argv : Array[String] = []
    argv.push_iter(self.interpreter_args.iter())
    argv.push(self.script)
    argv.push_iter(self.args.iter())
    (self.interpreter, argv)
  } else {
    (self.script, self.args.copy())
  }
}

///|
/// Human-readable one-line command, for `pm3 list` and `pm3 describe`.
pub fn App::command_display(self : App) -> String {
  let (cmd, argv) = self.command_line()
  let buf = StringBuilder()
  buf.write_string(cmd)
  for arg in argv {
    buf.write_char(' ')
    buf.write_string(arg)
  }
  buf.to_string()
}

///|
/// Whether the app currently has a live process.
pub fn App::is_online(self : App) -> Bool {
  self.status == status_online || self.status == status_launching
}

///|
/// The pid to show in `list` and `describe`: `0` unless the app is online.
///
/// A record loaded from `dump.json` keeps the last pid it ran with, because
/// `pm3 resurrect` needs it to clear an orphan left by a hard daemon death;
/// that pid must not be presented as if the process were still running.
pub fn App::display_pid(self : App) -> Int {
  if self.is_online() {
    self.pid
  } else {
    0
  }
}

///|
/// Whether a `pm3 stop` was requested.
pub fn App::wants_stop(self : App) -> Bool {
  self.desired_state == status_stopped
}

///|
/// Record that the process just started.
pub fn App::mark_started(self : App, pid : Int) -> Unit {
  self.pid = pid
  self.status = status_online
  self.started_at = @env.now().reinterpret_as_int64()
  self.last_start_ms = self.started_at
  self.exit_code = 0
}

///|
/// Record that the process exited with `code`. The resource samples are
/// dropped with it: PM2's monitor reports `0` for anything that is not
/// running, and the last sample of a dead process is not memory it holds.
pub fn App::mark_exited(self : App, code : Int) -> Unit {
  self.pid = 0
  self.pid_start = 0L
  self.memory = 0L
  self.cpu = 0.0
  self.exit_code = code
  self.stopped_at = @env.now().reinterpret_as_int64()
  if self.wants_stop() {
    self.status = status_stopped
  } else {
    self.status = status_errored
  }
}

///|
/// Whether the process should be restarted after exiting with `code`.
pub fn App::should_restart(self : App, code : Int) -> Bool {
  if self.wants_stop() {
    return false
  }
  if !self.autorestart {
    return false
  }
  if self.stop_exit_codes.contains(code) {
    return false
  }
  self.max_restarts <= 0 || self.restarts < self.max_restarts
}

///|
/// Record one restart, tracking whether the previous run was "unstable".
pub fn App::record_restart(self : App) -> Unit {
  let now = @env.now().reinterpret_as_int64()
  let uptime = now - self.last_start_ms
  if self.last_start_ms > 0L && uptime < self.min_uptime.to_int64() {
    self.unstable_restarts = self.unstable_restarts + 1
  } else {
    self.unstable_restarts = 0
  }
  self.restarts = self.restarts + 1
}

///|
/// A compact JSON description of an app, used for IPC payloads and `--json`.
pub fn App::to_summary_json(self : App) -> Json {
  @json.to_json(self)
}
