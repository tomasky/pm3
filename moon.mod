// pm3 — a language-agnostic process manager (PM2-like) with built-in
// log rotation, implemented in MoonBit.
//
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html

name = "kupas/pm3"

version = "0.1.1"

readme = "README.md"

repository = "https://github.com/tomasky/pm3"

license = "MIT"

keywords = [
  "process-manager",
  "pm2",
  "supervisor",
  "daemon",
  "logrotate",
  "log-rotation",
  "cli",
]

description = "A language-agnostic process manager (PM2-like) with built-in log rotation"

preferred_target = "native"

import {
  "moonbitlang/async@0.22.4",
  "moonbitlang/x@0.5.5",
}
