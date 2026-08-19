///|
fn exec(
  connection : @sqlite3.Connection,
  sql : String,
) -> Result[Unit, @errors.EngineError] {
  let statement = connection.prepare(sql) catch {
    _ =>
      return Err(
        @errors.database_error(
          "could not prepare attachment operation", "attachment",
        ),
      )
  }
  try {
    statement.step_once()
    statement.finalize()
    Ok(())
  } catch {
    _ => {
      statement.finalize() catch {
        _ => ()
      }
      Err(@errors.database_error("attachment operation failed", "attachment"))
    }
  }
}

///|
pub fn migrate(
  connection : @sqlite3.Connection,
) -> Result[Unit, @errors.EngineError] {
  exec(
    connection, "CREATE TABLE IF NOT EXISTS _moonyao_attachments (id TEXT PRIMARY KEY, storage_key TEXT NOT NULL UNIQUE, filename TEXT NOT NULL, media_type TEXT NOT NULL, byte_size INTEGER NOT NULL CHECK(byte_size >= 0), sha256 TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('image','text')), status TEXT NOT NULL CHECK(status IN ('ready','deleted')), created_at INTEGER NOT NULL, deleted_at INTEGER NOT NULL)",
  )
}

///|
fn kind_string(kind : Kind) -> String {
  match kind {
    Image => "image"
    Text => "text"
  }
}

///|
pub fn insert(
  connection : @sqlite3.Connection,
  attachment : Attachment,
) -> Result[Unit, @errors.EngineError] {
  if !valid_id(attachment.id) || attachment.status != "ready" {
    return Err(
      @errors.invalid_argument("invalid attachment metadata", "attachment"),
    )
  }
  let statement = connection.prepare(
    "INSERT INTO _moonyao_attachments(id, storage_key, filename, media_type, byte_size, sha256, kind, status, created_at, deleted_at) VALUES (?, ?, ?, ?, ?, ?, ?, 'ready', ?, 0)",
  ) catch {
    _ =>
      return Err(
        @errors.database_error(
          "could not prepare attachment insert", "attachment",
        ),
      )
  }
  try {
    statement.bind(index=1, attachment.id)
    statement.bind(index=2, attachment.storage_key)
    statement.bind(index=3, safe_filename(attachment.filename))
    statement.bind(index=4, attachment.media_type)
    statement.bind(index=5, attachment.byte_size)
    statement.bind(index=6, attachment.sha256)
    statement.bind(index=7, kind_string(attachment.kind))
    statement.bind(index=8, attachment.created_at)
    statement.step_once()
    statement.finalize()
    Ok(())
  } catch {
    _ => {
      statement.finalize() catch {
        _ => ()
      }
      Err(@errors.database_error("could not save attachment", "attachment"))
    }
  }
}

///|
pub fn get(
  connection : @sqlite3.Connection,
  id : String,
) -> Result[Attachment, @errors.EngineError] {
  if !valid_id(id) {
    return Err(
      @errors.invalid_argument("invalid attachment id", "attachment.id"),
    )
  }
  let statement = connection.prepare(
    "SELECT id, storage_key, filename, media_type, byte_size, sha256, kind, status, created_at, deleted_at FROM _moonyao_attachments WHERE id = ? AND status = 'ready'",
  ) catch {
    _ =>
      return Err(
        @errors.database_error(
          "could not prepare attachment read", "attachment",
        ),
      )
  }
  try {
    statement.bind(index=1, id)
    if !statement.step() {
      statement.finalize()
      return Err(
        @errors.invalid_argument("attachment was not found", "attachment.id"),
      )
    }
    let kind = if (statement.column(index=6) : String) == "image" {
      Image
    } else {
      Text
    }
    let value : Attachment = {
      id: statement.column(index=0),
      storage_key: statement.column(index=1),
      filename: statement.column(index=2),
      media_type: statement.column(index=3),
      byte_size: statement.column(index=4),
      sha256: statement.column(index=5),
      kind,
      status: statement.column(index=7),
      created_at: statement.column(index=8),
      deleted_at: statement.column(index=9),
    }
    statement.finalize()
    Ok(value)
  } catch {
    _ => {
      statement.finalize() catch {
        _ => ()
      }
      Err(@errors.database_error("could not read attachment", "attachment"))
    }
  }
}
