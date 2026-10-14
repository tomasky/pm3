///|
/// Human-readable size parsing and formatting.
///
/// The log rotator accepts limits such as `10M`, `1G`, `512K` or a bare
/// byte count. Unlike the original `pm2-logrotate`, which uses `parseInt`
/// and silently truncates decimals (`1.5G` became `1G`), this parser keeps
/// the fractional part, so `1.5G` really means 1.5 GiB.

///|
/// Multiplier for a size unit suffix. Returns `None` for unknown units.
fn size_unit_factor(unit : StringView) -> Int64? {
  let u = unit.to_upper().to_owned()
  match u {
    "" | "B" => Some(1L)
    "K" | "KB" | "KIB" => Some(1024L)
    "M" | "MB" | "MIB" => Some(1024L * 1024L)
    "G" | "GB" | "GIB" => Some(1024L * 1024L * 1024L)
    "T" | "TB" | "TIB" => Some(1024L * 1024L * 1024L * 1024L)
    _ => None
  }
}

///|
/// Parse the numeric prefix of a size string. Supports a single decimal
/// point. Returns `None` when no digit is present.
fn parse_size_number(text : StringView) -> Double? {
  if text.length() == 0 {
    return None
  }
  let mut value = 0.0
  let mut seen_dot = false
  let mut scale = 0.1
  let mut seen_digit = false
  for i in 0..<text.length() {
    guard text.get_char(i) is Some(c) else { break }
    if c == '.' {
      if seen_dot {
        return None
      }
      seen_dot = true
    } else if c >= '0' && c <= '9' {
      seen_digit = true
      let d = (c.to_int() - '0'.to_int()).to_double()
      if seen_dot {
        value = value + d * scale
        scale = scale * 0.1
      } else {
        value = value * 10.0 + d
      }
    } else {
      return None
    }
  }
  if !seen_digit {
    return None
  }
  Some(value)
}

///|
/// Parse a size string such as `10M` into bytes.
pub fn parse_size(text : StringView) -> Int64? {
  let t = text.trim()
  if t.length() == 0 {
    return None
  }
  // Split the numeric prefix from the unit suffix.
  let mut i = 0
  let n = t.length()
  while i < n {
    guard t.get_char(i) is Some(c) else { break }
    if (c >= '0' && c <= '9') || c == '.' {
      i = i + 1
    } else {
      break
    }
  }
  if i == 0 {
    return None
  }
  let number_part = t.view(start_offset=0, end_offset=i)
  let unit_part = t.view(start_offset=i, end_offset=n).trim()
  guard parse_size_number(number_part) is Some(value) else { return None }
  guard size_unit_factor(unit_part) is Some(factor) else { return None }
  Some((value * factor.to_double()).to_int64())
}

///|
/// Parse a size, falling back to `default` when the input is empty or invalid.
pub fn parse_size_or(text : StringView, default : Int64) -> Int64 {
  match parse_size(text) {
    Some(v) => v
    None => default
  }
}

///|
/// Left-pad `text` with `pad` until it is at least `width` characters wide.
fn pad_left(text : String, width : Int, pad : Char) -> String {
  if text.length() >= width {
    return text
  }
  let buf = StringBuilder()
  for _ in 0..<(width - text.length()) {
    buf.write_char(pad)
  }
  buf.write_string(text)
  buf.to_string()
}

///|
/// Format `value` with a fixed number of decimal places, without relying on
/// locale-aware formatting.
pub fn format_fixed(value : Double, precision : Int) -> String {
  let p = if precision < 0 { 0 } else { precision }
  let mut factor = 1.0
  for _ in 0..<p {
    factor = factor * 10.0
  }
  let scaled = (value * factor).round().to_int64()
  if p == 0 {
    return scaled.to_string()
  }
  let factor_i = factor.to_int64()
  let int_part = scaled / factor_i
  let frac_part = scaled % factor_i
  let frac_str = if frac_part < 0L {
    (-frac_part).to_string()
  } else {
    frac_part.to_string()
  }
  "\{int_part}.\{pad_left(frac_str, p, '0')}"
}

///|
/// Format a byte count with a binary unit and `precision` decimals.
pub fn format_size(bytes : Int64, precision? : Int) -> String {
  let p = match precision {
    Some(p) => p
    None => 2
  }
  if bytes < 1024L {
    return "\{bytes} B"
  }
  let units : Array[(Int64, String)] = [
    (1024L * 1024L * 1024L * 1024L, "TB"),
    (1024L * 1024L * 1024L, "GB"),
    (1024L * 1024L, "MB"),
    (1024L, "KB"),
  ]
  for unit in units {
    let (factor, name) = unit
    if bytes >= factor {
      let scaled = bytes.to_double() / factor.to_double()
      return "\{format_fixed(scaled, p)} \{name}"
    }
  }
  "\{bytes} B"
}
