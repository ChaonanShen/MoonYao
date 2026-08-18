///|
/// Reads one UTF-8 DSL source file.
///
/// The application loader added later in P1 will turn `@fs.IOError` into a
/// structured engine error at its public boundary.
pub fn read_dsl_source(path : String) -> String raise @fs.IOError {
  @fs.read_file_to_string(path)
}
