/*
 * Small POSIX shims for the pm3 daemon.
 *
 * Everything here is a thin wrapper over libc; the daemon uses it for
 * process-group detaching, liveness probes, timezone offsets and machine
 * detection.
 */

#define _GNU_SOURCE

#include <errno.h>
#include <moonbit.h>
#include <signal.h>
#include <stdint.h>
#include <string.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <crt_externs.h>
#else
/* glibc and musl both expose the original argv[0] under this name. */
extern char *program_invocation_name;
extern char **environ;
#endif

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

/* The `uname(2)` machine, classified the way Node names `process.arch`
 * (what PM2 prints as "Current arch" in its daemon banner). */
MOONBIT_FFI_EXPORT
int32_t pm3_uname_machine(void) {
  struct utsname u;
  if (uname(&u) != 0) {
    return 0;
  }
  if (strcmp(u.machine, "x86_64") == 0 || strcmp(u.machine, "amd64") == 0) {
    return 1;
  }
  if (strcmp(u.machine, "aarch64") == 0 || strcmp(u.machine, "arm64") == 0) {
    return 2;
  }
  if (strncmp(u.machine, "armv", 4) == 0 || strcmp(u.machine, "arm") == 0) {
    return 3;
  }
  if (strcmp(u.machine, "i386") == 0 || strcmp(u.machine, "i686") == 0) {
    return 4;
  }
  if (strncmp(u.machine, "ppc64", 5) == 0) {
    return 5;
  }
  if (strcmp(u.machine, "s390x") == 0) {
    return 6;
  }
  if (strncmp(u.machine, "riscv64", 7) == 0) {
    return 7;
  }
  return 0;
}

/* Rewrite this process's command line so `ps` shows `title`.
 *
 * The kernel renders the visible command line from the argv strings it copied
 * onto the stack at exec, so a process renames itself by overwriting that
 * memory in place — the same trick libuv performs for Node's `process.title`,
 * which is how PM2's `God Daemon` title reaches `ps`. We copy the title over
 * argv[0] and NUL-fill the rest of the argument block, stopping right before
 * the first environment string so `environ` stays intact. A title that does
 * not fit the original argument block is truncated. */
MOONBIT_FFI_EXPORT
void pm3_set_process_title(moonbit_bytes_t title) {
#if defined(__linux__) || defined(__APPLE__)
  int32_t len = Moonbit_array_length(title);
#if defined(__APPLE__)
  char *start = (*_NSGetArgv())[0];
  char **env = *_NSGetEnviron();
#else
  char *start = program_invocation_name;
  char **env = environ;
#endif
  if (start == NULL || len <= 0) {
    return;
  }
  uintptr_t limit = 0;
  for (char **e = env; e != NULL && *e != NULL; e++) {
    uintptr_t addr = (uintptr_t)*e;
    if (addr > (uintptr_t)start && (limit == 0 || addr < limit)) {
      limit = addr;
    }
  }
  if (limit == 0) {
    return;
  }
  size_t avail = (size_t)(limit - (uintptr_t)start);
  size_t n = (size_t)len < avail ? (size_t)len : avail - 1;
  memcpy(start, (const char *)title, n);
  memset(start + n, 0, avail - n);
#else
  (void)title;
#endif
}
