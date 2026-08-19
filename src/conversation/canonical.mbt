///|
pub(all) struct CanonicalMessage {
  id : String
  chat_id : String
  turn_id : String
  sequence : Int
  message : @content.Message
  status : String
  created_at : Int64
} derive(Eq, Debug)

///|
fn attachment_ids(message : @content.Message) -> Array[String] {
  let ids : Array[String] = []
  match message.content {
    Some(@content.Parts(parts)) =>
      for part in parts {
        match part {
          @content.ImageRef(id, _) | @content.FileRef(id, _) => ids.push(id)
          _ => ()
        }
      }
    _ => ()
  }
  ids
}

///|
/// Replace the compatibility user row created by begin_turn with canonical input.
pub fn replace_canonical_message(
  connection : @sqlite3.Connection,
  id : String,
  message : @content.Message,
) -> Result[Unit, @errors.EngineError] {
  if message.role != @content.User {
    return Err(
      @errors.invalid_argument("current message must be user", "message"),
    )
  }
  let payload = @content.encode(message).stringify()
  if payload.length() > 262144 {
    return Err(
      @errors.invalid_argument("canonical message is too large", "message"),
    )
  }
  let ids = attachment_ids(message)
  if ids.length() > 8 {
    return Err(
      @errors.invalid_argument(
        "too many message attachments", "message.content",
      ),
    )
  }
  for attachment_id in ids {
    match @attachment.get(connection, attachment_id) {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
  }
  match exec(connection, "BEGIN IMMEDIATE", "message.replace") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let update = connection.prepare(
    "UPDATE _moonyao_messages SET kind = 'multipart', content_json = ?, canonical_json = ? WHERE id = ? AND role = 'user'",
  ) catch {
    _ => {
      rollback(connection)
      return Err(
        @errors.database_error(
          "could not prepare canonical replacement", "message",
        ),
      )
    }
  }
  try {
    update.bind(index=1, payload)
    update.bind(index=2, payload)
    update.bind(index=3, id)
    update.step_once()
    update.finalize()
  } catch {
    _ => {
      update.finalize() catch {
        _ => ()
      }
      rollback(connection)
      return Err(
        @errors.database_error("could not replace canonical message", "message"),
      )
    }
  }
  for index = 0; index < ids.length(); index = index + 1 {
    let reference = connection.prepare(
      "INSERT INTO _moonyao_message_attachments(message_id, attachment_id, position) VALUES (?, ?, ?)",
    ) catch {
      _ => {
        rollback(connection)
        return Err(
          @errors.database_error(
            "could not prepare attachment references", "message",
          ),
        )
      }
    }
    try {
      reference.bind(index=1, id)
      reference.bind(index=2, ids[index])
      reference.bind(index=3, index)
      reference.step_once()
      reference.finalize()
    } catch {
      _ => {
        reference.finalize() catch {
          _ => ()
        }
        rollback(connection)
        return Err(
          @errors.database_error(
            "could not save attachment references", "message",
          ),
        )
      }
    }
  }
  match exec(connection, "COMMIT", "message.replace") {
    Ok(_) => Ok(())
    Err(error) => {
      rollback(connection)
      Err(error)
    }
  }
}

///|
pub fn append_canonical(
  connection : @sqlite3.Connection,
  id : String,
  chat_id : String,
  turn_id : String,
  kind : String,
  message : @content.Message,
  now : Int64,
) -> Result[Unit, @errors.EngineError] {
  let payload = @content.encode(message).stringify()
  if payload.length() > 262144 {
    return Err(
      @errors.invalid_argument("canonical message is too large", "message"),
    )
  }
  let role = match message.role {
    @content.Developer => "developer"
    @content.System => "system"
    @content.User => "user"
    @content.Assistant => "assistant"
    @content.Tool => "tool"
  }
  let ids = attachment_ids(message)
  if ids.length() > 8 {
    return Err(
      @errors.invalid_argument(
        "too many message attachments", "message.content",
      ),
    )
  }
  for attachment_id in ids {
    match @attachment.get(connection, attachment_id) {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
  }
  match exec(connection, "BEGIN IMMEDIATE", "message.append") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let sequence_statement = connection.prepare(
    "SELECT COALESCE(MAX(sequence), 0) + 1 FROM _moonyao_messages WHERE chat_id = ?",
  ) catch {
    _ => {
      rollback(connection)
      return Err(
        @errors.database_error("could not prepare message sequence", "message"),
      )
    }
  }
  let sequence = try {
    sequence_statement.bind(index=1, chat_id)
    ignore(sequence_statement.step())
    let value : Int = sequence_statement.column(index=0)
    sequence_statement.finalize()
    value
  } catch {
    _ => {
      sequence_statement.finalize() catch {
        _ => ()
      }
      rollback(connection)
      return Err(
        @errors.database_error("could not allocate message sequence", "message"),
      )
    }
  }
  let statement = connection.prepare(
    "INSERT INTO _moonyao_messages(id, chat_id, turn_id, sequence, role, kind, content_json, status, created_at, canonical_json) VALUES (?, ?, ?, ?, ?, ?, ?, 'completed', ?, ?)",
  ) catch {
    _ => {
      rollback(connection)
      return Err(
        @errors.database_error("could not prepare canonical message", "message"),
      )
    }
  }
  try {
    statement.bind(index=1, id)
    statement.bind(index=2, chat_id)
    statement.bind(index=3, turn_id)
    statement.bind(index=4, sequence)
    statement.bind(index=5, role)
    statement.bind(index=6, kind)
    statement.bind(index=7, payload)
    statement.bind(index=8, now)
    statement.bind(index=9, payload)
    statement.step_once()
    statement.finalize()
  } catch {
    _ => {
      statement.finalize() catch {
        _ => ()
      }
      rollback(connection)
      return Err(
        @errors.database_error("could not save canonical message", "message"),
      )
    }
  }
  for index = 0; index < ids.length(); index = index + 1 {
    let reference = connection.prepare(
      "INSERT INTO _moonyao_message_attachments(message_id, attachment_id, position) VALUES (?, ?, ?)",
    ) catch {
      _ => {
        rollback(connection)
        return Err(
          @errors.database_error(
            "could not prepare attachment references", "message",
          ),
        )
      }
    }
    try {
      reference.bind(index=1, id)
      reference.bind(index=2, ids[index])
      reference.bind(index=3, index)
      reference.step_once()
      reference.finalize()
    } catch {
      _ => {
        reference.finalize() catch {
          _ => ()
        }
        rollback(connection)
        return Err(
          @errors.database_error(
            "could not save attachment references", "message",
          ),
        )
      }
    }
  }
  match exec(connection, "COMMIT", "message.append") {
    Ok(_) => Ok(())
    Err(error) => {
      rollback(connection)
      Err(error)
    }
  }
}

///|
pub fn list_canonical(
  connection : @sqlite3.Connection,
  chat_id : String,
) -> Result[Array[CanonicalMessage], @errors.EngineError] {
  let statement = connection.prepare(
    "SELECT id, chat_id, turn_id, sequence, canonical_json, status, created_at FROM _moonyao_messages WHERE chat_id = ? AND canonical_json != '' ORDER BY sequence",
  ) catch {
    _ =>
      return Err(
        @errors.database_error("could not prepare canonical history", "message"),
      )
  }
  let output : Array[CanonicalMessage] = []
  try {
    statement.bind(index=1, chat_id)
    while statement.step() {
      let source : String = statement.column(index=4)
      let parsed = @json.parse(source) catch {
        _ => {
          statement.finalize()
          return Err(
            @errors.database_error("canonical message is invalid", "message"),
          )
        }
      }
      let message = match @content.decode(parsed, "message") {
        Ok(value) => value
        Err(_) => {
          statement.finalize()
          return Err(
            @errors.database_error("canonical message is invalid", "message"),
          )
        }
      }
      output.push({
        id: statement.column(index=0),
        chat_id: statement.column(index=1),
        turn_id: statement.column(index=2),
        sequence: statement.column(index=3),
        message,
        status: statement.column(index=5),
        created_at: statement.column(index=6),
      })
    }
    statement.finalize()
    Ok(output)
  } catch {
    _ => {
      statement.finalize() catch {
        _ => ()
      }
      Err(@errors.database_error("could not read canonical history", "message"))
    }
  }
}

///|
pub fn user_message_for_turn(
  connection : @sqlite3.Connection,
  turn_id : String,
) -> Result[CanonicalMessage, @errors.EngineError] {
  let statement = connection.prepare(
    "SELECT id, chat_id, turn_id, sequence, canonical_json, status, created_at FROM _moonyao_messages WHERE turn_id = ? AND role = 'user' AND canonical_json != '' ORDER BY sequence LIMIT 1",
  ) catch {
    _ =>
      return Err(
        @errors.database_error("could not prepare turn input query", "message"),
      )
  }
  try {
    statement.bind(index=1, turn_id)
    if !statement.step() {
      statement.finalize()
      return Err(@errors.record_not_found("turn.message"))
    }
    let source : String = statement.column(index=4)
    let parsed = @json.parse(source) catch {
      _ => {
        statement.finalize()
        return Err(
          @errors.database_error("canonical message is invalid", "message"),
        )
      }
    }
    let message = match @content.decode(parsed, "message") {
      Ok(value) => value
      Err(_) => {
        statement.finalize()
        return Err(
          @errors.database_error("canonical message is invalid", "message"),
        )
      }
    }
    let result : CanonicalMessage = {
      id: statement.column(index=0),
      chat_id: statement.column(index=1),
      turn_id: statement.column(index=2),
      sequence: statement.column(index=3),
      message,
      status: statement.column(index=5),
      created_at: statement.column(index=6),
    }
    statement.finalize()
    Ok(result)
  } catch {
    _ => {
      statement.finalize() catch {
        _ => ()
      }
      Err(@errors.database_error("could not read turn input", "message"))
    }
  }
}
