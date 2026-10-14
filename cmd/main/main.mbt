///|
/// pm3 executable entry point. All real work lives in `kupas/pm3/client`.

///|
async fn main {
  // The client reports user-facing errors itself; anything that escapes is
  // either an already-reported failure or a closed output pipe (for example
  // `pm3 logs | head`), neither of which deserves a stack-trace-like dump.
  @client.main_cli() catch {
    _ => ()
  }
}
