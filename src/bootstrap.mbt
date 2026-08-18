///|
/// Returns the stable message emitted by the initial native executable.
///
/// This is intentionally small: it establishes a public, testable boundary
/// before application loading, SQLite, Process dispatch, and HTTP are added.
pub fn bootstrap_message() -> String {
  "MoonYao Core bootstrap: Native runtime is ready."
}
