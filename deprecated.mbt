///|
/// Explicit trait re-exports.
///
/// Recent MoonBit toolchains deprecate the implicit promotion of derived
/// trait methods (`equal`, `not_equal`, `to_repr`, …) to regular methods.
/// These declarations keep the derived implementations available under the
/// new rules without changing behaviour.

///|
pub extend CronSpec with Eq::{not_equal, equal}

///|
pub extend CronSpec with @debug.Debug::{to_repr}

///|
pub extend LogrotateConfig with Eq::{not_equal, equal}

///|
pub extend LogrotateConfig with @debug.Debug::{to_repr}

///|
pub extend RotatedFile with Eq::{not_equal, equal}

///|
pub extend RotatedFile with @debug.Debug::{to_repr}

///|
pub extend App with Eq::{not_equal, equal}

///|
pub extend App with @debug.Debug::{to_repr}

///|
pub extend Request with Eq::{not_equal, equal}

///|
pub extend Request with @debug.Debug::{to_repr}

///|
pub extend Response with @debug.Debug::{to_repr}

///|
pub extend LogrotateConfig with ToJson::{to_json}

///|
pub extend LogrotateConfig with @json.FromJson::{from_json}

///|
pub extend App with ToJson::{to_json}

///|
pub extend App with @json.FromJson::{from_json}

///|
pub extend Request with ToJson::{to_json}

///|
pub extend Request with @json.FromJson::{from_json}

///|
pub extend Response with ToJson::{to_json}

///|
pub extend Response with @json.FromJson::{from_json}
