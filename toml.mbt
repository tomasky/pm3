///| A dependency-free TOML reader.
///
/// pm3 reads configuration, not arbitrary data, so this implements the parts of
/// TOML 1.0 that configuration files actually use: comments, bare, quoted and
/// dotted keys, basic, literal and multiline strings, integers in every base,
/// floats, booleans, arrays, inline tables, `[tables]` and `[[arrays of
/// tables]]`. The result is a `Json` tree, which means TOML and JSON configs
/// converge immediately and only one loader has to be maintained downstream.

///|
/// Raised while reading a TOML document. It stays private: `parse_toml`
/// converts it to a `Result` so callers can report the failure with the file
/// name in context.
priv suberror TomlError {
  TomlError(String)
}

///|
/// A cursor over the source text plus the table that bare keys land in.
/// `root` and `table` are both `Map`s, and MoonBit `Map`s are reference types,
/// so a nested table written into the tree stays linked to the tree.
priv struct TomlParser {
  src : String
  len : Int
  mut pos : Int
  mut line : Int
  root : Map[String, Json]
  mut table : Map[String, Json]
}

///|
/// Parse a TOML document into the same `Json` shape that the JSON loader
/// produces, so both config formats share one downstream path.
///
/// The error string carries the offending line number.
pub fn parse_toml(source : String) -> Result[Json, String] {
  Ok(TomlParser::new(source).parse()) catch {
    TomlError(msg) => Err("toml: " + msg)
  }
}

///|
fn TomlParser::new(src : String) -> TomlParser {
  let root : Map[String, Json] = Map([])
  { src, len: src.length(), pos: 0, line: 1, root, table: root, }
}

// ---------------------------------------------------------------------------
// Cursor helpers
// ---------------------------------------------------------------------------

///|
fn TomlParser::peek(self : TomlParser) -> Char? {
  self.src.get_char(self.pos)
}

///|
fn TomlParser::peek_at(self : TomlParser, offset : Int) -> Char? {
  self.src.get_char(self.pos + offset)
}

///|
fn TomlParser::eof(self : TomlParser) -> Bool {
  self.pos >= self.len
}

///|
/// Consume one code unit, keeping the line counter honest.
fn TomlParser::bump(self : TomlParser) -> Unit {
  match self.src.get_char(self.pos) {
    Some('\n') => {
      self.line += 1
      self.pos += 1
    }
    Some(_) => self.pos += 1
    None => ()
  }
}

///|
/// Report a syntax error. The return type is generic so the call can stand in
/// for any expected value; it never actually returns.
fn[T] TomlParser::fail(self : TomlParser, msg : String) -> T raise TomlError {
  raise TomlError("line " + self.line.to_string() + ": " + msg)
}

// ---------------------------------------------------------------------------
// Whitespace and comments
// ---------------------------------------------------------------------------

///|
fn TomlParser::skip_spaces(self : TomlParser) -> Unit {
  while true {
    match self.peek() {
      Some(' ') | Some('\t') => self.bump()
      _ => break
    }
  }
}

///|
fn TomlParser::skip_comment(self : TomlParser) -> Unit {
  if self.peek() == Some('#') {
    while true {
      match self.peek() {
        Some('\n') | None => break
        Some(_) => self.bump()
      }
    }
  }
}

///|
/// Skip whitespace, comments and blank lines, as allowed between top-level
/// constructs and inside arrays.
fn TomlParser::skip_blank(self : TomlParser) -> Unit {
  while true {
    self.skip_spaces()
    match self.peek() {
      Some('#') => self.skip_comment()
      Some('\n') | Some('\r') => self.bump()
      _ => break
    }
  }
}

///|
/// Consume the remainder of a key/value line, rejecting trailing junk.
fn TomlParser::finish_line(self : TomlParser) -> Unit raise TomlError {
  self.skip_spaces()
  self.skip_comment()
  match self.peek() {
    None => ()
    Some('\n') | Some('\r') => self.bump()
    Some(c) => self.fail("unexpected '" + c.to_string() + "' after a value")
  }
}

