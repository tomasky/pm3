///|
/// Interpreter resolution, the way PM2 does it.
///
/// PM2 never runs a script naked unless the file is a real executable: it
/// looks the extension up in a small map (`.js` → `node`, `.py` → `python`,
/// `.sh` → `bash`, …), and everything else that is not a binary is handed to
/// `node`. pm3 is language-agnostic, so the mapped commands are looked up on
/// `PATH` like any other program; what it keeps is PM2's decision, so
/// `pm3 start app.js` really runs `node app.js` even when `app.js` has no
/// shebang.
///
/// The pieces here are pure: the filesystem probes (`which`, reading the first
/// bytes of a file) live in the daemon, which is the side that has an async
/// runtime.

///|
/// The extension of `path`, including the dot, as `path.extname` defines it:
/// the last dot of the last component, and nothing for a leading dot or a
/// missing one.
pub fn script_extension(path : String) -> String {
  let base = path_basename(path)
  match base.rev_find(".") {
    Some(index) if index > 0 =>
      base.view(start_offset=index, end_offset=base.length()).to_owned()
    _ => ""
  }
}

///|
/// PM2's `lib/API/interpreter.json`, verbatim.
///
/// The returned name is a command, not a path: it is looked up on `PATH` when
/// the app starts.
pub fn interpreter_for_extension(extension : String) -> String? {
  match extension {
    ".sh" => Some("bash")
    ".py" => Some("python")
    ".rb" => Some("ruby")
    ".php" => Some("php")
    ".pl" => Some("perl")
    ".js" => Some("node")
    ".coffee" => Some("coffee")
    ".ls" => Some("lsc")
    ".ts" => Some("bun")
    ".tsx" => Some("bun")
    _ => None
  }
}

///|
/// Whether a file's first bytes look like a compiled executable rather than
/// text — PM2's `isbinaryfile` heuristic: a NUL byte, or more than 10% of the
/// sample being non-text, means binary. UTF-8 multibyte sequences and a UTF-8
/// BOM are not binary. An empty sample is text.
pub fn is_binary_content(bytes : Bytes) -> Bool {
  let total = if bytes.length() > 512 { 512 } else { bytes.length() }
  if total == 0 {
    return false
  }
  if total >= 3 &&
    bytes[0].to_int() == 0xEF &&
    bytes[1].to_int() == 0xBB &&
    bytes[2].to_int() == 0xBF {
    return false
  }
  let mut suspicious = 0
  let mut i = 0
  while i < total {
    let byte = bytes[i].to_int()
    if byte == 0 {
      return true
    }
    if (byte < 7 || byte > 14) && (byte < 32 || byte > 127) {
      // A UTF-8 two- or three-byte sequence is not suspicious.
      if byte > 193 && byte < 224 && i + 1 < total {
        i = i + 1
        let next = bytes[i].to_int()
        if next > 127 && next < 192 {
          i = i + 1
          continue
        }
      } else if byte > 223 && byte < 240 && i + 2 < total {
        i = i + 1
        let next = bytes[i].to_int()
        if next > 127 && next < 192 {
          let after = bytes[i + 1].to_int()
          if after > 127 && after < 192 {
            i = i + 2
            continue
          }
        }
      }
      suspicious = suspicious + 1
      // Read at least 32 bytes before making a decision.
      if i > 32 && suspicious * 100 / total > 10 {
        return true
      }
    }
    i = i + 1
  }
  suspicious * 100 / total > 10
}

///|
/// Whether a `python` interpreter needs its output unbuffered: PM2 exports
/// `PYTHONUNBUFFERED=1` whenever the interpreter contains `python`, so that
/// logs appear in the file as the program writes them.
pub fn is_python_interpreter(interpreter : String) -> Bool {
  interpreter.contains("python")
}

///|
/// The JS runtime behind an interpreter path or command.
///
/// This is PM2's `lib/tools/interpreter.js` rule, which 7.1.0 grew so that a
/// host is not mistaken for a host with no JavaScript just because its binary
/// is named differently. Only the last path segment counts, Windows
/// executable extensions and a trailing version tag are stripped, and the
/// match is anchored on the end of the name:
///
/// - `node`, `/usr/bin/node`, `nodejs`, `node.exe`, `node64.exe`, `node@18`,
///   `node18`, `node-v20.1.0`, `C:\nvm\v18.0.0\node.exe` are `node`;
/// - `bun`, `/home/ubuntu/.bun/bin/bun`, `bun.exe`, `bun-1.1` are `bun`;
/// - `bundle`, `bunx`, `/home/ubuntu/.venvs/bin/python` are neither (#5990).
pub fn runtime_of(interpreter : String) -> String? {
  let mut name = runtime_basename(interpreter).to_lower()
  for ext in [".exe", ".cmd", ".bat"] {
    match name.view().strip_suffix(ext) {
      Some(view) => name = view.to_owned()
      None => ()
    }
  }
  name = strip_version_tag(name)
  if name == "nodejs" || name.view().has_suffix("node") {
    Some("node")
  } else if name.view().has_suffix("bun") {
    Some("bun")
  } else {
    None
  }
}

