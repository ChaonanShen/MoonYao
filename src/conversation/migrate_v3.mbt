///|
fn migration_present(
  connection : @sqlite3.Connection,
  version : Int,
) -> Result[Bool, @errors.EngineError] {
  let statement = connection.prepare(
    "SELECT COUNT(*) FROM _moonyao_migrations WHERE version = ?",
  ) catch {
    _ =>
      return Err(
        @errors.database_error(
          "could not inspect conversation migration", "conversation.migrate",
        ),
      )
  }
  try {
    statement.bind(index=1, version)
    ignore(statement.step())
    let count : Int = statement.column(index=0)
    statement.finalize()
    Ok(count > 0)
  } catch {
    _ => {
      statement.finalize() catch {
        _ => ()
      }
      Err(
        @errors.database_error(
          "could not inspect conversation migration", "conversation.migrate",
        ),
      )
    }
  }
}

///|
fn canonical_for_legacy(
  role : String,
  kind : String,
  source : String,
) -> Result[Json, @errors.EngineError] {
  if kind == "text" {
    let parsed = @json.parse(source) catch {
      _ =>
        return Err(
          @errors.database_error(
            "legacy text message is invalid", "conversation.migrate.v3",
          ),
        )
    }
    guard parsed is String(text) else {
      return Err(
        @errors.database_error(
          "legacy text message is invalid", "conversation.migrate.v3",
        ),
      )
    }
    return match @content.from_legacy(role, text) {
      Ok(message) => Ok(@content.encode(message))
      Err(_) =>
        Err(
          @errors.database_error(
            "legacy message role is invalid", "conversation.migrate.v3",
          ),
        )
    }
  }
  if kind == "tool_calls" {
    let parsed = @json.parse(source) catch {
      _ =>
        return Err(
          @errors.database_error(
            "legacy tool call message is invalid", "conversation.migrate.v3",
          ),
        )
    }
    return match @content.decode(parsed, "message") {
      Ok(message) => Ok(@content.encode(message))
      Err(_) =>
        Err(
          @errors.database_error(
            "legacy tool call message is invalid", "conversation.migrate.v3",
          ),
        )
    }
  }
  if kind == "tool_result" {
    let parsed = @json.parse(source) catch {
      _ =>
        return Err(
          @errors.database_error(
            "legacy tool result is invalid", "conversation.migrate.v3",
          ),
        )
    }
    guard parsed is Object(object) else {
      return Err(
        @errors.database_error(
          "legacy tool result is invalid", "conversation.migrate.v3",
        ),
      )
    }
    let call_id = match object.get("tool_call_id") {
      Some(String(value)) if value.length() > 0 => value
      _ =>
        return Err(
          @errors.database_error(
            "legacy tool result is invalid", "conversation.migrate.v3",
          ),
        )
    }
    let name = match object.get("name") {
      Some(String(value)) => Some(value)
      _ => None
    }
    let message : @content.Message = {
      role: @content.Tool,
      content: Some(@content.Text(source)),
      name,
      tool_call_id: Some(call_id),
      reasoning_content: None,
      tool_calls: [],
      refusal: None,
    }
    return Ok(@content.encode(message))
  }
  if kind == "internal" {
    let message : @content.Message = {
      role: @content.Assistant,
      content: Some(@content.Text(source)),
      name: None,
      tool_call_id: None,
      reasoning_content: None,
      tool_calls: [],
      refusal: None,
    }
    return Ok(@content.encode(message))
  }
  Err(
    @errors.database_error(
      "unsupported legacy message kind", "conversation.migrate.v3",
    ),
  )
}

