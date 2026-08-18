///|
/// Opens a SQLite connection. Higher layers own the returned connection and
/// must close it after finalizing every statement created from it.
pub fn open(path : String) -> @sqlite3.Connection raise @sqlite3.SqliteError {
  @sqlite3.Connection::open(path)
}
