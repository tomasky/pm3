///|
/// The daemon-side log writer.
///
/// Every managed log file is owned by exactly one `LogSink`. Child processes
/// never hold the log fd: their stdout/stderr are pipes that the daemon pumps
/// into the sink. That ownership is what makes the optimized rotation
/// possible — the daemon can *rename* the live file and *reopen* a fresh one
/// atomically, with no copy, no truncate, no data loss and no sparse holes.
///
/// The sink is a shared, mutable object: the log pump and the rotation runner
/// both hold a reference to the same instance, and the embedded mutex keeps
/// their interleaved async operations consistent.

///|
/// A single managed log file.
pub struct LogSink {
  /// Absolute path of the live log file.
  path : String
  /// The shared rotation policy (mutated in place by `pm3 set logrotate`).
  config : @pm3.LogrotateConfig
  /// Queue receiving paths of freshly rotated files to gzip.
  compress_queue : @async.Queue[String]
  mut file : @fs.File
  mut size : Int64
  /// Serializes writes and rotations.
  lock : @async.Mutex
  /// Set by `pm3 reloadLogs` / the cron trigger; acted on by the next write.
  mut rotate_requested : Bool
  /// Cached UTC offset for file names, refreshed by the rotation runner.
  mut tz_offset : Int
  /// Wall-clock time of the last retention pass, to throttle pruning after a
  /// burst of rotations.
  mut last_prune_ms : Int64
  mut closed : Bool
}

///|
/// Open (creating if needed) the log file at `path`.
pub async fn LogSink::open(
  path : String,
  config : @pm3.LogrotateConfig,
  compress_queue : @async.Queue[String],
) -> LogSink {
  let file = @fs.open(
    path,
    mode=@fs.WriteOnly,
    append=true,
    create_mode=@fs.OpenOrCreate,
  )
  let size = @fs.file_size(path) catch { _ => 0L }
  {
    path,
    config,
    compress_queue,
    file,
    size,
    lock: @async.Mutex(),
    rotate_requested: false,
    tz_offset: pm3_local_offset(@async.now() / 1000L),
    last_prune_ms: 0L,
    closed: false,
  }
}

///|
/// Append `data`, rotating first if the policy demands it.
pub async fn LogSink::write(self : LogSink, data : Bytes) -> Unit {
  self.lock.acquire()
  defer self.lock.release()
  if self.closed {
    return
  }
  if self.rotate_requested {
    self.do_rotate()
  }
  self.file.write(data)
  self.size = self.size + data.length().to_int64()
  if @pm3.rotation_due(self.size, self.config) {
    self.do_rotate()
  }
}

///|
/// Rotate when the size policy says so. Called periodically by the runner so
/// that a log which stopped receiving writes still gets rotated.
pub async fn LogSink::maybe_rotate(self : LogSink) -> Unit {
  self.lock.acquire()
  defer self.lock.release()
  if self.closed {
    return
  }
  if self.rotate_requested || @pm3.rotation_due(self.size, self.config) {
    self.do_rotate()
  }
}

///|
/// Ask for a rotation on the next write (or the next runner tick).
pub fn LogSink::request_rotate(self : LogSink) -> Unit {
  self.rotate_requested = true
}

///|
/// Discard the current contents of the live log. Used by `pm3 flush`.
pub async fn LogSink::flush(self : LogSink) -> Unit {
  self.lock.acquire()
  defer self.lock.release()
  if self.closed {
    return
  }
  self.file.close()
  self.file = @fs.open(
    self.path,
    mode=@fs.WriteOnly,
    append=true,
    create_mode=@fs.CreateOrTruncate,
  )
  self.size = 0L
}

///|
/// Close the underlying descriptor.
pub async fn LogSink::close(self : LogSink) -> Unit {
  self.lock.acquire()
  defer self.lock.release()
  if !self.closed {
    self.closed = true
    self.file.close()
  }
}

///|
/// Delete rotated siblings beyond the retention policy.
pub async fn LogSink::prune(self : LogSink, now : Int64) -> Unit {
  let dir = @pm3.path_dirname(self.path)
  let names = @fs.readdir(dir) catch { _ => return }
  let files : Array[@pm3.RotatedFile] = []
  for name in names {
    match @pm3.parse_rotated_stamp(self.path, name) {
      Some(_) => {
        let full = @pm3.path_join(dir, name)
        let mtime = @fs.mtime(full) catch { _ => continue }
        files.push({ name: full, mtime: mtime.0, })
      }
      None => ()
    }
  }
  let doomed = @pm3.select_for_deletion(
    files,
    self.config.retain,
    self.config.max_age_days,
    now,
  )
  for path in doomed {
    @fs.remove(path) catch {
      _ => ()
    }
  }
}

///|
/// The rename-and-reopen rotation. Must be called with `self.lock` held.
///
/// Empty logs are left alone: rotating them would only litter the directory
/// with zero-byte files.
async fn LogSink::do_rotate(self : LogSink) -> Unit {
  self.rotate_requested = false
  if self.size <= 0L {
    return
  }
  let now = @async.now() / 1000L
  let stamp = @pm3.format_timestamp(
    now,
    self.tz_offset,
    self.config.date_format,
  )
  // The rename target is always the uncompressed `.log` name; the gzip worker
  // later turns it into `.log.gz`, which is what `rotated_path(.., true)`
  // names. Avoid clobbering a sibling rotated in the same clock tick.
  let mut target = @pm3.rotated_path(self.path, stamp, false)
  let mut collision = 0
  while (@fs.exists(target) catch { _ => false }) {
    collision = collision + 1
    target = @pm3.rotated_path(self.path, "\{stamp}-\{collision}", false)
  }
  self.file.close()
  @fs.rename(self.path, target, replace=true)
  self.file = @fs.open(
    self.path,
    mode=@fs.WriteOnly,
    append=true,
    create_mode=@fs.OpenOrCreate,
  )
  self.size = 0L
  if self.config.compress {
    self.compress_queue.put(target)
  }
  // A busy log can rotate many times between two runner passes. Prune here,
  // throttled to once a second, so retention stays close to the configured
  // count instead of overshooting by a whole worker interval.
  let now_ms = @async.now()
  if now_ms - self.last_prune_ms >= 1000L {
    self.last_prune_ms = now_ms
    self.prune(now)
  }
}