// ---------------------------------------------------------------------------
// Keys
// ---------------------------------------------------------------------------

///|
/// A bare key is `A-Za-z0-9_-`; anything else has to be quoted.
fn is_bare_key_char(c : Char) -> Bool {
  let n = c.to_int()
  (n >= 97 && n <= 122) ||
  (n >= 65 && n <= 90) ||
  (n >= 48 && n <= 57) ||
  n == 95 ||
  n == 45
}

///|
fn TomlParser::parse_key(self : TomlParser) -> String raise TomlError {
  match self.peek() {
    Some('"') => self.parse_basic_string()
    Some('\'') => self.parse_literal_string()
    None => self.fail("unexpected end of file while reading a key")
    Some(c) =>
      if is_bare_key_char(c) {
        let buf = StringBuilder()
        while true {
          match self.peek() {
            Some(ch) =>
              if is_bare_key_char(ch) {
                buf.write_char(ch)
                self.bump()
              } else {
                break
              }
            None => break
          }
        }
        buf.to_string()
      } else {
        self.fail("unexpected '" + c.to_string() + "' in a key")
      }
  }
}

///|
/// Read a dotted key such as `logrotate.max_size`.
fn TomlParser::parse_key_path(
  self : TomlParser,
) -> Array[String] raise TomlError {
  let path : Array[String] = []
  while true {
    self.skip_spaces()
    path.push(self.parse_key())
    self.skip_spaces()
    if self.peek() == Some('.') {
      self.bump()
      continue
    }
    break
  }
  path
}

// ---------------------------------------------------------------------------
// Strings
// ---------------------------------------------------------------------------

///|
fn hex_value(c : Char) -> Int? {
  let n = c.to_int()
  if n >= 48 && n <= 57 {
    Some(n - 48)
  } else if n >= 97 && n <= 102 {
    Some(n - 87)
  } else if n >= 65 && n <= 70 {
    Some(n - 55)
  } else {
    None
  }
}

///|
/// Write the character named by `\uXXXX` or `\UXXXXXXXX`. Code points outside
/// the BMP are emitted as a UTF-16 surrogate pair.
fn TomlParser::write_unicode_escape(
  self : TomlParser,
  buf : StringBuilder,
  digits : Int,
) -> Unit raise TomlError {
  self.bump() // 'u' or 'U'
  let mut code = 0
  for _i in 0..<digits {
    let c = match self.peek() {
      Some(c) => c
      None => self.fail("unterminated unicode escape")
    }
    let v = match hex_value(c) {
      Some(v) => v
      None =>
        self.fail("bad hex digit '" + c.to_string() + "' in a unicode escape")
    }
    code = code * 16 + v
    self.bump()
  }
  if code > 0x10FFFF {
    self.fail("unicode escape out of range")
  }
  if code > 0xFFFF {
    let v = code - 0x10000
    buf.write_char((0xD800 + (v >> 10)).unsafe_to_char())
    buf.write_char((0xDC00 + (v & 0x3FF)).unsafe_to_char())
  } else {
    buf.write_char(code.unsafe_to_char())
  }
}

///|
fn TomlParser::write_escape(
  self : TomlParser,
  buf : StringBuilder,
) -> Unit raise TomlError {
  self.bump() // the backslash
  match self.peek() {
    None => self.fail("unterminated escape sequence")
    Some('b') => {
      buf.write_char('\u{8}')
      self.bump()
    }
    Some('t') => {
      buf.write_char('\t')
      self.bump()
    }
    Some('n') => {
      buf.write_char('\n')
      self.bump()
    }
    Some('f') => {
      buf.write_char('\u{c}')
      self.bump()
    }
    Some('r') => {
      buf.write_char('\r')
      self.bump()
    }
    Some('"') => {
      buf.write_char('"')
      self.bump()
    }
    Some('\\') => {
      buf.write_char('\\')
      self.bump()
    }
    Some('u') => self.write_unicode_escape(buf, 4)
    Some('U') => self.write_unicode_escape(buf, 8)
    Some(c) => self.fail("unknown escape '\\" + c.to_string() + "'")
  }
}

