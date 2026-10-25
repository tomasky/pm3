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
async fn read_head(path : String, max : Int32) -> Bytes? {
  let file = @fs.open(path, mode=@fs.ReadOnly, create_mode=@fs.OpenExisting) catch {
    _ => return None
  }
  defer file.close()
  let buf = FixedArray::make(max, b'\x00')
  let got = file.read_at(buf, position=0L) catch { _ => return None }
  Some(buf.unsafe_reinterpret_as_bytes()[:got].to_owned())
}

///|
/// The canonical names a JS runtime answers to on `PATH`. Debian ships node
/// as `nodejs`, and only that package provides it.
fn runtime_names(runtime : String) -> Array[String] {
  if runtime == "node" {
    ["node", "nodejs"]
  } else {
    [runtime]
  }
}

///|
/// Resolve a JS runtime, the way PM2's interpreter detection does: the
/// canonical names first, then a scan of `PATH` for an anchored runtime name.
///
/// PM2 7.1.0 taught its detection `node.exe`, `node64.exe`, `nodejs`,
/// `node18`, `node@18` and `bun.exe`: a host that installs node as `nodejs`,
/// or a version manager that exposes `node18`, otherwise looks like a host
/// with no JavaScript at all. The anchored match (`interpreter.js` #5990)
/// keeps `bundle` and `bunx` out.
pub async fn which_runtime(runtime : String) -> String? {
  for name in runtime_names(runtime) {
    match which(name) {
      Some(path) => return Some(path)
      None => ()
    }
  }
  let path = match @env.get_env_var("PATH") {
    Some(value) => value
    None => return None
  }
  for dir in path.split(":") {
    if dir.length() == 0 {
      continue
    }
    let names = @fs.readdir(dir) catch { _ => continue }
    for name in names {
      match @pm3.runtime_of(name) {
        Some(kind) if kind == runtime => {
          let candidate = @pm3.path_join(dir.to_owned(), name)
          if is_executable_file(candidate) {
            return Some(candidate)
          }
        }
        _ => ()
      }
    }
  }
  None
}

///|
/// The command to record for `runtime`: its canonical name when that is on
/// `PATH`, otherwise the path of the binary that stands in for it. Recording
/// the name keeps a dump readable and lets a later start resolve `node` to
/// whatever this host installs; recording the path is what makes a version
/// manager's `node18` work at all.
async fn runtime_command(runtime : String) -> String? {
  if which(runtime) is Some(_) {
    return Some(runtime)
  }
  which_runtime(runtime)
}

///|
/// Keep `interpreter` when it resolves, otherwise the variant that stands in
/// for it: `node` on a host whose binary is only called `nodejs`.
async fn resolve_runtime(
  interpreter : String,
  runtime : String,
) -> Result[String, String] {
  if which(interpreter) is Some(_) {
    return Ok(interpreter)
  }
  match runtime_command(runtime) {
    Some(found) => Ok(found)
    None => Err(interpreter_unavailable(interpreter))
  }
}

///|
/// The version a node binary reports (`v22.18.0`). Empty when it cannot be
/// asked, which makes it unable to run TypeScript.
async fn node_version(node : String) -> String {
  let result = @process.collect_stdout(node, ["--version"]) catch {
    _ => return ""
  }
  let (_, data) = result
  let text = data.text() catch { _ => return "" }
  text.trim().to_owned()
}

///|
/// PM2's message for a `.ts` file no installed runtime can run.
fn typescript_unavailable() -> String {
  "TypeScript apps require bun, Node.js >= 22.18 (native type stripping) or a custom interpreter (e.g. --interpreter ts-node)"
}

///|
/// The interpreter for a `.ts` file, in PM2's order: bun when it is
/// installed, then node's type stripping when the node on `PATH` is new
/// enough — native since 22.18, behind `--experimental-strip-types` since
/// 22.6, an error before that (7.0.4). `.tsx` is deliberately not eligible:
/// node strips types but does not transform JSX.
async fn typescript_interpreter() -> Result[(String, Array[String]), String] {
  match runtime_command("bun") {
    Some(bun) => return Ok((bun, []))
    None => ()
  }
  let node = match runtime_command("node") {
    Some(node) => node
    None => return Err(typescript_unavailable())
  }
  // `node` here is the resolved command, which is the plain name on a normal
  // host and the path of a `nodejs`/`node18` binary when that is all there is.
  match @pm3.type_strip_support(node_version(node)) {
    @pm3.TsSupport::Native => Ok((node, []))
    @pm3.TsSupport::Flag => Ok((node, ["--experimental-strip-types"]))
    @pm3.TsSupport::Unsupported => Err(typescript_unavailable())
  }
}

///|
/// PM2's default interpreter for a script pm3 found on disk: the extension
/// map first, then `none` for a real binary, then `node`. The interpreter
/// arguments it needs (only type stripping, today) ride along.
async fn default_interpreter(
  path : String,
) -> Result[(String, Array[String]), String] {
  let extension = @pm3.script_extension(path)
  if extension == ".ts" {
    return typescript_interpreter()
  }
  match @pm3.interpreter_for_extension(extension) {
    Some("python") => {
      // PM2 prefers `python` and survives on a `python3`-only system.
      let python = which("python")
      if python is Some(_) {
        return Ok(("python", []))
      }
      let python3 = which("python3")
      if python3 is Some(_) {
        return Ok(("python3", []))
      }
      Err(interpreter_unavailable("python"))
    }
    Some(interpreter) =>
      // `.js` maps to `node`, which a host may install as `nodejs`.
      match @pm3.runtime_of(interpreter) {
        Some(runtime) =>
          match resolve_runtime(interpreter, runtime) {
            Ok(found) => Ok((found, []))
            Err(message) => Err(message)
          }
        None => Ok((interpreter, []))
      }
    None => {
      match read_head(path, 512) {
        Some(bytes) if @pm3.is_binary_content(bytes) => return Ok(("none", []))
        _ => ()
      }
      // Everything else is JavaScript to PM2; pm3 does the same, so
      // `pm3 start app.js` works for a file with no shebang, which is the
      // behaviour a PM2 user expects.
      match runtime_command("node") {
        Some(node) => Ok((node, []))
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
          Ok((chosen, extra_args)) => {
            interpreter = chosen
            // PM2 appends `--experimental-strip-types` to `node_args` and
            // never twice.
            for arg in extra_args {
              if !app.interpreter_args.contains(arg) {
                app.interpreter_args.push(arg)
              }
            }
          }
          Err(message) => return Err(message)
        }
    }
    app.interpreter = interpreter
  } else if interpreter != "none" {
    // A pinned interpreter that names a runtime may exist under a different
    // binary name: `--interpreter node` on a host that only has `nodejs`.
    match @pm3.runtime_of(interpreter) {
      Some(runtime) =>
        match resolve_runtime(interpreter, runtime) {
          Ok(found) => {
            interpreter = found
            app.interpreter = found
          }
          Err(message) => return Err(message)
        }
      None => ()
    }
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
