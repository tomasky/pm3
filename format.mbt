///|
/// Text helpers used by the CLI to render tables and durations.

///|
/// Right-pad `text` with `pad` until it is at least `width` characters wide.
pub fn pad_right(text : String, width : Int, pad : Char) -> String {
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
pub fn pad_left_text(text : String, width : Int, pad : Char) -> String {
  pad_left(text, width, pad)
}

///|
/// Shorten `text` to at most `width` characters, appending an ellipsis.
pub fn truncate_text(text : String, width : Int) -> String {
  if text.length() <= width {
    return text
  }
  if width <= 3 {
    return text.view(start_offset=0, end_offset=width).to_owned()
  }
  text.view(start_offset=0, end_offset=width - 3).to_owned() + "..."
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
/// Render a table the way PM2 renders its tables through `cli-tableau`: a
/// box-drawing border around every cell, with exactly one space of padding on
/// each side of the content.
///
/// `header` is optional. `pm3 describe` passes `None` to get the key/value
/// shape `pm2 show` prints; `pm3 list` passes column names.
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
  let widths : Array[Int] = []
  for _ in 0..<columns {
    widths.push(0)
  }
  let measure = fn(cells : Array[String]) {
    for index in 0..<columns {
      if index < cells.length() && cells[index].length() > widths[index] {
        widths[index] = cells[index].length()
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
  let buf = StringBuilder()
  let border = fn(left : String, middle : String, right : String) {
    buf.write_string(left)
    for index in 0..<columns {
      for _ in 0..<(widths[index] + 2) {
        buf.write_string("─")
      }
      buf.write_string(if index + 1 < columns { middle } else { right })
    }
    buf.write_string("\n")
  }
  let content = fn(cells : Array[String]) {
    buf.write_string("│")
    for index in 0..<columns {
      let cell = if index < cells.length() { cells[index] } else { "" }
      buf.write_string(" ")
      buf.write_string(cell)
      for _ in 0..<(widths[index] + 1 - cell.length()) {
        buf.write_string(" ")
      }
      buf.write_string("│")
    }
    buf.write_string("\n")
  }
  border("┌", "┬", "┐")
  match header {
    Some(cells) => {
      content(cells)
      border("├", "┼", "┤")
    }
    None => ()
  }
  for row in rows {
    content(row)
  }
  border("└", "┴", "┘")
  buf.to_string()
}