///|
/// Read a basic string, `"..."` or `"""..."""`. The caller has already looked
/// at the opening quote.
fn TomlParser::parse_basic_string(self : TomlParser) -> String raise TomlError {
  self.bump()
  let multiline = self.peek() == Some('"') && self.peek_at(1) == Some('"')
  if multiline {
    self.bump()
    self.bump()
    // A newline immediately after the opening delimiter is not part of the value.
    if self.peek() == Some('\r') {
      self.bump()
    }
    if self.peek() == Some('\n') {
      self.bump()
    }
  }
  let buf = StringBuilder()
  while true {
    match self.peek() {
      None => self.fail("unterminated string")
      Some('"') =>
        if multiline {
          if self.peek_at(1) == Some('"') && self.peek_at(2) == Some('"') {
            self.bump()
            self.bump()
            self.bump()
            break
          }
          buf.write_char('"')
          self.bump()
        } else {
          self.bump()
          break
        }
      Some('\\') => self.write_escape(buf)
      Some('\n') =>
        if multiline {
          buf.write_char('\n')
          self.bump()
        } else {
          self.fail("unterminated string")
        }
      Some(c) => {
        buf.write_char(c)
        self.bump()
      }
    }
  }
  buf.to_string()
}

///|
/// Read a literal string, `'...'` or `'''...'''`. Literal strings take no
/// escapes at all, which makes them the right choice for Windows paths.
fn TomlParser::parse_literal_string(
  self : TomlParser,
) -> String raise TomlError {
  self.bump()
  let multiline = self.peek() == Some('\'') && self.peek_at(1) == Some('\'')
  if multiline {
    self.bump()
    self.bump()
    if self.peek() == Some('\r') {
      self.bump()
    }
    if self.peek() == Some('\n') {
      self.bump()
    }
  }
  let buf = StringBuilder()
  while true {
    match self.peek() {
      None => self.fail("unterminated string")
      Some('\'') =>
        if multiline {
          if self.peek_at(1) == Some('\'') && self.peek_at(2) == Some('\'') {
            self.bump()
            self.bump()
            self.bump()
            break
          }
          buf.write_char('\'')
          self.bump()
        } else {
          self.bump()
          break
        }
      Some('\n') =>
        if multiline {
          buf.write_char('\n')
          self.bump()
        } else {
          self.fail("unterminated string")
        }
      Some(c) => {
        buf.write_char(c)
        self.bump()
      }
    }
  }
  buf.to_string()
}

// ---------------------------------------------------------------------------
// Values
// ---------------------------------------------------------------------------

///|
fn TomlParser::parse_value(self : TomlParser) -> Json raise TomlError {
  match self.peek() {
    None => self.fail("expected a value")
    Some('"') => Json::string(self.parse_basic_string())
    Some('\'') => Json::string(self.parse_literal_string())
    Some('[') => self.parse_array()
    Some('{') => self.parse_inline_table()
    Some(_) => self.parse_scalar()
  }
}

///|
/// An array, possibly spanning several lines with comments between elements.
fn TomlParser::parse_array(self : TomlParser) -> Json raise TomlError {
  self.bump() // '['
  let items : Array[Json] = []
  while true {
    self.skip_blank()
    if self.eof() {
      self.fail("unterminated array")
    }
    if self.peek() == Some(']') {
      self.bump()
      break
    }
    items.push(self.parse_value())
    self.skip_blank()
    match self.peek() {
      Some(',') => {
        self.bump()
        continue
      }
      Some(']') => {
        self.bump()
        break
      }
      Some(c) =>
        self.fail(
          "expected ',' or ']' in an array, found '" + c.to_string() + "'",
        )
      None => self.fail("unterminated array")
    }
  }
  Json::array(items)
}

