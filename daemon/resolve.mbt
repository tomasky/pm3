///|
/// Turning a launch specification into the exact command pm3 will run.
///
/// This is the pm3 side of PM2's `Common.sink.resolveInterpreter`, and it
/// follows the same order of decisions:
///
/// 1. Find the script — relative to the app's working directory (or the
///    daemon's), falling back to `PATH`, exactly like the spawner will.
/// 2. If the user pinned an interpreter, keep it.
/// 3. Otherwise map the extension (`.js` → `node`, `.py` → `python`, …),
///    run directly when the file is a binary, and fall back to `node`.
/// 4. Refuse an interpreter that is not on `PATH`, with PM2's wording.
///
/// A resolved `python` that is missing falls back to `python3`, and any
/// python interpreter gets `PYTHONUNBUFFERED=1` in its environment so log
/// lines appear when the program writes them, not when the interpreter
/// flushes.

///|
/// `which(1)`: resolve `command` on `PATH`, or check it as a path when it
/// contains a slash. Only an executable, non-directory file counts.
pub async fn which(command : String) -> String? {
  if command.length() == 0 {
    return None
  }
  if command.contains("/") {
    let usable = is_executable_file(command)
    return if usable { Some(command) } else { None }
  }
  let path = match @env.get_env_var("PATH") {
    Some(value) => value
    None => return None
  }
  for dir in path.split(":") {
    if dir.length() == 0 {
      // Empty PATH entries mean the current directory in some shells;
      // PM2's `which` skips them, and so do we.
      continue
    }
    let candidate = @pm3.path_join(dir.to_owned(), command)
    if is_executable_file(candidate) {
      return Some(candidate)
    }
  }
  None
}

///|
/// Whether `path` is a file that `execve(2)` would accept.
async fn is_executable_file(path : String) -> Bool {
  let exists = @fs.exists(path) catch { _ => false }
  if !exists {
    return false
  }
  let kind = @fs.kind(path) catch { _ => @fs.Unknown }
  if kind == @fs.Directory {
    return false
  }
  @fs.can_execute(path) catch {
    _ => false
  }
}

///|
/// The absolute path pm3 will execute for `script`, or `None` when there is
/// nothing to run.
///
/// PM2 resolves the script against the working directory first and only then
/// tries `PATH`, which is what makes `pm3 start sh` run `/bin/sh` while
/// `pm3 start ./sh` runs the file next to the app.
pub async fn resolve_script(script : String, cwd : String) -> String? {
  if script.has_prefix("/") {
    let exists = @fs.exists(script) catch { _ => false }
    if exists {
      return Some(script)
    }
    return which(script)
  }
  let mut base = cwd
  if base.length() == 0 {
    match @env.current_dir() {
      Some(dir) => base = dir
      None => return which(script)
    }
  }
  let full = @pm3.path_join(base, script)
  let exists = @fs.exists(full) catch { _ => false }
  if exists {
    return Some(full)
  }
  which(script)
}

///|
/// What a missing interpreter is reported as, in PM2's words.
fn interpreter_unavailable(interpreter : String) -> String {
  "Interpreter " +
  interpreter +
  " is NOT AVAILABLE in PATH. (type 'which " +
  interpreter +
  "' to double check.)"
}

///|
/// Read at most `max` bytes from the head of a file; `None` when the file
/// cannot be read at all.
async fn read_head(path : String, max : Int) -> Bytes? {
  let file = @fs.open(path, mode=@fs.ReadOnly, create_mode=@fs.OpenExisting) catch {
    _ => return None
  }
  defer file.close()
  let buf = FixedArray::make(max, b'\x00')
  let got = file.read_at(buf, position=0L) catch { _ => return None }
  Some(buf.unsafe_reinterpret_as_bytes()[:got].to_owned())
}

///|
/// PM2's default interpreter for a script pm3 found on disk: the extension
/// map first, then `none` for a real binary, then `node`.
async fn default_interpreter(path : String) -> Result[String, String] {
  match @pm3.interpreter_for_extension(@pm3.script_extension(path)) {
    Some("python") => {
      // PM2 prefers `python` and survives on a `python3`-only system.
      let python = which("python")
      if python is Some(_) {
        return Ok("python")
      }
      let python3 = which("python3")
      if python3 is Some(_) {
        return Ok("python3")
      }
      Err(interpreter_unavailable("python"))
    }
    Some(interpreter) => Ok(interpreter)
    None => {
      match read_head(path, 512) {
        Some(bytes) if @pm3.is_binary_content(bytes) => return Ok("none")
        _ => ()
      }
      // Everything else is JavaScript to PM2; pm3 does the same, so
      // `pm3 start app.js` works for a file with no shebang, which is the
      // behaviour a PM2 user expects.
      match which("node") {
        Some(node) => Ok(node)
        None => Err(interpreter_unavailable("node"))
      }
    }
  }
}

///|
/// How a failing start names the script it could not find.
fn missing_script_message(app : @pm3.App) -> String {
  if app.cwd.length() > 0 && !app.script.has_prefix("/") {
    "Script not found: " + @pm3.path_join(app.cwd, app.script)
  } else {
    "Script not found: " + app.script
  }
}

///|
/// Fill in the interpreter of `app` the way PM2 would when it is started:
/// a pinned interpreter is checked, an unset one is derived from the script,
/// and a python interpreter marks the app's output unbuffered.
pub async fn resolve_start_spec(app : @pm3.App) -> Result[Unit, String] {
  let mut interpreter = app.interpreter
  if interpreter.length() == 0 {
    match resolve_script(app.script, app.cwd) {
      None => return Err(missing_script_message(app))
      Some(path) =>
        match default_interpreter(path) {
          Ok(chosen) => interpreter = chosen
          Err(message) => return Err(message)
        }
    }
    app.interpreter = interpreter
  }
  if interpreter != "none" {
    let found = which(interpreter)
    if found is None {
      return Err(interpreter_unavailable(interpreter))
    }
  }
  if @pm3.is_python_interpreter(interpreter) {
    app.env.set("PYTHONUNBUFFERED", "1")
  }
  Ok(())
}
