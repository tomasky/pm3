/*
 * Small POSIX shims for the pm3 core package.
 *
 * The CLI needs to know whether it is writing to a terminal before it emits
 * colours; everything else here is pure.
 */

#define _GNU_SOURCE

#include <moonbit.h>
#include <unistd.h>

MOONBIT_FFI_EXPORT
int32_t pm3_isatty(int32_t fd) {
  return (int32_t)isatty((int)fd);
}
