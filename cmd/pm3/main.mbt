///|
/// pm3 executable entry point. All real work lives in `kupas/pm3/client`.

///|
async fn main {
  // The client reports user-facing errors itself, so what escapes here is
  // either a closed output pipe (`pm3 logs | head`) or a bug. Swallowing both —
  // which this used to do — makes a crashing command look like a command that
  // did nothing and succeeded, the worst answer a process manager can give.
  @client.main_cli() catch {
    error => {
      let message = error.to_string()
      // A closed pipe is the user's terminal closing, not a fault.
      if message.contains("Broken pipe") || message.contains("EPIPE") {
        return
      }
      @stdio.stderr.write("pm3: unexpected failure: \{message}\n")
      @client.pm3_exit(2)
    }
  }
}
