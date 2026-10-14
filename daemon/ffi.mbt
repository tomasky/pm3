///|
/// POSIX shims implemented in `stub.c`.

///|
/// Detach from the controlling terminal / create a new session.
pub extern "C" fn pm3_setsid() -> Int = "pm3_setsid"

///|
/// The daemon's own process id.
pub extern "C" fn pm3_getpid() -> Int = "pm3_getpid"

///|
/// `kill(2)`. Returns 0 on success, -1 on error.
pub extern "C" fn pm3_kill(pid : Int, sig : Int) -> Int = "pm3_kill"

///|
/// Non-zero when `pid` refers to a live process.
pub extern "C" fn pm3_pid_alive(pid : Int) -> Int = "pm3_pid_alive"

///|
/// Seconds east of UTC for the system timezone at `epoch_secs`.
pub extern "C" fn pm3_local_offset(epoch_secs : Int64) -> Int = "pm3_local_offset"

///|
/// Memory page size, used to translate `/proc/<pid>/statm`.
pub extern "C" fn pm3_pagesize() -> Int = "pm3_pagesize"

///|
/// `sysconf(_SC_CLK_TCK)`, used to translate CPU tick counts to seconds.
pub extern "C" fn pm3_clk_tck() -> Int = "pm3_clk_tck"

///|
/// Signal numbers, as understood by `kill(2)`.
pub let sig_term : Int = 15

///|
pub let sig_kill : Int = 9

///|
pub let sig_int : Int = 2

///|
pub let sig_hup : Int = 1

///|
/// Map a signal name from the process configuration to a number.
pub fn signal_number(name : String) -> Int {
  match name.trim().to_upper().to_owned() {
    "SIGTERM" | "TERM" | "15" => sig_term
    "SIGKILL" | "KILL" | "9" => sig_kill
    "SIGINT" | "INT" | "2" => sig_int
    "SIGHUP" | "HUP" | "1" => sig_hup
    _ => sig_term
  }
}

///|
/// Whether `pid` is alive.
pub fn pid_alive(pid : Int) -> Bool {
  pid > 0 && pm3_pid_alive(pid) != 0
}

///|
/// Send a signal, ignoring failures.
pub fn send_signal(pid : Int, sig : Int) -> Unit {
  if pid > 0 {
    ignore(pm3_kill(pid, sig))
  }
}
