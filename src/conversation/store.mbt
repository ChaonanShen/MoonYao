///|
pub(all) struct Chat {
  id : String
  agent_id : String
  title : String
  status : String
  created_at : Int64
  updated_at : Int64
} derive(Eq, Debug)

///|
pub(all) struct Message {
  id : String
  chat_id : String
  turn_id : String
  sequence : Int
  role : String
  kind : String
  content : String
  status : String
  created_at : Int64
} derive(Eq, Debug)

///|
pub(all) struct Turn {
  id : String
  chat_id : String
  status : String
  error_code : String
  error_message : String
  prompt_tokens : Int
  completion_tokens : Int
  started_at : Int64
  finished_at : Int64
} derive(Eq, Debug)

///|
pub(all) struct PublicMessage {
  message : Message
  turn_status : String
} derive(Eq, Debug)

///|
fn exec(
  connection : @sqlite3.Connection,
  sql : String,
  path : String,
) -> Result[Unit, @errors.EngineError] {
  let statement = connection.prepare(sql) catch {
    (_ : @sqlite3.SqliteError) =>
      return Err(
        @errors.database_error("could not prepare conversation operation", path),
      )
  }
  try {
    statement.step_once()
    statement.finalize()
    Ok(())
  } catch {
    (_ : @sqlite3.SqliteError) => {
      statement.finalize() catch {
        _ => ()
      }
      Err(@errors.database_error("conversation operation failed", path))
    }
  }
}

///|
fn rollback(connection : @sqlite3.Connection) -> Unit {
  ignore(exec(connection, "ROLLBACK", "conversation"))
}

