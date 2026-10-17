///|
/// The version of this pm3 build.
///
/// This is the single source for `pm3 --version` and for the `version`
/// request the daemon answers with: the CLI compares the two to notice it is
/// talking to a daemon left over from another build. Keep it in step with
/// `moon.mod` and `npmjs/package.json` when a release is cut.
pub let pm3_version : String = "0.1.7"
