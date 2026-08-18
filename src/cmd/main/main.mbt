///|
/// Entry point for the MoonYao Core executable.
///
/// Keep this package limited to wiring. CLI argument parsing and runtime
/// behavior will be added in dedicated issues after the core contracts exist.
fn main {
  println(@moonyao.bootstrap_message())
}
