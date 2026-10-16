///|
/// ANSI styling for the CLI, in the palette PM2 uses through its color
/// library.
///
/// Colours are emitted only when standard output is a terminal, so piping
/// `pm3 list` into a file or another program prints plain text. `FORCE_COLOR`
/// overrides the terminal check (for tests and for `watch`-like consumers),
/// `NO_COLOR` turns colours off, and `--no-color` does the same for one
/// invocation. The escape sequences mirror PM2's exactly — bold cyan headers,
/// grey table borders, green/red/blue log prefixes — so the two tools' output
/// looks the same side by side.

///|
/// `isatty(3)` from the C library.
pub extern "C" fn pm3_isatty(fd : Int) -> Int = "pm3_isatty"

///|
/// Cached `colors_enabled()` answer: `-1` until computed, then `0` or `1`.
let colors_cache : Ref[Int] = Ref(-1)

///|
/// Enable or disable styling for the rest of this process.
pub fn set_colors_enabled(enabled : Bool) -> Unit {
  colors_cache.val = if enabled { 1 } else { 0 }
}

///|
/// Whether output should be colorized.
///
/// `FORCE_COLOR` wins over everything: an empty value, `1` and `true` force
/// colours on, `0` and `false` force them off. Otherwise `NO_COLOR` (any
/// non-empty value) disables them, and the fallback is whether stdout is a
/// terminal.
pub fn colors_enabled() -> Bool {
  if colors_cache.val >= 0 {
    return colors_cache.val == 1
  }
  let enabled = match @env.get_env_var("FORCE_COLOR") {
    Some(value) => {
      let lowered = value.trim().to_lower().to_owned()
      lowered != "0" && lowered != "false"
    }
    None =>
      match @env.get_env_var("NO_COLOR") {
        Some(value) if value.length() > 0 => false
        _ => pm3_isatty(1) != 0
      }
  }
  colors_cache.val = if enabled { 1 } else { 0 }
  enabled
}

///|
/// Wrap `text` in an ANSI select and its matching reset, unless colours are
/// off.
fn ansi(text : String, open : String, close : String) -> String {
  if !colors_enabled() {
    return text
  }
  open + text + close
}

///|
/// Green text — PM2's colour for "online" and for stdout log lines.
pub fn style_green(text : String) -> String {
  ansi(text, "\u{1b}[32m", "\u{1b}[39m")
}

///|
/// Red text — PM2's colour for stopped/errored states and stderr log lines.
pub fn style_red(text : String) -> String {
  ansi(text, "\u{1b}[31m", "\u{1b}[39m")
}

///|
/// Blue text — PM2's colour for the daemon's own log lines.
pub fn style_blue(text : String) -> String {
  ansi(text, "\u{1b}[34m", "\u{1b}[39m")
}

///|
/// Cyan text.
pub fn style_cyan(text : String) -> String {
  ansi(text, "\u{1b}[36m", "\u{1b}[39m")
}

///|
/// Yellow text — PM2's colour for restarting/created states.
pub fn style_yellow(text : String) -> String {
  ansi(text, "\u{1b}[33m", "\u{1b}[39m")
}

///|
/// Grey text — PM2 draws table borders and muted notes in grey.
pub fn style_gray(text : String) -> String {
  ansi(text, "\u{1b}[90m", "\u{1b}[39m")
}

///|
/// Bold text.
pub fn style_bold(text : String) -> String {
  ansi(text, "\u{1b}[1m", "\u{1b}[22m")
}

///|
/// Faint text.
pub fn style_dim(text : String) -> String {
  ansi(text, "\u{1b}[2m", "\u{1b}[22m")
}

///|
/// Inverted text, for the banner PM2 draws around a title.
pub fn style_inverse(text : String) -> String {
  ansi(text, "\u{1b}[7m", "\u{1b}[27m")
}

///|
/// Bold cyan, the style PM2 gives table headers and `pm3 show` keys.
pub fn bold_cyan(text : String) -> String {
  style_bold(style_cyan(text))
}

///|
/// Bold grey, the style PM2 gives the `[TAILING] …` note.
pub fn bold_gray(text : String) -> String {
  style_bold(style_gray(text))
}

///|
/// Bold green, the style PM2 gives the `online` status.
pub fn green_bold(text : String) -> String {
  style_bold(style_green(text))
}

///|
/// Bold red, the style PM2 gives `errored` and friends.
pub fn red_bold(text : String) -> String {
  style_bold(style_red(text))
}

///|
/// Bold blue, the style PM2 gives the `launching` status.
pub fn blue_bold(text : String) -> String {
  style_bold(style_blue(text))
}

///|
/// Bold yellow, the style PM2 gives `restarting` and `created`.
pub fn yellow_bold(text : String) -> String {
  style_bold(style_yellow(text))
}

///|
/// Bold inverse, the style PM2 gives the ` Describing process … ` banner.
pub fn bold_inverse(text : String) -> String {
  style_bold(style_inverse(text))
}

///|
/// Bright-black background, the style PM2 gives search highlights in logs.
pub fn bg_black_bright(text : String) -> String {
  ansi(text, "\u{1b}[100m", "\u{1b}[49m")
}

///|
/// The length of `text` as it appears on a terminal: ANSI escape sequences
/// contribute nothing.
pub fn visible_width(text : String) -> Int {
  let mut width = 0
  let mut i = 0
  let length = text.length()
  while i < length {
    match text.get_char(i) {
      Some('\u{1b}') => {
        i = i + 1
        if i < length && text.get_char(i) == Some('[') {
          i = i + 1
          let mut done = false
          while i < length && !done {
            match text.get_char(i) {
              Some(c) => {
                i = i + 1
                // CSI ends at the first byte in the range `@` to `~`.
                if c >= '@' && c <= '~' {
                  done = true
                }
              }
              None => done = true
            }
          }
        }
      }
      Some(_) => {
        width = width + 1
        i = i + 1
      }
      None => i = i + 1
    }
  }
  width
}

///|
/// Pad `text` on the right with spaces until it is `width` terminal columns
/// wide. Unlike `pad_right`, ANSI escape sequences in `text` are not counted,
/// which is what lets `render_box` lay out pre-coloured cells.
pub fn pad_visible(text : String, width : Int, pad : Char) -> String {
  let visible = visible_width(text)
  if visible >= width {
    return text
  }
  let buf = StringBuilder()
  buf.write_string(text)
  for _ in 0..<(width - visible) {
    buf.write_char(pad)
  }
  buf.to_string()
}