///|
fn backfill_canonical(
  connection : @sqlite3.Connection,
) -> Result[Unit, @errors.EngineError] {
  let select = connection.prepare(
    "SELECT id, role, kind, content_json FROM _moonyao_messages ORDER BY chat_id, sequence",
  ) catch {
    _ =>
      return Err(
        @errors.database_error(
          "could not prepare canonical backfill", "conversation.migrate.v3",
        ),
      )
  }
  let rows : Array[(String, String)] = []
  try {
    while select.step() {
      let id : String = select.column(index=0)
      let role : String = select.column(index=1)
      let kind : String = select.column(index=2)
      let source : String = select.column(index=3)
      let canonical = match canonical_for_legacy(role, kind, source) {
        Ok(value) => value.stringify()
        Err(error) => {
          select.finalize()
          return Err(error)
        }
      }
      rows.push((id, canonical))
    }
    select.finalize()
  } catch {
    _ => {
      select.finalize() catch {
        _ => ()
      }
      return Err(
        @errors.database_error(
          "could not read canonical backfill", "conversation.migrate.v3",
        ),
      )
    }
  }
  for row in rows {
    let (id, canonical) = row
    let update = connection.prepare(
      "UPDATE _moonyao_messages SET canonical_json = ? WHERE id = ?",
    ) catch {
      _ =>
        return Err(
          @errors.database_error(
            "could not prepare canonical update", "conversation.migrate.v3",
          ),
        )
    }
    try {
      update.bind(index=1, canonical)
      update.bind(index=2, id)
      update.step_once()
      update.finalize()
    } catch {
      _ => {
        update.finalize() catch {
          _ => ()
        }
        return Err(
          @errors.database_error(
            "could not update canonical messages", "conversation.migrate.v3",
          ),
        )
      }
    }
  }
  Ok(())
}

///|
pub fn migrate_v3(
  connection : @sqlite3.Connection,
) -> Result[Unit, @errors.EngineError] {
  match migration_present(connection, 3) {
    Ok(true) => return Ok(())
    Ok(false) => ()
    Err(error) => return Err(error)
  }
  match exec(connection, "BEGIN IMMEDIATE", "conversation.migrate.v3") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let statements = [
    "ALTER TABLE _moonyao_messages ADD COLUMN canonical_json TEXT NOT NULL DEFAULT ''",
  ]
  match @attachment.migrate(connection) {
    Err(error) => {
      rollback(connection)
      return Err(error)
    }
    Ok(_) => ()
  }
  for statement in statements {
    match exec(connection, statement, "conversation.migrate.v3") {
      Err(error) => {
        rollback(connection)
        return Err(error)
      }
      Ok(_) => ()
    }
  }
  match backfill_canonical(connection) {
    Err(error) => {
      rollback(connection)
      return Err(error)
    }
    Ok(_) => ()
  }
  let rebuild = [
    "CREATE TABLE _moonyao_messages_v3 (id TEXT PRIMARY KEY, chat_id TEXT NOT NULL REFERENCES _moonyao_chats(id) ON DELETE CASCADE, turn_id TEXT NOT NULL REFERENCES _moonyao_turns(id) ON DELETE CASCADE, sequence INTEGER NOT NULL, role TEXT NOT NULL CHECK(role IN ('developer','system','user','assistant','tool')), kind TEXT NOT NULL CHECK(kind IN ('text','multipart','tool_calls','tool_result','internal','partial')), content_json TEXT NOT NULL, status TEXT NOT NULL CHECK(status IN ('completed','failed','partial')), created_at INTEGER NOT NULL, canonical_json TEXT NOT NULL, UNIQUE(chat_id, sequence))",
    "INSERT INTO _moonyao_messages_v3(id, chat_id, turn_id, sequence, role, kind, content_json, status, created_at, canonical_json) SELECT id, chat_id, turn_id, sequence, role, kind, content_json, status, created_at, canonical_json FROM _moonyao_messages",
    "DROP TABLE _moonyao_messages", "ALTER TABLE _moonyao_messages_v3 RENAME TO _moonyao_messages",
    "CREATE INDEX _moonyao_messages_chat ON _moonyao_messages(chat_id, sequence)",
    "CREATE TABLE _moonyao_message_attachments (message_id TEXT NOT NULL REFERENCES _moonyao_messages(id) ON DELETE CASCADE, attachment_id TEXT NOT NULL REFERENCES _moonyao_attachments(id), position INTEGER NOT NULL CHECK(position >= 0), PRIMARY KEY(message_id, position), UNIQUE(message_id, attachment_id, position))",
    "CREATE INDEX _moonyao_message_attachments_attachment ON _moonyao_message_attachments(attachment_id)",
  ]
  for statement in rebuild {
    match exec(connection, statement, "conversation.migrate.v3") {
      Err(error) => {
        rollback(connection)
        return Err(error)
      }
      Ok(_) => ()
    }
  }
  match
    exec(
      connection, "INSERT INTO _moonyao_migrations(version) VALUES (3)", "conversation.migrate.v3",
    ) {
    Err(error) => {
      rollback(connection)
      return Err(error)
    }
    Ok(_) => ()
  }
  match exec(connection, "COMMIT", "conversation.migrate.v3") {
    Ok(_) => Ok(())
    Err(error) => {
      rollback(connection)
      Err(error)
    }
  }
}
