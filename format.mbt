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