///|
/// The last segment of a path, accepting both separators so a Windows path
/// classifies on any host (PM2 splits on `[\\/]`).
fn runtime_basename(path : String) -> String {
  let mut start = 0
  for i in 0..<path.length() {
    match path.get_char(i) {
      Some(ch) if ch == '/' || ch == '\\' => start = i + 1
      _ => ()
    }
  }
  path.view(start_offset=start, end_offset=path.length()).to_owned()
}

///|
/// Drop a trailing version tag: PM2's `[-@_.]?v?\d+(\.\d+)*$`.
///
/// `node18` and `node@18` lose the number and its separator, `node-v20.1.0`
/// loses `-v20.1.0`. A name that does not end in a digit is returned as is,
/// so `node.` is not mistaken for a versioned `node`.
fn strip_version_tag(name : String) -> String {
  let mut index = name.length()
  while index > 0 {
    let ch = match name.get_char(index - 1) {
      Some(ch) => ch
      None => break
    }
    if (ch >= '0' && ch <= '9') || ch == '.' {
      index = index - 1
    } else {
      break
    }
  }
  if index == name.length() {
    return name
  }
  let last = match name.get_char(name.length() - 1) {
    Some(ch) => ch
    None => return name
  }
  if last < '0' || last > '9' {
    return name
  }
  let mut start = index
  if start > 0 {
    match name.get_char(start - 1) {
      Some(ch) if ch == 'v' || ch == 'V' => start = start - 1
      _ => ()
    }
  }
  if start > 0 {
    match name.get_char(start - 1) {
      Some(ch) if ch == '-' || ch == '@' || ch == '_' || ch == '.' =>
        start = start - 1
      _ => ()
    }
  }
  name.view(start_offset=0, end_offset=start).to_owned()
}

///|
/// Whether a node binary can run a `.ts` file, and under which conditions.
pub(all) enum TsSupport {
  /// Type stripping is on by default: no flag needed.
  Native
  /// Type stripping exists but has to be asked for.
  Flag
  /// This node cannot run TypeScript at all.
  Unsupported
} derive(Eq, Debug)

pub extend TsSupport with Eq::{not_equal, equal}

pub extend TsSupport with Debug::{to_repr}

///|
/// What a node version can do with `.ts` files, the way PM2's
/// `lib/tools/typestrip.js` classifies it:
///
/// - `native` from 22.18.0 in the 22 line, and from 23.6.0;
/// - `flag` (`--experimental-strip-types`) from 22.6.0;
/// - `none` before that, and for anything that is not a version at all.
pub fn type_strip_support(version : String) -> TsSupport {
  let (major, minor) = match parse_node_version(version) {
    Some(parsed) => parsed
    None => return Unsupported
  }
  if major >= 24 {
    Native
  } else if major == 23 {
    if minor >= 6 {
      Native
    } else {
      Flag
    }
  } else if major == 22 {
    if minor >= 18 {
      Native
    } else if minor >= 6 {
      Flag
    } else {
      Unsupported
    }
  } else {
    Unsupported
  }
}

///|
/// `(major, minor)` of a `node --version` answer such as `v22.18.0` or
/// `v23.6.0-rc.1`. A `v` prefix is optional.
fn parse_node_version(version : String) -> (Int, Int)? {
  let text = version.trim().to_owned()
  let digits = if text.has_prefix("v") || text.has_prefix("V") {
    text.view(start_offset=1, end_offset=text.length())
  } else {
    text.view()
  }
  let parts : Array[String] = []
  for part in digits.split(".") {
    parts.push(part.to_owned())
  }
  if parts.length() < 2 {
    return None
  }
  let major = match parse_non_negative_int(parts[0].view()) {
    Some(value) => value
    None => return None
  }
  let minor = match parse_non_negative_int(parts[1].view()) {
    Some(value) => value
    None => return None
  }
  Some((major, minor))
}
