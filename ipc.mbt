///|
/// The tiny line-delimited JSON protocol spoken between the CLI and the
/// daemon over a loopback TCP socket.
///
/// Using TCP (rather than a Unix socket) keeps the transport portable and
/// available in `moonbitlang/async` without extra FFI. The socket is bound to
/// `127.0.0.1` only and the daemon publishes its ephemeral port in
/// `~/.pm3/daemon.port`.

///|
/// Command names understood by the daemon.
pub let cmd_ping : String = "ping"

///|
pub let cmd_list : String = "list"

///|
pub let cmd_start : String = "start"

///|
/// Start every app declared in a config file. `args[0]` is a JSON array of
/// `App` records, already resolved by the client.
pub let cmd_start_apps : String = "start_apps"

///|
pub let cmd_stop : String = "stop"

///|
pub let cmd_restart : String = "restart"

///|
pub let cmd_delete : String = "delete"

///|
pub let cmd_describe : String = "describe"

///|
pub let cmd_flush : String = "flush"

///|
pub let cmd_reload_logs : String = "reloadLogs"

///|
pub let cmd_save : String = "save"

///|
pub let cmd_resurrect : String = "resurrect"

///|
pub let cmd_kill : String = "kill"

///|
pub let cmd_get_logrotate : String = "get_logrotate"

///|
pub let cmd_get_config = "get_config"

///|
pub let cmd_set_logrotate : String = "set_logrotate"

///|
pub let cmd_reset : String = "reset"

///|
/// A request from the CLI. Kept deliberately generic so new commands do not
/// require protocol version bumps.
pub(all) struct Request {
  cmd : String
  args : Array[String]
  opts : Map[String, String]
  flags : Map[String, Bool]
} derive(Eq, Debug, ToJson, FromJson)

///|
/// A reply from the daemon. `data` carries an optional JSON payload.
pub(all) struct Response {
  ok : Bool
  msg : String
  data : Json
} derive(Debug, ToJson, FromJson)

///|
/// A request with a command name and no arguments.
pub fn Request::new(cmd : String) -> Request {
  { cmd, args: [], opts: Map([]), flags: Map([]), }
}

///|
/// A request with positional arguments.
pub fn Request::with_args(cmd : String, args : Array[String]) -> Request {
  { cmd, args, opts: Map([]), flags: Map([]), }
}

///|
/// A successful response with no payload.
pub fn Response::success(msg : String) -> Response {
  { ok: true, msg, data: Json::null(), }
}

///|
/// A successful response carrying a JSON payload.
pub fn Response::success_data(msg : String, data : Json) -> Response {
  { ok: true, msg, data, }
}

///|
/// A failed response.
pub fn Response::failure(msg : String) -> Response {
  { ok: false, msg, data: Json::null(), }
}

///|
/// Encode a request as a single newline-terminated line.
pub fn encode_request(request : Request) -> String {
  @json.to_json(request).stringify() + "\n"
}

///|
/// Encode a response as a single newline-terminated line.
pub fn encode_response(response : Response) -> String {
  @json.to_json(response).stringify() + "\n"
}

///|
/// Decode one request line.
pub fn decode_request(line : String) -> Request? {
  Some(@json.from_json(@json.parse(line))) catch {
    _ => None
  }
}

///|
/// Decode one response line.
pub fn decode_response(line : String) -> Response? {
  Some(@json.from_json(@json.parse(line))) catch {
    _ => None
  }
}
