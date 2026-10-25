///|
/// A small, dependency-free cron engine used to schedule forced log
/// rotations.
///
/// `pm2-logrotate` depends on `node-schedule` for this. pm3 only needs the
/// subset of cron that is useful for log rotation, so it is implemented here
/// directly. Supported syntax:
///
/// - `*` and `*/step`
/// - `a`, `a-b`, `a-b/step`, `a/step`
/// - comma separated lists, e.g. `0,30`
/// - month and weekday names, e.g. `JAN`, `MON`
/// - 5 fields (`min hour dom month dow`) or 6 fields with seconds first
/// - the usual `@hourly`, `@daily`, `@weekly`, `@monthly`, `@yearly` aliases
///
/// When both day-of-month and day-of-week are restricted, the schedule fires
/// if *either* matches, matching Vixie cron.

///|
/// Parsed cron schedule. Fields are sorted ascending and de-duplicated.
pub struct CronSpec {
  seconds : Array[Int32]
  minutes : Array[Int32]
  hours : Array[Int32]
  days_of_month : Array[Int32]
  months : Array[Int32]
  days_of_week : Array[Int32]
  seconds_restricted : Bool
  dom_restricted : Bool
  dow_restricted : Bool
} derive(Eq, Debug)

///|
fn cron_name_table(kind : Int32) -> Array[String] {
  if kind == 0 {
    [
      "JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV",
      "DEC",
    ]
  } else {
    ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
  }
}

///|
/// Resolve a numeric or symbolic cron value. `kind` selects the month (0) or
/// weekday (1) name table.
fn cron_atom(text : StringView, kind : Int32) -> Int32? {
  let t = text.trim()
  if t.length() == 0 {
    return None
  }
  let upper = t.to_upper().to_owned()
  if kind >= 0 {
    let names = cron_name_table(kind)
    for i in 0..<names.length() {
      if names[i] == upper {
        // Month names are 1-based in cron; weekday names are 0-based.
        return Some(if kind == 0 { i + 1 } else { i })
      }
    }
  }
  Some(@string.parse_int(t)) catch {
    _ => None
  }
}

///|
/// Parse one cron field into the list of accepted values.
/// Returns the values plus whether the field was restricted (i.e. not `*`).
fn parse_cron_field(
  field : StringView,
  min_value : Int32,
  max_value : Int32,
  kind : Int32,
) -> (Array[Int32], Bool)? {
  let raw = field.trim()
  if raw.length() == 0 {
    return None
  }
  let restricted = !(raw.length() == 1 && raw.get_char(0) is Some('*'))
  let values : Array[Int32] = []
  for part in raw.split(",") {
    let item = part.trim()
    if item.length() == 0 {
      return None
    }
    // Separate the optional `/step` suffix.
    let (range_text, step) = match item.split_once("/") {
      Some((range, step_text)) => {
        guard cron_atom(step_text, -1) is Some(s) && s > 0 else { return None }
        (range, s)
      }
      None => (item, 1)
    }
    let (start, end) = if range_text.length() == 1 &&
      range_text.get_char(0) is Some('*') {
      (min_value, max_value)
    } else {
      match range_text.split_once("-") {
        Some((a, b)) => {
          guard cron_atom(a, kind) is Some(start) else { return None }
          guard cron_atom(b, kind) is Some(end) else { return None }
          (start, end)
        }
        None => {
          guard cron_atom(range_text, kind) is Some(single) else { return None }
          // `a/n` in cron means "from a to max, step n".
          if step > 1 {
            (single, max_value)
          } else {
            (single, single)
          }
        }
      }
    }
    if start < min_value || end > max_value || start > end {
      return None
    }
    let mut v = start
    while v <= end {
      if !values.contains(v) {
        values.push(v)
      }
      v = v + step
    }
  }
  if values.length() == 0 {
    return None
  }
  values.sort()
  Some((values, restricted))
}

///|
/// Expand a `@alias` into its five-field equivalent.
fn expand_cron_alias(expr : String) -> String? {
  match expr {
    "@yearly" | "@annually" => Some("0 0 1 1 *")
    "@monthly" => Some("0 0 1 * *")
    "@weekly" => Some("0 0 * * 0")
    "@daily" | "@midnight" => Some("0 0 * * *")
    "@hourly" => Some("0 * * * *")
    _ => None
  }
}

