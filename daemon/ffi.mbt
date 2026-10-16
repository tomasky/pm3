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
/// `uname(2)` machine class: 1 x86-64, 2 aarch64, 3 32-bit ARM, 4 ia32,
/// 5 ppc64, 6 s390x, 7 riscv64, 0 anything else.
pub extern "C" fn pm3_uname_machine() -> Int = "pm3_uname_machine"

///|
/// `sysconf(_SC_CLK_TCK)`, used to translate CPU tick counts to seconds.
pub extern "C" fn pm3_clk_tck() -> Int = "pm3_clk_tck"

///|
/// Rename the process the way PM2 renames its God daemon: the title replaces
/// argv in the memory `ps` reads, so the daemon shows up as
/// `PM3 v0.1.6: God Daemon (/home/me/.pm3)` instead of the binary path.
/// No-op on platforms without a portable way to rewrite argv.
#borrow(title)
pub extern "C" fn pm3_set_process_title(title : Bytes) -> Unit = "pm3_set_process_title"

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
/// Map a signal number back to its name, for the daemon log's exit line.
pub fn signal_name(sig : Int) -> String {
  match sig {
    1 => "SIGHUP"
    2 => "SIGINT"
    3 => "SIGQUIT"
    4 => "SIGILL"
    5 => "SIGTRAP"
    6 => "SIGABRT"
    7 => "SIGBUS"
    8 => "SIGFPE"
    9 => "SIGKILL"
    10 => "SIGUSR1"
    11 => "SIGSEGV"
    12 => "SIGUSR2"
    13 => "SIGPIPE"
    14 => "SIGALRM"
    15 => "SIGTERM"
    16 => "SIGSTKFLT"
    17 => "SIGCHLD"
    18 => "SIGCONT"
    19 => "SIGSTOP"
    20 => "SIGTSTP"
    21 => "SIGTTIN"
    22 => "SIGTTOU"
    23 => "SIGURG"
    24 => "SIGXCPU"
    25 => "SIGXFSZ"
    26 => "SIGVTALRM"
    27 => "SIGPROF"
    28 => "SIGWINCH"
    29 => "SIGIO"
    30 => "SIGPWR"
    31 => "SIGSYS"
    _ => "SIG\{sig}"
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
