/*
 * Small POSIX shims for the pm3 daemon.
 *
 * Everything here is a thin wrapper over libc; the daemon uses it for
 * process-group detaching, liveness probes and timezone offsets.
 */

#define _GNU_SOURCE

#include <errno.h>
#include <moonbit.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>

MOONBIT_FFI_EXPORT
int32_t pm3_pagesize(void) {
  return (int32_t)sysconf(_SC_PAGESIZE);
}

MOONBIT_FFI_EXPORT
int32_t pm3_clk_tck(void) {
  return (int32_t)sysconf(_SC_CLK_TCK);
}

MOONBIT_FFI_EXPORT
int32_t pm3_setsid(void) {
  return (int32_t)setsid();
}

MOONBIT_FFI_EXPORT
int32_t pm3_getpid(void) {
  return (int32_t)getpid();
}

MOONBIT_FFI_EXPORT
int32_t pm3_kill(int32_t pid, int32_t sig) {
  return (int32_t)kill((pid_t)pid, sig);
}

/* Return non-zero when `pid` exists and we may signal it. */
MOONBIT_FFI_EXPORT
int32_t pm3_pid_alive(int32_t pid) {
  if (pid <= 0) {
    return 0;
  }
  if (kill((pid_t)pid, 0) == 0) {
    return 1;
  }
  /* EPERM means the process exists but belongs to another user. */
  return errno == EPERM ? 1 : 0;
}

/* Seconds east of UTC for the system timezone at `epoch_secs`. */
MOONBIT_FFI_EXPORT
int32_t pm3_local_offset(int64_t epoch_secs) {
  time_t t = (time_t)epoch_secs;
  struct tm tm;
  if (localtime_r(&t, &tm) == NULL) {
    return 0;
  }
  return (int32_t)tm.tm_gmtoff;
}
