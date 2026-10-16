///|
/// Decoding helpers for the `App` records the CLI and the daemon exchange.
///
/// The daemon answering a request may have been built from a different pm3
/// than the client: it writes the fields its own build knew about, so a
/// record written before a field existed simply lacks it. Failing on that
/// would turn one missing key into "the daemon manages nothing", so missing
/// fields are backfilled from a default record before decoding. Fields this
/// build does not know are ignored by the decoder, which keeps the other
/// direction — a new daemon answering an older client — working too.

///|
/// Fill in the fields a record written by another pm3 build did not have.
pub fn with_app_defaults(json : Json) -> Json {
  match json {
    Json::Object(members) =>
      match @json.to_json(App::new("", "", [])) {
        Json::Object(defaults) =>
          for key, value in defaults {
            if !members.contains(key) {
              members.set(key, value)
            }
          }
        _ => ()
      }
    _ => ()
  }
  json
}

///|
/// Decode a JSON list of `App` records as one daemon reported them. `None`
/// means the payload is not a list of apps this build can read, so a caller
/// can report a real error instead of showing an empty process list.
pub fn app_records_from_json(json : Json) -> Array[App]? {
  match json {
    Json::Array(items) => {
      let apps : Array[App] = []
      for item in items {
        let app : App = @json.from_json(with_app_defaults(item)) catch {
          _ => return None
        }
        apps.push(app)
      }
      Some(apps)
    }
    _ => None
  }
}
