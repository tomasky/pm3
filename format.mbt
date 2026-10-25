///|
/// Text helpers used by the CLI to render tables and durations.

///|
/// Right-pad `text` with `pad` until it is at least `width` characters wide.
pub fn pad_right(text : String, width : Int32, pad : Char) -> String {
  if text.length() >= width {
    return text
  }
  let buf = StringBuilder()
  buf.write_string(text)
  for _ in 0..<(width - text.length()) {
    buf.write_char(pad)
  }
  buf.to_string()
}

///|
/// Left-pad `text` with `pad` until it is at least `width` characters wide.
pub fn pad_left_text(text : String, width : Int32, pad : Char) -> String {
  pad_left(text, width, pad)
}

///|
/// Shorten `text` to at most `width` characters, appending an ellipsis.
pub fn truncate_text(text : String, width : Int32) -> String {
  if text.length() <= width {
    return text
  }
  if width <= 3 {
    return text.view(start_offset=0, end_offset=width).to_owned()
  }
  text.view(start_offset=0, end_offset=width - 3).to_owned() + "..."
}

///|
/// Split `text` the way PM2 splits option values that are meant to be argument
/// lists: on whitespace, with single and double quotes grouping a run of
/// spaces into one word. The quotes themselves are not part of the words.
///
/// `--max-old-space-size=4096 --trace-warnings` becomes two arguments, and so
/// does `--require "lib/setup file.js"`.
pub fn split_shell_words(text : String) -> Array[String] {
  let out : Array[String] = []
  let buf = StringBuilder()
  let mut quote : Char? = None
  let mut in_word = false
  for char in text {
    match quote {
      Some(open) =>
        if char == open {
          quote = None
        } else {
          buf.write_char(char)
        }
      None =>
        if char == '"' || char == '\'' {
          quote = Some(char)
          in_word = true
        } else if char == ' ' || char == '\t' || char == '\n' || char == '\r' {
          if in_word {
            out.push(buf.to_string())
            buf.reset()
            in_word = false
          }
        } else {
          buf.write_char(char)
          in_word = true
        }
    }
  }
  if in_word {
    out.push(buf.to_string())
  }
  out
}

///|
/// Render a millisecond duration as a short human string.
pub fn format_duration(millis : Int64) -> String {
  if millis <= 0L {
    return "-"
  }
  let secs = millis / 1000L
  if secs < 60L {
    return "\{secs}s"
  }
  let mins = secs / 60L
  if mins < 60L {
    return "\{mins}m"
  }
  let hours = mins / 60L
  if hours < 24L {
    return "\{hours}h\{mins % 60L}m"
  }
  let days = hours / 24L
  "\{days}d\{hours % 24L}h"
}

///|
/// Render the uptime column the way PM2's `UxHelpers.timeSince` does: whole
/// seconds below a minute, then the largest unit that is used *more than
/// once* — 119s stays `119s`, 120s becomes `2m`, 3600s is `60m`, 7200s is
/// `2h` — with `s`, `m`, `h`, `D`, `M` and `Y` as the units.
pub fn format_uptime_pm2(millis : Int64) -> String {
  let seconds = if millis < 0L { 0L } else { millis / 1000L }
  let years = seconds / 31536000L
  if years > 1L {
    return "\{years}Y"
  }
  let months = seconds / 2592000L
  if months > 1L {
    return "\{months}M"
  }
  let days = seconds / 86400L
  if days > 1L {
    return "\{days}D"
  }
  let hours = seconds / 3600L
  if hours > 1L {
    return "\{hours}h"
  }
  let minutes = seconds / 60L
  if minutes > 1L {
    return "\{minutes}m"
  }
  "\{seconds}s"
}

///|
/// Render a table the way PM2 renders its tables through `cli-tableau`: a
/// box-drawing border around every cell, with exactly one space of padding on
/// each side of the content.
///
/// `header` is optional. `pm3 describe` passes `None` to get the key/value
/// shape `pm2 show` prints; `pm3 list` passes column names.
///
/// With `style` set the table is colored the way PM2 colors it: grey borders,
/// a bold cyan header row, and — for the headerless key/value shape — a bold
/// cyan first column. Cells may already contain ANSI codes; their widths are
/// measured on the visible text.
///
/// ```
/// ┌────┬────────┐
/// │ id │ name   │
/// ├────┼────────┤
/// │ 0  │ worker │
/// └────┴────────┘
/// ```
pub fn render_box(
  header : Array[String]?,
  rows : Array[Array[String]],
  style~ : Bool = false,
) -> String {
  let mut columns = match header {
    Some(cells) => cells.length()
    None => 0
  }
  for row in rows {
    if row.length() > columns {
      columns = row.length()
    }
  }
  if columns == 0 {
    return ""
  }
  // Content width per column: the widest cell. The borders add one space on
  // each side, so a rendered cell is `width + 2` columns wide.
  let widths : Array[Int32] = []
  for _ in 0..<columns {
    widths.push(0)
  }
  let measure = fn(cells : Array[String]) {
    for index in 0..<columns {
      if index < cells.length() && visible_width(cells[index]) > widths[index] {
        widths[index] = visible_width(cells[index])
      }
    }
  }
  match header {
    Some(cells) => measure(cells)
    None => ()
  }
  for row in rows {
    measure(row)
  }
  let headerless = header is None
  let buf = StringBuilder()
  let bar = if style { style_gray("│") } else { "│" }
  let border = fn(left : String, middle : String, right : String) {
    let line = StringBuilder()
    line.write_string(left)
    for index in 0..<columns {
      for _ in 0..<(widths[index] + 2) {
        line.write_string("─")
      }
      line.write_string(if index + 1 < columns { middle } else { right })
    }
    let text = line.to_string()
    buf.write_string(if style { style_gray(text) } else { text })
    buf.write_string("\n")
  }
  let content = fn(cells : Array[String], is_header : Bool) {
    buf.write_string(bar)
    for index in 0..<columns {
      let cell = if index < cells.length() { cells[index] } else { "" }
      let inner = pad_visible(" " + cell, widths[index] + 2, ' ')
      // PM2 colors the whole padded cell, not just its text.
      if style && (is_header || (headerless && index == 0)) {
        buf.write_string(bold_cyan(inner))
      } else {
        buf.write_string(inner)
      }
      buf.write_string(bar)
    }
    buf.write_string("\n")
  }
  border("┌", "┬", "┐")
  match header {
    Some(cells) => {
      content(cells, true)
      border("├", "┼", "┤")
    }
    None => ()
  }
  for row in rows {
    content(row, false)
  }
  border("└", "┴", "┘")
  buf.to_string()
}