///|
fn TomlParser::parse_inline_table(self : TomlParser) -> Json raise TomlError {
  self.bump() // '{'
  let map : Map[String, Json] = Map([])
  self.skip_spaces()
  if self.peek() == Some('}') {
    self.bump()
    return Json::object(map)
  }
  while true {
    self.skip_spaces()
    let path = self.parse_key_path()
    self.skip_spaces()
    if self.peek() != Some('=') {
      self.fail("expected '=' in an inline table")
    }
    self.bump()
    self.skip_spaces()
    let value = self.parse_value()
    self.assign_into(map, path, value)
    self.skip_spaces()
    match self.peek() {
      Some(',') => {
        self.bump()
        continue
      }
      Some('}') => {
        self.bump()
        break
      }
      Some(c) =>
        self.fail(
          "expected ',' or '}' in an inline table, found '" +
          c.to_string() +
          "'",
        )
      None => self.fail("unterminated inline table")
    }
  }
  Json::object(map)
}

///|
/// Remove the `_` separators TOML allows between digits.
fn strip_underscores(s : String) -> String {
  let buf = StringBuilder()
  for i in 0..<s.length() {
    match s.get_char(i) {
      Some('_') => ()
      Some(c) => buf.write_char(c)
      None => ()
    }
  }
  buf.to_string()
}

///|
/// Accumulate digits in the given radix. `None` means the token is not a
/// well-formed number in that base.
fn parse_digits(s : String, radix : Int64) -> Int64? {
  let mut acc : Int64 = 0L
  let mut any = false
  for i in 0..<s.length() {
    match s.get_char(i) {
      Some('_') => ()
      Some(c) => {
        let d = match hex_value(c) {
          Some(d) => d
          None => return None
        }
        if d.to_int64() >= radix {
          return None
        }
        acc = acc * radix + d.to_int64()
        any = true
      }
      None => ()
    }
  }
  if any {
    Some(acc)
  } else {
    None
  }
}

///|
/// A TOML date or time literal always carries a separator that a number
/// cannot: a `:` in a time, or the `-`s of a date. pm3 keeps them as strings,
/// since configuration never does arithmetic on a timestamp.
fn looks_like_datetime(t : String) -> Bool {
  if t.contains(":") {
    return true
  }
  t.length() >= 10 && t.get_char(4) == Some('-') && t.get_char(7) == Some('-')
}

///|
/// Read an unquoted token: a boolean, a number or a date/time literal.
fn TomlParser::parse_scalar(self : TomlParser) -> Json raise TomlError {
  let start = self.pos
  while true {
    match self.peek() {
      None => break
      Some(c) =>
        if c == ',' ||
          c == ']' ||
          c == '}' ||
          c == '#' ||
          c == '\n' ||
          c == '\r' ||
          c == ' ' ||
          c == '\t' {
          break
        } else {
          self.bump()
        }
    }
  }
  let token = self.src[start:self.pos].to_owned()
  if token.is_empty() {
    self.fail("expected a value")
  }
  if token == "true" {
    return Json::boolean(true)
  }
  if token == "false" {
    return Json::boolean(false)
  }
  if looks_like_datetime(token) {
    return Json::string(token)
  }
  self.parse_number(token)
}

///|
fn TomlParser::parse_number(
  self : TomlParser,
  token : String,
) -> Json raise TomlError {
  let t = strip_underscores(token)
  let negative = t.has_prefix("-")
  let unsigned = if negative || t.has_prefix("+") {
    t[1:].to_owned()
  } else {
    t
  }
  if unsigned.is_empty() {
    self.fail("'" + token + "' is not a number")
  }
  let radix = if unsigned.has_prefix("0x") || unsigned.has_prefix("0X") {
    16L
  } else if unsigned.has_prefix("0o") || unsigned.has_prefix("0O") {
    8L
  } else if unsigned.has_prefix("0b") || unsigned.has_prefix("0B") {
    2L
  } else {
    0L
  }
  if radix != 0L {
    let digits = unsigned[2:].to_owned()
    match parse_digits(digits, radix) {
      Some(v) =>
        if negative {
          Json::number(-v.to_double())
        } else {
          Json::number(v.to_double())
        }
      None =>
        self.fail(
          "'" +
          token +
          "' is not a valid base-" +
          radix.to_string() +
          " integer",
        )
    }
  } else if unsigned == "inf" {
    if negative {
      Json::number(@double.neg_infinity)
    } else {
      Json::number(@double.infinity)
    }
  } else if unsigned == "nan" {
    Json::number(@double.not_a_number)
  } else {
    let cleaned = if negative { "-" + unsigned } else { unsigned }
    let parsed : Double? = Some(@string.parse_double(cleaned)) catch {
      _ => None
    }
    match parsed {
      Some(v) => Json::number(v)
      None => self.fail("'" + token + "' is not a number")
    }
  }
}