///|
pub fn migrate(
  connection : @sqlite3.Connection,
) -> Result[Unit, @errors.EngineError] {
  let statements = [
    "PRAGMA foreign_keys = ON", "CREATE TABLE IF NOT EXISTS _moonyao_migrations (version INTEGER PRIMARY KEY)",
    "CREATE TABLE IF NOT EXISTS _moonyao_chats (id TEXT PRIMARY KEY, agent_id TEXT NOT NULL, title TEXT NOT NULL, status TEXT NOT NULL CHECK(status IN ('active','deleted')), created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)",
    "CREATE TABLE IF NOT EXISTS _moonyao_turns (id TEXT PRIMARY KEY, chat_id TEXT NOT NULL REFERENCES _moonyao_chats(id) ON DELETE CASCADE, status TEXT NOT NULL CHECK(status IN ('active','completed','failed','interrupted')), error_code TEXT NOT NULL, error_message TEXT NOT NULL, prompt_tokens INTEGER NOT NULL, completion_tokens INTEGER NOT NULL, started_at INTEGER NOT NULL, finished_at INTEGER NOT NULL)",
    "CREATE TABLE IF NOT EXISTS _moonyao_messages (id TEXT PRIMARY KEY, chat_id TEXT NOT NULL REFERENCES _moonyao_chats(id) ON DELETE CASCADE, turn_id TEXT NOT NULL REFERENCES _moonyao_turns(id) ON DELETE CASCADE, sequence INTEGER NOT NULL, role TEXT NOT NULL CHECK(role IN ('user','assistant')), kind TEXT NOT NULL CHECK(kind = 'text'), content_json TEXT NOT NULL, status TEXT NOT NULL CHECK(status IN ('completed','failed')), created_at INTEGER NOT NULL, UNIQUE(chat_id, sequence))",
    "CREATE INDEX IF NOT EXISTS _moonyao_turns_chat ON _moonyao_turns(chat_id)",
    "CREATE INDEX IF NOT EXISTS _moonyao_messages_chat ON _moonyao_messages(chat_id, sequence)",
    "CREATE UNIQUE INDEX IF NOT EXISTS _moonyao_one_active_turn ON _moonyao_turns(chat_id) WHERE status = 'active'",
    "INSERT OR IGNORE INTO _moonyao_migrations(version) VALUES (1)",
  ]
  for statement in statements {
    match exec(connection, statement, "conversation.migrate") {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  let version = connection.prepare(
    "SELECT COUNT(*) FROM _moonyao_migrations WHERE version = 2",
  ) catch {
    _ =>
      return Err(
        @errors.database_error(
          "could not inspect conversation migration", "conversation.migrate",
        ),
      )
  }
  let has_v2 = try {
    ignore(version.step())
    let count : Int = version.column(index=0)
    version.finalize()
    count > 0
  } catch {
    _ => {
      version.finalize() catch {
        _ => ()
      }
      return Err(
        @errors.database_error(
          "could not inspect conversation migration", "conversation.migrate",
        ),
      )
    }
  }
  if !has_v2 {
    let upgrade = [
      "BEGIN IMMEDIATE", "CREATE TABLE _moonyao_messages_v2 (id TEXT PRIMARY KEY, chat_id TEXT NOT NULL REFERENCES _moonyao_chats(id) ON DELETE CASCADE, turn_id TEXT NOT NULL REFERENCES _moonyao_turns(id) ON DELETE CASCADE, sequence INTEGER NOT NULL, role TEXT NOT NULL CHECK(role IN ('user','assistant','tool')), kind TEXT NOT NULL CHECK(kind IN ('text','tool_calls','tool_result','internal')), content_json TEXT NOT NULL, status TEXT NOT NULL CHECK(status IN ('completed','failed')), created_at INTEGER NOT NULL, UNIQUE(chat_id, sequence))",
      "INSERT INTO _moonyao_messages_v2(id, chat_id, turn_id, sequence, role, kind, content_json, status, created_at) SELECT id, chat_id, turn_id, sequence, role, kind, content_json, status, created_at FROM _moonyao_messages",
      "DROP TABLE _moonyao_messages", "ALTER TABLE _moonyao_messages_v2 RENAME TO _moonyao_messages",
      "CREATE INDEX _moonyao_messages_chat ON _moonyao_messages(chat_id, sequence)",
      "INSERT INTO _moonyao_migrations(version) VALUES (2)", "COMMIT",
    ]
    for statement in upgrade {
      match exec(connection, statement, "conversation.migrate.v2") {
        Ok(_) => ()
        Err(error) => {
          rollback(connection)
          return Err(error)
        }
      }
    }
  }
  Ok(())
}

///|
pub fn append_message(
  connection : @sqlite3.Connection,
  id : String,
  chat_id : String,
  turn_id : String,
  role : String,
  kind : String,
  content : Json,
  now : Int64,
) -> Result[Unit, @errors.EngineError] {
  if !["assistant", "tool"].contains(role) ||
    !["tool_calls", "tool_result", "internal"].contains(kind) {
    return Err(
      @errors.invalid_argument("invalid transcript message", "message"),
    )
  }
  let source = content.stringify()
  if source.length() > 262144 {
    return Err(
      @errors.invalid_argument("transcript message is too large", "message"),
    )
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
    "INSERT INTO _moonyao_messages(id, chat_id, turn_id, sequence, role, kind, content_json, status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, 'completed', ?)",
  ) catch {
    _ => {
      rollback(connection)
      return Err(
        @errors.database_error(
          "could not prepare transcript message", "message",
        ),
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
    statement.bind(index=7, source)
    statement.bind(index=8, now)
    statement.step_once()
    statement.finalize()
  } catch {
    _ => {
      statement.finalize() catch {
        _ => ()
      }
      rollback(connection)
      return Err(
        @errors.database_error("could not save transcript message", "message"),
      )
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
pub fn recover_active(
  connection : @sqlite3.Connection,
  now : Int64,
) -> Result[Int, @errors.EngineError] {
  let count_statement = connection.prepare(
    "SELECT COUNT(*) FROM _moonyao_turns WHERE status = 'active'",
  ) catch {
    _ =>
      return Err(
        @errors.database_error(
          "could not inspect active turns", "conversation.recover",
        ),
      )
  }
  let count = try {
    ignore(count_statement.step())
    let value : Int = count_statement.column(index=0)
    count_statement.finalize()
    value
  } catch {
    _ => {
      count_statement.finalize() catch {
        _ => ()
      }
      return Err(
        @errors.database_error(
          "could not inspect active turns", "conversation.recover",
        ),
      )
    }
  }
  let statement = connection.prepare(
    "UPDATE _moonyao_turns SET status = 'interrupted', error_code = 'interrupted', error_message = 'turn was interrupted', finished_at = ? WHERE status = 'active'",
  ) catch {
    _ =>
      return Err(
        @errors.database_error(
          "could not recover active turns", "conversation.recover",
        ),
      )
  }
  try {
    statement.bind(index=1, now)
    statement.step_once()
    statement.finalize()
    Ok(count)
  } catch {
    _ => {
      statement.finalize() catch {
        _ => ()
      }
      Err(
        @errors.database_error(
          "could not recover active turns", "conversation.recover",
        ),
      )
    }
  }
}

///|
pub fn create_chat(
  connection : @sqlite3.Connection,
  id : String,
  agent_id : String,
  title : String,
  now : Int64,
) -> Result[Chat, @errors.EngineError] {
  let statement = connection.prepare(
    "INSERT INTO _moonyao_chats(id, agent_id, title, status, created_at, updated_at) VALUES (?, ?, ?, 'active', ?, ?)",
  ) catch {
    _ => return Err(@errors.database_error("could not prepare chat", "chat"))
  }
  try {
    statement.bind(index=1, id)
    statement.bind(index=2, agent_id)
    statement.bind(index=3, title)
    statement.bind(index=4, now)
    statement.bind(index=5, now)
    statement.step_once()
    statement.finalize()
    Ok({
      id,
      agent_id,
      title,
      status: "active",
      created_at: now,
      updated_at: now,
    })
  } catch {
    _ => {
      statement.finalize() catch {
        _ => ()
      }
      Err(@errors.database_error("could not create chat", "chat"))
    }
  }
}

///|
pub fn get_chat(
  connection : @sqlite3.Connection,
  id : String,
) -> Result[Chat, @errors.EngineError] {
  let statement = connection.prepare(
    "SELECT id, agent_id, title, status, created_at, updated_at FROM _moonyao_chats WHERE id = ? AND status = 'active'",
  ) catch {
    _ =>
      return Err(@errors.database_error("could not prepare chat query", "chat"))
  }
  try {
    statement.bind(index=1, id)
    if !statement.step() {
      statement.finalize()
      return Err(@errors.chat_not_found())
    }
    let chat : Chat = {
      id: statement.column(index=0),
      agent_id: statement.column(index=1),
      title: statement.column(index=2),
      status: statement.column(index=3),
      created_at: statement.column(index=4),
      updated_at: statement.column(index=5),
    }
    statement.finalize()
    Ok(chat)
  } catch {
    _ => {
      statement.finalize() catch {
        _ => ()
      }
      Err(@errors.database_error("could not read chat", "chat"))
    }
  }
}

///|
pub fn list_chats(
  connection : @sqlite3.Connection,
  limit : Int,
  offset : Int,
) -> Result[Array[Chat], @errors.EngineError] {
  if limit < 0 || limit > 100 || offset < 0 {
    return Err(@errors.invalid_argument("invalid pagination", "chat"))
  }
  let statement = connection.prepare(
    "SELECT id, agent_id, title, status, created_at, updated_at FROM _moonyao_chats WHERE status = 'active' ORDER BY updated_at DESC, id LIMIT ? OFFSET ?",
  ) catch {
    _ =>
      return Err(@errors.database_error("could not prepare chat list", "chat"))
  }
  let chats : Array[Chat] = []
  try {
    statement.bind(index=1, limit)
    statement.bind(index=2, offset)
    while statement.step() {
      chats.push({
        id: statement.column(index=0),
        agent_id: statement.column(index=1),
        title: statement.column(index=2),
        status: statement.column(index=3),
        created_at: statement.column(index=4),
        updated_at: statement.column(index=5),
      })
    }
    statement.finalize()
    Ok(chats)
  } catch {
    _ => {
      statement.finalize() catch {
        _ => ()
      }
      Err(@errors.database_error("could not list chats", "chat"))
    }
  }
}

///|
pub fn list_chats_for_agent(
  connection : @sqlite3.Connection,
  agent_id : String,
  limit : Int,
  offset : Int,
) -> Result[Array[Chat], @errors.EngineError] {
  if limit < 1 || limit > 100 || offset < 0 {
    return Err(@errors.invalid_argument("invalid pagination", "query"))
  }
  let statement = connection.prepare(
    "SELECT id, agent_id, title, status, created_at, updated_at FROM _moonyao_chats WHERE status = 'active' AND (? = '' OR agent_id = ?) ORDER BY updated_at DESC, id ASC LIMIT ? OFFSET ?",
  ) catch {
    _ =>
      return Err(@errors.database_error("could not prepare chat list", "chat"))
  }
  let chats : Array[Chat] = []
  try {
    statement.bind(index=1, agent_id)
    statement.bind(index=2, agent_id)
    statement.bind(index=3, limit)
    statement.bind(index=4, offset)
    while statement.step() {
      chats.push({
        id: statement.column(index=0),
        agent_id: statement.column(index=1),
        title: statement.column(index=2),
        status: statement.column(index=3),
        created_at: statement.column(index=4),
        updated_at: statement.column(index=5),
      })
    }
    statement.finalize()
    Ok(chats)
  } catch {
    _ => {
      statement.finalize() catch {
        _ => ()
      }
      Err(@errors.database_error("could not list chats", "chat"))
    }
  }
}

///|
pub fn count_chats(
  connection : @sqlite3.Connection,
  agent_id : String,
) -> Result[Int, @errors.EngineError] {
  let statement = connection.prepare(
    "SELECT COUNT(*) FROM _moonyao_chats WHERE status = 'active' AND (? = '' OR agent_id = ?)",
  ) catch {
    _ =>
      return Err(@errors.database_error("could not prepare chat count", "chat"))
  }
  try {
    statement.bind(index=1, agent_id)
    statement.bind(index=2, agent_id)
    ignore(statement.step())
    let count : Int = statement.column(index=0)
    statement.finalize()
    Ok(count)
  } catch {
    _ => {
      statement.finalize() catch {
        _ => ()
      }
      Err(@errors.database_error("could not count chats", "chat"))
    }
  }
}

///|
pub fn get_turn(
  connection : @sqlite3.Connection,
  id : String,
) -> Result[Turn, @errors.EngineError] {
  let statement = connection.prepare(
    "SELECT id, chat_id, status, error_code, error_message, prompt_tokens, completion_tokens, started_at, finished_at FROM _moonyao_turns WHERE id = ?",
  ) catch {
    _ =>
      return Err(@errors.database_error("could not prepare turn query", "turn"))
  }
  try {
    statement.bind(index=1, id)
    if !statement.step() {
      statement.finalize()
      return Err(@errors.invalid_argument("turn was not found", "turn"))
    }
    let turn : Turn = {
      id: statement.column(index=0),
      chat_id: statement.column(index=1),
      status: statement.column(index=2),
      error_code: statement.column(index=3),
      error_message: statement.column(index=4),
      prompt_tokens: statement.column(index=5),
      completion_tokens: statement.column(index=6),
      started_at: statement.column(index=7),
      finished_at: statement.column(index=8),
    }
    statement.finalize()
    Ok(turn)
  } catch {
    _ => {
      statement.finalize() catch {
        _ => ()
      }
      Err(@errors.database_error("could not read turn", "turn"))
    }
  }
}

///|
pub fn active_turn_id(
  connection : @sqlite3.Connection,
  chat_id : String,
) -> Result[String, @errors.EngineError] {
  let statement = connection.prepare(
    "SELECT id FROM _moonyao_turns WHERE chat_id = ? AND status = 'active' LIMIT 1",
  ) catch {
    _ =>
      return Err(
        @errors.database_error("could not inspect active turn", "chat"),
      )
  }
  try {
    statement.bind(index=1, chat_id)
    let id : String = if statement.step() {
      statement.column(index=0)
    } else {
      ""
    }
    statement.finalize()
    Ok(id)
  } catch {
    _ => {
      statement.finalize() catch {
        _ => ()
      }
      Err(@errors.database_error("could not inspect active turn", "chat"))
    }
  }
}

///|
pub fn rename_chat(
  connection : @sqlite3.Connection,
  id : String,
  title : String,
  now : Int64,
) -> Result[Unit, @errors.EngineError] {
  if title.length() == 0 || title.length() > 200 {
    return Err(@errors.invalid_argument("invalid chat title", "chat.title"))
  }
  match get_chat(connection, id) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let statement = connection.prepare(
    "UPDATE _moonyao_chats SET title = ?, updated_at = ? WHERE id = ?",
  ) catch {
    _ =>
      return Err(
        @errors.database_error("could not prepare chat rename", "chat"),
      )
  }
  try {
    statement.bind(index=1, title)
    statement.bind(index=2, now)
    statement.bind(index=3, id)
    statement.step_once()
    statement.finalize()
    Ok(())
  } catch {
    _ => {
      statement.finalize() catch {
        _ => ()
      }
      Err(@errors.database_error("could not rename chat", "chat"))
    }
  }
}

///|
pub fn begin_turn(
  connection : @sqlite3.Connection,
  turn_id : String,
  message_id : String,
  chat_id : String,
  content : String,
  now : Int64,
) -> Result[Unit, @errors.EngineError] {
  match get_chat(connection, chat_id) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  match exec(connection, "BEGIN IMMEDIATE", "turn.begin") {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let next_statement = connection.prepare(
    "SELECT COALESCE(MAX(sequence), 0) + 1 FROM _moonyao_messages WHERE chat_id = ?",
  ) catch {
    _ => {
      rollback(connection)
      return Err(
        @errors.database_error("could not prepare message sequence", "turn"),
      )
    }
  }
  let sequence = try {
    next_statement.bind(index=1, chat_id)
    ignore(next_statement.step())
    let value : Int = next_statement.column(index=0)
    next_statement.finalize()
    value
  } catch {
    _ => {
      next_statement.finalize() catch {
        _ => ()
      }
      rollback(connection)
      return Err(
        @errors.database_error("could not allocate message sequence", "turn"),
      )
    }
  }
  let turn = connection.prepare(
    "INSERT INTO _moonyao_turns(id, chat_id, status, error_code, error_message, prompt_tokens, completion_tokens, started_at, finished_at) VALUES (?, ?, 'active', '', '', -1, -1, ?, 0)",
  ) catch {
    _ => {
      rollback(connection)
      return Err(@errors.database_error("could not prepare turn", "turn"))
    }
  }
  try {
    turn.bind(index=1, turn_id)
    turn.bind(index=2, chat_id)
    turn.bind(index=3, now)
    turn.step_once()
    turn.finalize()
  } catch {
    _ => {
      turn.finalize() catch {
        _ => ()
      }
      rollback(connection)
      return Err(@errors.turn_conflict())
    }
  }
  let message = connection.prepare(
    "INSERT INTO _moonyao_messages(id, chat_id, turn_id, sequence, role, kind, content_json, status, created_at) VALUES (?, ?, ?, ?, 'user', 'text', ?, 'completed', ?)",
  ) catch {
    _ => {
      rollback(connection)
      return Err(
        @errors.database_error("could not prepare user message", "turn"),
      )
    }
  }
  try {
    message.bind(index=1, message_id)
    message.bind(index=2, chat_id)
    message.bind(index=3, turn_id)
    message.bind(index=4, sequence)
    message.bind(index=5, Json::string(content).stringify())
    message.bind(index=6, now)
    message.step_once()
    message.finalize()
  } catch {
    _ => {
      message.finalize() catch {
        _ => ()
      }
      rollback(connection)
      return Err(@errors.database_error("could not save user message", "turn"))
    }
  }
  match exec(connection, "COMMIT", "turn.begin") {
    Ok(_) => Ok(())
    Err(e) => {
      rollback(connection)
      Err(e)
    }
  }
}

///|
pub fn complete_turn(
  connection : @sqlite3.Connection,
  message_id : String,
  chat_id : String,
  turn_id : String,
  content : String,
  usage : @llm.Usage,
  now : Int64,
) -> Result[Unit, @errors.EngineError] {
  if content.length() == 0 {
    return Err(@errors.llm_error("model returned empty text"))
  }
  match exec(connection, "BEGIN IMMEDIATE", "turn.complete") {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let active_statement = connection.prepare(
    "SELECT COUNT(*) FROM _moonyao_turns WHERE id = ? AND chat_id = ? AND status = 'active'",
  ) catch {
    _ => {
      rollback(connection)
      return Err(
        @errors.database_error("could not inspect active turn", "turn"),
      )
    }
  }
  let active_count = try {
    active_statement.bind(index=1, turn_id)
    active_statement.bind(index=2, chat_id)
    ignore(active_statement.step())
    let value : Int = active_statement.column(index=0)
    active_statement.finalize()
    value
  } catch {
    _ => {
      active_statement.finalize() catch {
        _ => ()
      }
      rollback(connection)
      return Err(
        @errors.database_error("could not inspect active turn", "turn"),
      )
    }
  }
  if active_count != 1 {
    rollback(connection)
    return Err(@errors.turn_conflict())
  }
  let sequence_statement = connection.prepare(
    "SELECT COALESCE(MAX(sequence), 0) + 1 FROM _moonyao_messages WHERE chat_id = ?",
  ) catch {
    _ => {
      rollback(connection)
      return Err(
        @errors.database_error("could not prepare message sequence", "turn"),
      )
    }
  }
  let sequence = try {
    sequence_statement.bind(index=1, chat_id)
    ignore(sequence_statement.step())
    let v : Int = sequence_statement.column(index=0)
    sequence_statement.finalize()
    v
  } catch {
    _ => {
      sequence_statement.finalize() catch {
        _ => ()
      }
      rollback(connection)
      return Err(
        @errors.database_error("could not allocate message sequence", "turn"),
      )
    }
  }
  let message = connection.prepare(
    "INSERT INTO _moonyao_messages(id, chat_id, turn_id, sequence, role, kind, content_json, status, created_at) VALUES (?, ?, ?, ?, 'assistant', 'text', ?, 'completed', ?)",
  ) catch {
    _ => {
      rollback(connection)
      return Err(
        @errors.database_error("could not prepare assistant message", "turn"),
      )
    }
  }
  try {
    message.bind(index=1, message_id)
    message.bind(index=2, chat_id)
    message.bind(index=3, turn_id)
    message.bind(index=4, sequence)
    message.bind(index=5, Json::string(content).stringify())
    message.bind(index=6, now)
    message.step_once()
    message.finalize()
  } catch {
    _ => {
      message.finalize() catch {
        _ => ()
      }
      rollback(connection)
      return Err(
        @errors.database_error("could not save assistant message", "turn"),
      )
    }
  }
  let update = connection.prepare(
    "UPDATE _moonyao_turns SET status = 'completed', prompt_tokens = ?, completion_tokens = ?, finished_at = ? WHERE id = ? AND status = 'active'",
  ) catch {
    _ => {
      rollback(connection)
      return Err(
        @errors.database_error("could not prepare turn completion", "turn"),
      )
    }
  }
  try {
    update.bind(index=1, usage.prompt_tokens)
    update.bind(index=2, usage.completion_tokens)
    update.bind(index=3, now)
    update.bind(index=4, turn_id)
    update.step_once()
    update.finalize()
  } catch {
    _ => {
      update.finalize() catch {
        _ => ()
      }
      rollback(connection)
      return Err(@errors.database_error("could not complete turn", "turn"))
    }
  }
  let chat = connection.prepare(
    "UPDATE _moonyao_chats SET updated_at = ? WHERE id = ?",
  ) catch {
    _ => {
      rollback(connection)
      return Err(
        @errors.database_error("could not prepare chat update", "turn"),
      )
    }
  }
  try {
    chat.bind(index=1, now)
    chat.bind(index=2, chat_id)
    chat.step_once()
    chat.finalize()
  } catch {
    _ => {
      chat.finalize() catch {
        _ => ()
      }
      rollback(connection)
      return Err(@errors.database_error("could not update chat", "turn"))
    }
  }
  match exec(connection, "COMMIT", "turn.complete") {
    Ok(_) => Ok(())
    Err(e) => {
      rollback(connection)
      Err(e)
    }
  }
}

///|
pub fn fail_turn(
  connection : @sqlite3.Connection,
  turn_id : String,
  code : String,
  message : String,
  now : Int64,
) -> Result[Unit, @errors.EngineError] {
  let statement = connection.prepare(
    "UPDATE _moonyao_turns SET status = 'failed', error_code = ?, error_message = ?, finished_at = ? WHERE id = ? AND status = 'active'",
  ) catch {
    _ =>
      return Err(
        @errors.database_error("could not prepare turn failure", "turn"),
      )
  }
  try {
    statement.bind(index=1, code)
    statement.bind(index=2, message)
    statement.bind(index=3, now)
    statement.bind(index=4, turn_id)
    statement.step_once()
    statement.finalize()
    Ok(())
  } catch {
    _ => {
      statement.finalize() catch {
        _ => ()
      }
      Err(@errors.database_error("could not fail turn", "turn"))
    }
  }
}

///|
fn decode_content(source : String, kind : String) -> String {
  if kind != "text" {
    return source
  }
  let value = @json.parse(source) catch { _ => return "" }
  match value {
    String(content) => content
    _ => ""
  }
}

///|
pub fn completed_messages(
  connection : @sqlite3.Connection,
  chat_id : String,
) -> Result[Array[Message], @errors.EngineError] {
  let statement = connection.prepare(
    "SELECT m.id, m.chat_id, m.turn_id, m.sequence, m.role, m.kind, m.content_json, m.status, m.created_at FROM _moonyao_messages m JOIN _moonyao_turns t ON t.id = m.turn_id WHERE m.chat_id = ? AND t.status = 'completed' AND m.kind != 'internal' ORDER BY m.sequence",
  ) catch {
    _ =>
      return Err(
        @errors.database_error("could not prepare chat history", "chat"),
      )
  }
  let messages : Array[Message] = []
  try {
    statement.bind(index=1, chat_id)
    while statement.step() {
      let kind : String = statement.column(index=5)
      let source : String = statement.column(index=6)
      messages.push({
        id: statement.column(index=0),
        chat_id: statement.column(index=1),
        turn_id: statement.column(index=2),
        sequence: statement.column(index=3),
        role: statement.column(index=4),
        kind,
        content: decode_content(source, kind),
        status: statement.column(index=7),
        created_at: statement.column(index=8),
      })
    }
    statement.finalize()
    Ok(messages)
  } catch {
    _ => {
      statement.finalize() catch {
        _ => ()
      }
      Err(@errors.database_error("could not read chat history", "chat"))
    }
  }
}

///|
pub fn list_messages(
  connection : @sqlite3.Connection,
  chat_id : String,
  limit : Int,
  offset : Int,
) -> Result[Array[Message], @errors.EngineError] {
  if limit < 0 || limit > 100 || offset < 0 {
    return Err(@errors.invalid_argument("invalid pagination", "message"))
  }
  match get_chat(connection, chat_id) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let statement = connection.prepare(
    "SELECT id, chat_id, turn_id, sequence, role, kind, content_json, status, created_at FROM _moonyao_messages WHERE chat_id = ? ORDER BY sequence LIMIT ? OFFSET ?",
  ) catch {
    _ =>
      return Err(
        @errors.database_error("could not prepare message list", "message"),
      )
  }
  let messages : Array[Message] = []
  try {
    statement.bind(index=1, chat_id)
    statement.bind(index=2, limit)
    statement.bind(index=3, offset)
    while statement.step() {
      let kind : String = statement.column(index=5)
      let source : String = statement.column(index=6)
      messages.push({
        id: statement.column(index=0),
        chat_id: statement.column(index=1),
        turn_id: statement.column(index=2),
        sequence: statement.column(index=3),
        role: statement.column(index=4),
        kind,
        content: decode_content(source, kind),
        status: statement.column(index=7),
        created_at: statement.column(index=8),
      })
    }
    statement.finalize()
    Ok(messages)
  } catch {
    _ => {
      statement.finalize() catch {
        _ => ()
      }
      Err(@errors.database_error("could not list messages", "message"))
    }
  }
}

///|
pub fn list_public_messages(
  connection : @sqlite3.Connection,
  chat_id : String,
  limit : Int,
  offset : Int,
) -> Result[Array[PublicMessage], @errors.EngineError] {
  if limit < 1 || limit > 100 || offset < 0 {
    return Err(@errors.invalid_argument("invalid pagination", "query"))
  }
  match get_chat(connection, chat_id) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let statement = connection.prepare(
    "SELECT m.id, m.chat_id, m.turn_id, m.sequence, m.role, m.kind, m.content_json, m.status, m.created_at, t.status FROM _moonyao_messages m JOIN _moonyao_turns t ON t.id = m.turn_id WHERE m.chat_id = ? AND m.kind != 'internal' ORDER BY m.sequence ASC LIMIT ? OFFSET ?",
  ) catch {
    _ =>
      return Err(
        @errors.database_error(
          "could not prepare public message list", "message",
        ),
      )
  }
  let messages : Array[PublicMessage] = []
  try {
    statement.bind(index=1, chat_id)
    statement.bind(index=2, limit)
    statement.bind(index=3, offset)
    while statement.step() {
      let kind : String = statement.column(index=5)
      let source : String = statement.column(index=6)
      messages.push({
        message: {
          id: statement.column(index=0),
          chat_id: statement.column(index=1),
          turn_id: statement.column(index=2),
          sequence: statement.column(index=3),
          role: statement.column(index=4),
          kind,
          content: decode_content(source, kind),
          status: statement.column(index=7),
          created_at: statement.column(index=8),
        },
        turn_status: statement.column(index=9),
      })
    }
    statement.finalize()
    Ok(messages)
  } catch {
    _ => {
      statement.finalize() catch {
        _ => ()
      }
      Err(@errors.database_error("could not list public messages", "message"))
    }
  }
}

///|
pub fn count_public_messages(
  connection : @sqlite3.Connection,
  chat_id : String,
) -> Result[Int, @errors.EngineError] {
  match get_chat(connection, chat_id) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let statement = connection.prepare(
    "SELECT COUNT(*) FROM _moonyao_messages WHERE chat_id = ? AND kind != 'internal'",
  ) catch {
    _ =>
      return Err(
        @errors.database_error("could not prepare message count", "message"),
      )
  }
  try {
    statement.bind(index=1, chat_id)
    ignore(statement.step())
    let count : Int = statement.column(index=0)
    statement.finalize()
    Ok(count)
  } catch {
    _ => {
      statement.finalize() catch {
        _ => ()
      }
      Err(@errors.database_error("could not count messages", "message"))
    }
  }
}

///|
pub fn delete_chat(
  connection : @sqlite3.Connection,
  id : String,
) -> Result[Unit, @errors.EngineError] {
  match get_chat(connection, id) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let active = connection.prepare(
    "SELECT COUNT(*) FROM _moonyao_turns WHERE chat_id = ? AND status = 'active'",
  ) catch {
    _ => return Err(@errors.database_error("could not inspect chat", "chat"))
  }
  let count = try {
    active.bind(index=1, id)
    ignore(active.step())
    let v : Int = active.column(index=0)
    active.finalize()
    v
  } catch {
    _ => {
      active.finalize() catch {
        _ => ()
      }
      return Err(@errors.database_error("could not inspect chat", "chat"))
    }
  }
  if count > 0 {
    return Err(@errors.turn_conflict())
  }
  let statement = connection.prepare("DELETE FROM _moonyao_chats WHERE id = ?") catch {
    _ =>
      return Err(
        @errors.database_error("could not prepare chat deletion", "chat"),
      )
  }
  try {
    statement.bind(index=1, id)
    statement.step_once()
    statement.finalize()
    Ok(())
  } catch {
    _ => {
      statement.finalize() catch {
        _ => ()
      }
      Err(@errors.database_error("could not delete chat", "chat"))
    }
  }
}
