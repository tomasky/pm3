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
  /// Rotations performed since the last retention pass. Pruning right after a
  /// few of them keeps the on-disk file count bounded even when a log rotates
  /// far faster than the runner's pass.
  mut rotations_since_prune : Int
  /// Set for the daemon's own log: the daemon writes it through the stderr
  /// the client opened, so a rotation must move that descriptor too.
  redirect_stderr : Bool
  mut closed : Bool
  /// Set when the live file must be (re)opened before the next append: a
  /// rotation renamed the file but the fresh one could not be created yet.
  mut needs_open : Bool
  /// Bytes the pump had to drop because the file would not take them (a full
  /// disk). Reported on the daemon log and reset once writes work again.
  mut dropped_bytes : Int64
  /// Wall-clock time of the last reported sink error, to throttle messages.
  mut last_error_ms : Int64
}

///|
/// Open (creating if needed) the log file at `path`.
pub async fn LogSink::open(
  path : String,
  config : @pm3.LogrotateConfig,
  compress_queue : @async.Queue[String],
  redirect_stderr : Bool,
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
    rotations_since_prune: 0,
    redirect_stderr,
    closed: false,
    needs_open: false,
    dropped_bytes: 0L,
    last_error_ms: 0L,
  }
}

///|
/// (Re)open the live log file. Must be called with `self.lock` held. Raises
/// when the file cannot be opened; `needs_open` then stays set so a later
/// write (or the runner) retries.
async fn LogSink::open_live(self : LogSink) -> Unit {
  self.file = @fs.open(
    self.path,
    mode=@fs.WriteOnly,
    append=true,
    create_mode=@fs.OpenOrCreate,
  )
  self.needs_open = false
}

///|
/// The pump dropped a chunk because the log file would not take it — a full
/// disk, most likely. The failure is reported on the daemon log, throttled:
/// it repeats for every chunk until the file accepts data again.
pub async fn LogSink::note_write_failure(
  self : LogSink,
  bytes : Int,
  reason : String,
) -> Unit {
  self.dropped_bytes = self.dropped_bytes + bytes.to_int64()
  self.note_error("write", reason)
}

///|
/// A rotation or retention pass on this sink failed.
pub async fn LogSink::note_rotation_failure(
  self : LogSink,
  reason : String,
) -> Unit {
  self.note_error("rotation", reason)
}

///|
/// Report a sink problem on the daemon log, at most once every five seconds
/// so a persistent failure cannot flood the daemon's own log.
async fn LogSink::note_error(
  self : LogSink,
  what : String,
  reason : String,
) -> Unit {
  let now = @async.now()
  if now - self.last_error_ms < 5000L {
    return
  }
  self.last_error_ms = now
  let dropped = if self.dropped_bytes > 0L {
    "; \{self.dropped_bytes} bytes dropped so far"
  } else {
    ""
  }
  daemon_log("log \{what} failed for \{self.path}: \{reason}\{dropped}")
}

///|
/// Append `data`, rotating first if the policy demands it.
pub async fn LogSink::write(self : LogSink, data : Bytes) -> Unit {
  self.lock.acquire()
  defer self.lock.release()
  if self.closed {
    return
  }
  if self.needs_open {
    self.open_live()
  }
  if self.rotate_requested {
    self.do_rotate()
  }
  self.file.write(data)
  self.size = self.size + data.length().to_int64()
  if self.dropped_bytes > 0L {
    daemon_log(
      "log writes to \{self.path} work again (\{self.dropped_bytes} bytes were dropped while the file would not take them)",
    )
    self.dropped_bytes = 0L
  }
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
  if self.needs_open {
    self.open_live()
  }
  if self.redirect_stderr {
    // The daemon's own log grows through the inherited stderr, not through
    // this sink, so the tracked size would stay stale; the file is the
    // source of truth.
    self.size = @fs.file_size(self.path) catch {
      _ => self.size
    }
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
  if !self.needs_open {
    self.file.close()
  }
  self.file = @fs.open(
    self.path,
    mode=@fs.WriteOnly,
    append=true,
    create_mode=@fs.CreateOrTruncate,
  )
  self.needs_open = false
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
  self.rotations_since_prune = 0
  let dir = @pm3.path_dirname(self.path)
  let names = @fs.readdir(dir) catch { _ => return }
  let files : Array[@pm3.RotatedFile] = []
  for name in names {
    match @pm3.parse_rotated_stamp(self.path, name) {
      Some(_) => {
        let full = @pm3.path_join(dir, name)
        let mtime = @fs.mtime(full) catch { _ => continue }
        files.push({
          name: full,
          mtime: mtime.0 * 1_000_000_000L + mtime.1.to_int64(),
        })
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
  // Renaming is metadata-only, so a rotation still works on a full disk; it
  // is the fresh live file that a full disk may refuse to create. Leave the
  // sink recoverable either way: `needs_open` makes the next write (or the
  // runner) retry, and a failed rename just keeps appending to the file that
  // is still in place.
  let renamed = try {
    @fs.rename(self.path, target, replace=true)
    true
  } catch {
    _ => false
  }
  self.needs_open = true
  if !renamed {
    self.open_live()
    return
  }
  // The data moved to the rotated name; start the size policy over.
  self.size = 0L
  self.open_live()
  if self.redirect_stderr {
    pm3_reopen_stderr(@utf8.encode(self.path))
  }
  if self.config.compress {
    self.compress_queue.put(target)
  }
  // A busy log can rotate many times between two runner passes. Prune after a
  // few rotations (and at most once a second) so retention stays close to the
  // configured count instead of overshooting by a whole worker interval — a
  // write storm would otherwise pile files up at the write rate rather than
  // at the retention count.
  self.rotations_since_prune = self.rotations_since_prune + 1
  let now_ms = @async.now()
  if self.rotations_since_prune >= 4 || now_ms - self.last_prune_ms >= 1000L {
    self.last_prune_ms = now_ms
    self.prune(now_ms * 1_000_000L)
  }
}
