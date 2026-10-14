///|
/// Timestamp formatting for rotated log file names.
///
/// Only the calendar/clock fields that make sense in a file name are
/// supported. Formatting is offset-aware so a daemon can render file names
/// in the host's local time while keeping the rest of its arithmetic in
/// Unix seconds.

///|
/// Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm).
pub fn days_from_civil(year : Int, month : Int, day : Int) -> Int {
  let y = if month <= 2 { year - 1 } else { year }
  let era = (if y >= 0 { y } else { y - 399 }) / 400
  let yoe = y - era * 400
  let mp = if month > 2 { month - 3 } else { month + 9 }
  let doy = (153 * mp + 2) / 5 + day - 1
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  era * 146097 + doe - 719468
}

///|
/// Civil date `(year, month, day)` for a number of days since 1970-01-01.
pub fn civil_from_days(days : Int) -> (Int, Int, Int) {
  let z = days + 719468
  let era = (if z >= 0 { z } else { z - 146096 }) / 146097
  let doe = z - era * 146097
  let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  let y = yoe + era * 400
  let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
  let mp = (5 * doy + 2) / 153
  let d = doy - (153 * mp + 2) / 5 + 1
  let m = if mp < 10 { mp + 3 } else { mp - 9 }
  (if m <= 2 { y + 1 } else { y }, m, d)
}

///|
/// Day of week for a number of days since 1970-01-01 (0 = Sunday).
pub fn weekday_from_days(days : Int) -> Int {
  (days % 7 + 4 + 7) % 7
}

///|
/// Split a local Unix second into its calendar/clock fields.
pub fn split_timestamp(
  local_secs : Int64,
) -> (Int, Int, Int, Int, Int, Int, Int) {
  let days = (local_secs / 86400L).to_int()
  let sod = (local_secs % 86400L).to_int()
  let (y, mo, d) = civil_from_days(days)
  let hh = sod / 3600
  let mi = sod % 3600 / 60
  let ss = sod % 60
  (y, mo, d, hh, mi, ss, days)
}

///|
/// Try to render a single format token at `pos`. Returns the rendered text
/// and the token length, or `None` when no token starts here.
fn render_token(
  fmt : StringView,
  pos : Int,
  year : Int,
  month : Int,
  day : Int,
  hour : Int,
  minute : Int,
  second : Int,
) -> (String, Int)? {
  let rest = fmt.view(start_offset=pos, end_offset=fmt.length())
  // Longest tokens first so that YYYY wins over YY, MM over M, ...
  let tokens : Array[(String, String)] = [
    ("YYYY", pad_left(year.to_string(), 4, '0')),
    ("YY", pad_left((year % 100).to_string(), 2, '0')),
    ("MM", pad_left(month.to_string(), 2, '0')),
    ("DD", pad_left(day.to_string(), 2, '0')),
    ("HH", pad_left(hour.to_string(), 2, '0')),
    ("mm", pad_left(minute.to_string(), 2, '0')),
    ("ss", pad_left(second.to_string(), 2, '0')),
    ("M", month.to_string()),
    ("D", day.to_string()),
    ("H", hour.to_string()),
    ("m", minute.to_string()),
    ("s", second.to_string()),
  ]
  for token in tokens {
    let (pattern, value) = token
    if rest.has_prefix(pattern) {
      return Some((value, pattern.length()))
    }
  }
  None
}

///|
/// Format a Unix second using a subset of the moment.js-style tokens:
/// `YYYY`, `YY`, `MM`, `M`, `DD`, `D`, `HH`, `H`, `mm`, `m`, `ss`, `s`.
pub fn format_timestamp(
  epoch_secs : Int64,
  offset_secs : Int,
  fmt : String,
) -> String {
  let local_secs = epoch_secs + offset_secs.to_int64()
  let (year, month, day, hour, minute, second, _) = split_timestamp(local_secs)
  let out = StringBuilder()
  let mut i = 0
  while i < fmt.length() {
    match render_token(fmt, i, year, month, day, hour, minute, second) {
      Some((text, len)) => {
        out.write_string(text)
        i = i + len
      }
      None => {
        guard fmt.get_char(i) is Some(c) else { break }
        out.write_char(c)
        i = i + 1
      }
    }
  }
  out.to_string()
}
