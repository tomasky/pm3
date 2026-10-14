///|
/// Daemon state: the process table, shared log sinks and the rotation policy.

///|
/// One supervised application plus its runtime-only handles.
///
/// `app` is a reference to the shared, mutable `App` record, so the request
/// handlers, the supervisor and the dump writer all observe the same object.
pub struct Managed {
  app : @pm3.App
  mut proc : @process.Process?
  mut task : @async.Task[Unit]?
  /// CPU tick counter and wall-clock sample time from the last monitor pass.
  mut last_cpu_ticks : Int64
  mut last_cpu_at : Int64
}

///|
/// Everything the daemon knows.
pub struct DaemonState {
  mut apps : Map[Int, Managed]
  mut next_id : Int
  /// Cleared by `pm3 kill`; the accept loop then returns and the daemon exits.
  mut running : Bool
  /// Rotation policy. Never reassigned, only mutated in place so that sinks
  /// holding a reference see configuration changes immediately.
  config : @pm3.LogrotateConfig
  /// The config file `pm3 set` writes back to, and its syntax.
  config_source : @pm3.ConfigSource
  /// Log sinks keyed by absolute path.
  sinks : Map[String, LogSink]
  /// Rotated files waiting to be gzipped.
  compress_queue : @async.Queue[String]
  mut port : Int
}

///|
/// Create empty state for the given policy.
pub fn DaemonState::new(
  config : @pm3.LogrotateConfig,
  config_source : @pm3.ConfigSource,
) -> DaemonState {
  {
    apps: Map([]),
    next_id: 0,
    running: true,
    config,
    config_source,
    sinks: Map([]),
    compress_queue: @aqueue.Queue::Queue(kind=@aqueue.Unbounded),
    port: 0,
  }
}

///|
/// Look up a managed app by its pm_id.
pub fn DaemonState::get(self : DaemonState, id : Int) -> Managed? {
  self.apps.get(id)
}

///|
/// Look up a managed app by name.
pub fn DaemonState::find_by_name(self : DaemonState, name : String) -> Managed? {
  for _, managed in self.apps {
    if managed.app.name == name {
      return Some(managed)
    }
  }
  None
}

///|
/// All managed apps ordered by pm_id.
pub fn DaemonState::ordered(self : DaemonState) -> Array[Managed] {
  let list : Array[Managed] = []
  for _, managed in self.apps {
    list.push(managed)
  }
  list.sort_by(fn(a, b) { a.app.pm_id - b.app.pm_id })
  list
}

///|
/// The shared log sink for `path`, opening it on first use.
pub async fn DaemonState::sink_for(
  self : DaemonState,
  path : String,
) -> LogSink {
  match self.sinks.get(path) {
    Some(sink) => sink
    None => {
      let sink = LogSink::open(path, self.config, self.compress_queue)
      self.sinks.set(path, sink)
      sink
    }
  }
}

///|
/// Insert a new managed app, assigning it a pm_id.
pub fn DaemonState::add(self : DaemonState, app : @pm3.App) -> Managed {
  let id = self.next_id
  self.next_id = self.next_id + 1
  app.pm_id = id
  let managed : Managed = {
    app,
    proc: None,
    task: None,
    last_cpu_ticks: 0L,
    last_cpu_at: 0L,
  }
  self.apps.set(id, managed)
  managed
}

///|
/// Remove an app from the table.
pub fn DaemonState::remove(self : DaemonState, id : Int) -> Unit {
  self.apps.remove(id)
}

///|
/// Load the process table from `dump.json`, if present.
pub async fn DaemonState::load(self : DaemonState) -> Unit {
  let path = @pm3.pm3_dump_path()
  let exists = @fs.exists(path) catch { _ => false }
  if !exists {
    return
  }
  let text = @fs.read_file(path).text() catch { _ => return }
  let apps : Array[@pm3.App] = @json.from_json(@json.parse(text)) catch {
    _ => return
  }
  for app in apps {
    if app.pm_id >= self.next_id {
      self.next_id = app.pm_id + 1
    }
    self.apps.set(app.pm_id, {
      app,
      proc: None,
      task: None,
      last_cpu_ticks: 0L,
      last_cpu_at: 0L,
    })
  }
}

///|
/// Persist the process table to `dump.json`.
pub async fn DaemonState::save(self : DaemonState) -> Unit {
  let apps : Array[@pm3.App] = []
  for managed in self.ordered() {
    apps.push(managed.app)
  }
  let text = @json.to_json(apps).stringify()
  @fs.write_file(@pm3.pm3_dump_path(), text, create_mode=@fs.CreateOrTruncate) catch {
    _ => ()
  }
}