///|
/// Parse a cron expression. Returns `None` for malformed input.
pub fn parse_cron(expr : String) -> CronSpec? {
  let trimmed = expr.trim()
  if trimmed.length() == 0 {
    return None
  }
  let expanded = match expand_cron_alias(trimmed.to_owned()) {
    Some(e) => e
    None => trimmed.to_owned()
  }
  let fields : Array[String] = []
  for field in expanded.split(" ") {
    if field.length() > 0 {
      fields.push(field.to_owned())
    }
  }
  let (sec_text, min_text, hour_text, dom_text, month_text, dow_text) = match
    fields.length() {
    5 => ("0", fields[0], fields[1], fields[2], fields[3], fields[4])
    6 => (fields[0], fields[1], fields[2], fields[3], fields[4], fields[5])
    _ => return None
  }
  guard parse_cron_field(sec_text, 0, 59, -1)
    is Some((seconds, seconds_restricted)) else {
    return None
  }
  guard parse_cron_field(min_text, 0, 59, -1) is Some((minutes, _)) else {
    return None
  }
  guard parse_cron_field(hour_text, 0, 23, -1) is Some((hours, _)) else {
    return None
  }
  guard parse_cron_field(dom_text, 1, 31, -1)
    is Some((days_of_month, dom_restricted)) else {
    return None
  }
  guard parse_cron_field(month_text, 1, 12, 0) is Some((months, _)) else {
    return None
  }
  guard parse_cron_field(dow_text, 0, 6, 1)
    is Some((days_of_week, dow_restricted)) else {
    return None
  }
  Some({
    seconds,
    minutes,
    hours,
    days_of_month,
    months,
    days_of_week,
    seconds_restricted,
    dom_restricted,
    dow_restricted,
  })
}

///|
/// Does `spec` fire at local Unix second `epoch_secs` (already offset-shifted)?
pub fn cron_matches(spec : CronSpec, local_secs : Int64) -> Bool {
  let (_, month, day, hour, minute, second, days) = split_timestamp(local_secs)
  if !spec.months.contains(month) {
    return false
  }
  if !spec.hours.contains(hour) || !spec.minutes.contains(minute) {
    return false
  }
  if spec.seconds_restricted && !spec.seconds.contains(second) {
    return false
  }
  let dom_ok = spec.days_of_month.contains(day)
  let dow_ok = spec.days_of_week.contains(weekday_from_days(days))
  if spec.dom_restricted && spec.dow_restricted {
    dom_ok || dow_ok
  } else if spec.dom_restricted {
    dom_ok
  } else if spec.dow_restricted {
    dow_ok
  } else {
    true
  }
}

///|
/// Smallest value in `values` that is strictly greater than `after`.
fn first_greater(values : Array[Int32], after : Int32) -> Int32? {
  for v in values {
    if v > after {
      return Some(v)
    }
  }
  None
}

///|
/// Compute the next fire time strictly after `from_secs`.
///
/// `offset_secs` is the local UTC offset applied before evaluating the
/// calendar fields. Returns `None` when no fire time is found within roughly
/// four years (e.g. for an impossible date such as February 30th).
pub fn next_cron_fire(
  spec : CronSpec,
  from_secs : Int64,
  offset_secs : Int32,
) -> Int64? {
  // Start at the minute that contains `from_secs`, then look for a second
  // inside it that is strictly after `from_secs`.
  let offset = offset_secs.to_int64()
  let mut minute = from_secs / 60L * 60L
  // ~4 years of minutes; bounded so impossible schedules terminate.
  let max_steps = 366 * 24 * 60 * 4
  for _ in 0..<max_steps {
    let local_secs = minute + offset
    let (_, month, day, hour, minute_of_hour, _, days) = split_timestamp(
      local_secs,
    )
    let dom_ok = spec.days_of_month.contains(day)
    let dow_ok = spec.days_of_week.contains(weekday_from_days(days))
    let day_ok = if spec.dom_restricted && spec.dow_restricted {
      dom_ok || dow_ok
    } else if spec.dom_restricted {
      dom_ok
    } else if spec.dow_restricted {
      dow_ok
    } else {
      true
    }
    if spec.months.contains(month) &&
      day_ok &&
      spec.hours.contains(hour) &&
      spec.minutes.contains(minute_of_hour) {
      if spec.seconds_restricted {
        // Find the first allowed second that lands after `from_secs`.
        let threshold = (from_secs - minute).to_int()
        match first_greater(spec.seconds, threshold) {
          Some(sec) => return Some(minute + sec.to_int64())
          None => ()
        }
      } else if minute > from_secs {
        return Some(minute)
      }
    }
    minute = minute + 60L
  }
  None
}
