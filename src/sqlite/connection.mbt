///|
/// Opens a SQLite connection. Higher layers own the returned connection and
/// must close it after finalizing every statement created from it.
pub fn open(path : String) -> @sqlite3.Connection raise @sqlite3.SqliteError {
  @sqlite3.Connection::open(path)
}

///|
pub fn open_result(
  path : String,
) -> Result[@sqlite3.Connection, @errors.EngineError] {
  Ok(@sqlite3.Connection::open(path)) catch {
    (_ : @sqlite3.SqliteError) =>
      Err(@errors.database_error("could not open database", path))
  }
}

///|
pub fn close_result(
  connection : @sqlite3.Connection,
) -> Result[Unit, @errors.EngineError] {
  try {
    connection.close()
    Ok(())
  } catch {
    (_ : @sqlite3.SqliteError) =>
      Err(@errors.database_error("could not close database", "database"))
  }
}
