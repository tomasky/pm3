/*
 * Process-exit shim for the CLI.
 *
 * PM2 reports a failed command through the process exit status, and pm3 is
 * meant to be usable from scripts and CI, so it does the same. `exit(3)` is
 * the right primitive here: the async stdio layer writes straight to the file
 * descriptors without buffering in user space, so nothing is left behind.
 */

#include <moonbit.h>
#include <stdlib.h>

MOONBIT_FFI_EXPORT
void pm3_exit(int32_t status) {
  exit((int)status);
}