// ---------------------------------------------------------------------------
// Tables
// ---------------------------------------------------------------------------

///|
/// Walk a dotted path from `base`, creating intermediate tables. Used both by
/// dotted keys and by table headers.
fn TomlParser::descend(
  self : TomlParser,
  base : Map[String, Json],
  path : Array[String],
  count : Int,
) -> Map[String, Json] raise TomlError {
  let mut target = base
  for i in 0..<count {
    let key = path[i]
    target = match target.get(key) {
      Some(Json::Object(m)) => m
      Some(Json::Array(a)) =>
        // A dotted path through an array of tables refers to its last element.
        if a.length() == 0 {
          self.fail("'" + key + "' is an empty array of tables")
        } else {
          match a[a.length() - 1] {
            Json::Object(m) => m
            _ => self.fail("'" + key + "' is not a table")
          }
        }
      Some(_) => self.fail("'" + key + "' is already a value, not a table")
      None => {
        let m : Map[String, Json] = Map([])
        target.set(key, Json::object(m))
        m
      }
    }
  }
  target
}

///|
/// Store `value` at a dotted path relative to `base`.
fn TomlParser::assign_into(
  self : TomlParser,
  base : Map[String, Json],
  path : Array[String],
  value : Json,
) -> Unit raise TomlError {
  if path.is_empty() {
    self.fail("empty key")
  }
  let target = self.descend(base, path, path.length() - 1)
  target.set(path[path.length() - 1], value)
}

///|
/// `[table]` or `[[array of tables]]`. The header switches the table that
/// subsequent bare keys are written into.
fn TomlParser::parse_table_header(self : TomlParser) -> Unit raise TomlError {
  self.bump() // '['
  let is_array = self.peek() == Some('[')
  if is_array {
    self.bump()
  }
  self.skip_spaces()
  let path = self.parse_key_path()
  self.skip_spaces()
  if self.peek() != Some(']') {
    self.fail("expected ']' to close a table header")
  }
  self.bump()
  if is_array {
    if self.peek() != Some(']') {
      self.fail("expected ']]' to close an array-of-tables header")
    }
    self.bump()
  }
  let last = path.length() - 1
  let parent = self.descend(self.root, path, last)
  let key = path[last]
  if is_array {
    let arr = match parent.get(key) {
      Some(Json::Array(a)) => a
      Some(_) =>
        self.fail(
          "'" + key + "' is already defined and is not an array of tables",
        )
      None => {
        let a : Array[Json] = []
        parent.set(key, Json::array(a))
        a
      }
    }
    let element : Map[String, Json] = Map([])
    arr.push(Json::object(element))
    self.table = element
  } else {
    self.table = match parent.get(key) {
      Some(Json::Object(m)) => m
      Some(_) =>
        self.fail("'" + key + "' is already defined and is not a table")
      None => {
        let m : Map[String, Json] = Map([])
        parent.set(key, Json::object(m))
        m
      }
    }
  }
}

///|
fn TomlParser::parse_key_value(self : TomlParser) -> Unit raise TomlError {
  let path = self.parse_key_path()
  self.skip_spaces()
  if self.peek() != Some('=') {
    self.fail("expected '=' after a key")
  }
  self.bump()
  self.skip_spaces()
  let value = self.parse_value()
  self.assign_into(self.table, path, value)
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

///|
fn TomlParser::parse(self : TomlParser) -> Json raise TomlError {
  while true {
    self.skip_blank()
    if self.eof() {
      break
    }
    match self.peek() {
      Some('[') => self.parse_table_header()
      _ => self.parse_key_value()
    }
    self.finish_line()
  }
  Json::object(self.root)
}
