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
