///|
test "conversation migration, state transitions, recovery, and deletion" {
  let connection = @sqlite3.Connection::open(":memory:")
  match migrate(connection) {
    Ok(_) => ()
    Err(error) => fail(error.message)
  }
  match migrate(connection) {
    Ok(_) => ()
    Err(error) => fail(error.message)
  }
  match create_chat(connection, "chat", "todo", "hello", 1) {
    Ok(_) => ()
    Err(error) => fail(error.message)
  }
  match begin_turn(connection, "turn1", "user1", "chat", "hello", 2) {
    Ok(_) => ()
    Err(error) => fail(error.message)
  }
  match begin_turn(connection, "turn2", "user2", "chat", "conflict", 3) {
    Err(error) => assert_eq(error.code, @errors.TurnConflict)
    Ok(_) => fail("expected active-turn conflict")
  }
  match
    complete_turn(
      connection,
      "assistant1",
      "chat",
      "turn1",
      "hi",
      { prompt_tokens: 2, completion_tokens: 1 },
      4,
    ) {
    Ok(_) => ()
    Err(error) => fail(error.message)
  }
  match begin_turn(connection, "turn2", "user2", "chat", "fail", 5) {
    Ok(_) => ()
    Err(error) => fail(error.message)
  }
  match fail_turn(connection, "turn2", "llm_error", "provider failed", 6) {
    Ok(_) => ()
    Err(error) => fail(error.message)
  }
  match completed_messages(connection, "chat") {
    Ok(messages) => {
      assert_eq(messages.length(), 2)
      assert_eq(messages[1].content, "hi")
    }
    Err(error) => fail(error.message)
  }
  match list_messages(connection, "chat", 1, 1) {
    Ok(messages) => {
      assert_eq(messages.length(), 1)
      assert_eq(messages[0].role, "assistant")
    }
    Err(error) => fail(error.message)
  }
  match begin_turn(connection, "turn3", "user3", "chat", "restart", 7) {
    Ok(_) => ()
    Err(error) => fail(error.message)
  }
  match recover_active(connection, 8) {
    Ok(count) => assert_eq(count, 1)
    Err(error) => fail(error.message)
  }
  match
    complete_turn(
      connection,
      "late-assistant",
      "chat",
      "turn3",
      "too late",
      { prompt_tokens: -1, completion_tokens: -1 },
      9,
    ) {
    Err(error) => assert_eq(error.code, @errors.TurnConflict)
    Ok(_) => fail("expected interrupted-turn conflict")
  }
  match delete_chat(connection, "chat") {
    Ok(_) => ()
    Err(error) => fail(error.message)
  }
  match get_chat(connection, "chat") {
    Err(error) => assert_eq(error.code, @errors.ChatNotFound)
    Ok(_) => fail("expected deletion")
  }
  connection.close()
}

///|
test "chat CRUD pagination and active deletion guard" {
  let connection = @sqlite3.Connection::open(":memory:")
  ignore(migrate(connection))
  ignore(create_chat(connection, "a", "todo", "first", 1))
  ignore(create_chat(connection, "b", "todo", "second", 2))
  match list_chats(connection, 1, 0) {
    Ok(chats) => assert_eq(chats[0].id, "b")
    Err(error) => fail(error.message)
  }
  ignore(rename_chat(connection, "a", "renamed", 3))
  match get_chat(connection, "a") {
    Ok(chat) => assert_eq(chat.title, "renamed")
    Err(error) => fail(error.message)
  }
  ignore(begin_turn(connection, "t", "m", "a", "x", 4))
  match delete_chat(connection, "a") {
    Err(error) => assert_eq(error.code, @errors.TurnConflict)
    Ok(_) => fail("expected guard")
  }
  connection.close()
}

///|
test "conversation migration upgrades the P5 text-only message table" {
  let connection = @sqlite3.Connection::open(":memory:")
  let setup = [
    "PRAGMA foreign_keys = ON", "CREATE TABLE _moonyao_migrations (version INTEGER PRIMARY KEY)",
    "CREATE TABLE _moonyao_chats (id TEXT PRIMARY KEY, agent_id TEXT NOT NULL, title TEXT NOT NULL, status TEXT NOT NULL CHECK(status IN ('active','deleted')), created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)",
    "CREATE TABLE _moonyao_turns (id TEXT PRIMARY KEY, chat_id TEXT NOT NULL REFERENCES _moonyao_chats(id) ON DELETE CASCADE, status TEXT NOT NULL CHECK(status IN ('active','completed','failed','interrupted')), error_code TEXT NOT NULL, error_message TEXT NOT NULL, prompt_tokens INTEGER NOT NULL, completion_tokens INTEGER NOT NULL, started_at INTEGER NOT NULL, finished_at INTEGER NOT NULL)",
    "CREATE TABLE _moonyao_messages (id TEXT PRIMARY KEY, chat_id TEXT NOT NULL REFERENCES _moonyao_chats(id) ON DELETE CASCADE, turn_id TEXT NOT NULL REFERENCES _moonyao_turns(id) ON DELETE CASCADE, sequence INTEGER NOT NULL, role TEXT NOT NULL CHECK(role IN ('user','assistant')), kind TEXT NOT NULL CHECK(kind = 'text'), content_json TEXT NOT NULL, status TEXT NOT NULL CHECK(status IN ('completed','failed')), created_at INTEGER NOT NULL, UNIQUE(chat_id, sequence))",
    "INSERT INTO _moonyao_migrations(version) VALUES (1)",
  ]
  for sql in setup {
    let statement = connection.prepare(sql)
    statement.step_once()
    statement.finalize()
  }
  match migrate(connection) {
    Ok(_) => ()
    Err(error) => fail(error.message)
  }
  ignore(create_chat(connection, "chat", "todo", "upgrade", 1))
  ignore(begin_turn(connection, "turn", "user", "chat", "hello", 2))
  match
    append_message(
      connection,
      "tool",
      "chat",
      "turn",
      "tool",
      "tool_result",
      {
        "tool_call_id": "call",
        "name": "create_todo",
        "ok": true,
        "result": { "id": 1 },
      },
      3,
    ) {
    Ok(_) => ()
    Err(error) => fail(error.message)
  }
  match list_messages(connection, "chat", 10, 0) {
    Ok(messages) => assert_eq(messages[1].kind, "tool_result")
    Err(error) => fail(error.message)
  }
  connection.close()
}
