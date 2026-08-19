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

///|
test "canonical messages persist attachment references beside legacy fields" {
  let connection = @sqlite3.Connection::open(":memory:")
  match migrate(connection) {
    Err(error) => fail(error.message)
    Ok(_) => ()
  }
  ignore(create_chat(connection, "chat", "todo", "canonical", 1))
  ignore(begin_turn(connection, "turn", "user", "chat", "look", 2))
  let attachment : @attachment.Attachment = {
    id: "att_abcdef12",
    storage_key: "ab/att_abcdef12",
    filename: "image.png",
    media_type: "image/png",
    byte_size: 8,
    sha256: "hash",
    kind: @attachment.Image,
    status: "ready",
    created_at: 2,
    deleted_at: 0,
  }
  match @attachment.insert(connection, attachment) {
    Err(error) => fail(error.message)
    Ok(_) => ()
  }
  let parts : Array[@content.ContentPart] = [
    @content.TextPart("look"),
    @content.ImageRef(attachment.id, @content.Auto),
  ]
  let message : @content.Message = {
    role: @content.Assistant,
    content: Some(@content.Parts(parts)),
    name: None,
    tool_call_id: None,
    reasoning_content: None,
    tool_calls: [],
    refusal: None,
  }
  match
    append_canonical(
      connection, "assistant", "chat", "turn", "multipart", message, 3,
    ) {
    Err(error) => fail(error.message)
    Ok(_) => ()
  }
  match list_canonical(connection, "chat") {
    Ok(messages) => {
      assert_eq(messages.length(), 2)
      assert_eq(messages[1].message, message)
    }
    Err(error) => fail(error.message)
  }
  let refs = connection.prepare(
    "SELECT COUNT(*) FROM _moonyao_message_attachments WHERE message_id = 'assistant'",
  )
  ignore(refs.step())
  let count : Int = refs.column(index=0)
  refs.finalize()
  assert_eq(count, 1)
  connection.close()
}

///|
test "platform queries filter chats, hide internal messages, and report active turns" {
  let connection = @sqlite3.Connection::open(":memory:")
  ignore(migrate(connection))
  ignore(create_chat(connection, "a", "todo", "Todo", 1))
  ignore(create_chat(connection, "b", "other", "Other", 2))
  match list_chats_for_agent(connection, "todo", 20, 0) {
    Ok(chats) => assert_eq(chats.length(), 1)
    Err(error) => fail(error.message)
  }
  match count_chats(connection, "") {
    Ok(count) => assert_eq(count, 2)
    Err(error) => fail(error.message)
  }
  ignore(begin_turn(connection, "turn", "user", "a", "hello", 3))
  match active_turn_id(connection, "a") {
    Ok(id) => assert_eq(id, "turn")
    Err(error) => fail(error.message)
  }
  ignore(
    append_message(
      connection,
      "internal",
      "a",
      "turn",
      "assistant",
      "internal",
      { "messages": [] },
      4,
    ),
  )
  match list_public_messages(connection, "a", 20, 0) {
    Ok(messages) => {
      assert_eq(messages.length(), 1)
      assert_eq(messages[0].turn_status, "active")
    }
    Err(error) => fail(error.message)
  }
  match count_public_messages(connection, "a") {
    Ok(count) => assert_eq(count, 1)
    Err(error) => fail(error.message)
  }
  connection.close()
}

///|
test "v4 migration preserves turns and foreign keys while adding control state" {
  let connection = @sqlite3.Connection::open(":memory:")
  let setup = [
    "PRAGMA foreign_keys = ON", "CREATE TABLE _moonyao_migrations (version INTEGER PRIMARY KEY)",
    "CREATE TABLE _moonyao_chats (id TEXT PRIMARY KEY, agent_id TEXT NOT NULL, title TEXT NOT NULL, status TEXT NOT NULL CHECK(status IN ('active','deleted')), created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)",
    "CREATE TABLE _moonyao_turns (id TEXT PRIMARY KEY, chat_id TEXT NOT NULL REFERENCES _moonyao_chats(id) ON DELETE CASCADE, status TEXT NOT NULL CHECK(status IN ('active','completed','failed','interrupted')), error_code TEXT NOT NULL, error_message TEXT NOT NULL, prompt_tokens INTEGER NOT NULL, completion_tokens INTEGER NOT NULL, started_at INTEGER NOT NULL, finished_at INTEGER NOT NULL)",
    "CREATE TABLE _moonyao_messages (id TEXT PRIMARY KEY, chat_id TEXT NOT NULL REFERENCES _moonyao_chats(id) ON DELETE CASCADE, turn_id TEXT NOT NULL REFERENCES _moonyao_turns(id) ON DELETE CASCADE, sequence INTEGER NOT NULL, role TEXT NOT NULL, kind TEXT NOT NULL, content_json TEXT NOT NULL, status TEXT NOT NULL, created_at INTEGER NOT NULL, canonical_json TEXT NOT NULL DEFAULT '', UNIQUE(chat_id, sequence))",
    "INSERT INTO _moonyao_migrations(version) VALUES (1), (2), (3), (4)", "INSERT INTO _moonyao_chats VALUES ('chat', 'todo', 'old', 'active', 1, 1)",
    "INSERT INTO _moonyao_turns VALUES ('turn', 'chat', 'completed', '', '', 2, 1, 2, 3)",
  ]
  for sql in setup {
    let statement = connection.prepare(sql)
    statement.step_once()
    statement.finalize()
  }
  let message = connection.prepare(
    "INSERT INTO _moonyao_messages(id, chat_id, turn_id, sequence, role, kind, content_json, status, created_at, canonical_json) VALUES ('user', 'chat', 'turn', 1, 'user', 'text', '\"hello\"', 'completed', 2, '')",
  )
  message.step_once()
  message.finalize()
  match migrate(connection) {
    Err(error) => fail(error.message)
    Ok(_) => ()
  }
  let turn = get_turn(connection, "turn").unwrap()
  assert_eq(turn.status, "completed")
  assert_eq(turn.cancel_requested_at, 0)
  assert_eq(turn.deadline_at, 0)
  assert_eq(turn.retry_of_turn_id, "")
  assert_eq(turn.attempt, 1)
  assert_eq(turn.idempotency_key, "")
  assert_eq(turn.request_hash, "")
  let version = connection.prepare(
    "SELECT COUNT(*) FROM _moonyao_migrations WHERE version = 6",
  )
  ignore(version.step())
  let version_count : Int = version.column(index=0)
  version.finalize()
  assert_eq(version_count, 1)
  let events = connection.prepare(
    "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '_moonyao_turn_events'",
  )
  ignore(events.step())
  let event_table_count : Int = events.column(index=0)
  events.finalize()
  assert_eq(event_table_count, 1)
  let foreign_keys = connection.prepare("PRAGMA foreign_key_check")
  assert_false(foreign_keys.step())
  foreign_keys.finalize()
  ignore(delete_chat(connection, "chat"))
  match get_turn(connection, "turn") {
    Err(error) => assert_eq(error.code, @errors.RecordNotFound)
    Ok(_) => fail("expected turn cascade deletion")
  }
  connection.close()
}

///|
test "turn cancellation request is idempotent and terminal control uses CAS" {
  let connection = @sqlite3.Connection::open(":memory:")
  ignore(migrate(connection))
  ignore(create_chat(connection, "chat", "todo", "control", 1))
  ignore(
    begin_turn(connection, "turn", "user", "chat", "hello", 2, deadline_at=5000),
  )
  assert_eq(
    request_turn_cancel(connection, "turn", 10).unwrap().cancel_requested_at,
    10,
  )
  assert_eq(
    request_turn_cancel(connection, "turn", 20).unwrap().cancel_requested_at,
    10,
  )
  assert_true(cancel_turn(connection, "turn", 30).unwrap())
  assert_false(timeout_turn(connection, "turn", 31).unwrap())
  assert_false(interrupt_turn(connection, "turn", 32).unwrap())
  let turn = request_turn_cancel(connection, "turn", 40).unwrap()
  assert_eq(turn.status, "cancelled")
  assert_eq(turn.cancel_requested_at, 10)
  match request_turn_cancel(connection, "missing", 50) {
    Err(error) => assert_eq(error.code, @errors.RecordNotFound)
    Ok(_) => fail("expected missing turn rejection")
  }
  connection.close()
}

///|
test "turn event journal orders replay and records one terminal event" {
  let connection = @sqlite3.Connection::open(":memory:")
  ignore(migrate(connection))
  ignore(create_chat(connection, "chat", "todo", "events", 1))
  ignore(begin_turn(connection, "turn", "user", "chat", "hello", 2))
  match
    append_event(connection, "turn", "hook.started", { "kind": "create" }, 3) {
    Ok(event) => assert_eq(event.sequence, 2)
    Err(error) => fail(error.message)
  }
  match
    append_event(connection, "turn", "message.delta", { "delta": "hi" }, 4) {
    Ok(event) => assert_eq(event.sequence, 3)
    Err(error) => fail(error.message)
  }
  ignore(
    complete_turn(
      connection,
      "assistant",
      "chat",
      "turn",
      "hi",
      { prompt_tokens: 2, completion_tokens: 1 },
      5,
    ),
  )
  match list_events(connection, "turn", 2, 100) {
    Ok(events) => {
      assert_eq(events.length(), 3)
      assert_eq(events[0].sequence, 3)
      assert_eq(events[0].event, "message.delta")
      assert_eq(events[1].event, "message.completed")
      assert_eq(events[2].event, "turn.completed")
      assert_true(
        events[2].data.stringify().contains("\"status\":\"completed\""),
      )
    }
    Err(error) => fail(error.message)
  }
  match
    append_event(connection, "turn", "message.delta", { "delta": "late" }, 6) {
    Err(error) => assert_eq(error.code, @errors.TurnConflict)
    Ok(_) => fail("expected terminal event append rejection")
  }
  let terminal = connection.prepare(
    "SELECT COUNT(*) FROM _moonyao_turn_events WHERE turn_id = 'turn' AND event LIKE 'turn.%' AND event != 'turn.started'",
  )
  ignore(terminal.step())
  let count : Int = terminal.column(index=0)
  terminal.finalize()
  assert_eq(count, 1)
  connection.close()
}

///|
test "startup recovery appends an interrupted terminal event" {
  let connection = @sqlite3.Connection::open(":memory:")
  ignore(migrate(connection))
  ignore(create_chat(connection, "chat", "todo", "recover", 1))
  ignore(begin_turn(connection, "turn", "user", "chat", "hello", 2))
  assert_eq(recover_active(connection, 3).unwrap(), 1)
  let events = list_events(connection, "turn", 0, 100).unwrap()
  assert_eq(events.length(), 2)
  assert_eq(events[1].event, "turn.interrupted")
  assert_eq(get_turn(connection, "turn").unwrap().status, "interrupted")
  assert_eq(recover_active(connection, 4).unwrap(), 0)
  assert_eq(list_events(connection, "turn", 0, 100).unwrap().length(), 2)
  connection.close()
}

///|
test "idempotency and retry preserve canonical input and root attempts" {
  let connection = @sqlite3.Connection::open(":memory:")
  ignore(migrate(connection))
  ignore(create_chat(connection, "chat", "todo", "retry", 1))
  let attachment : @attachment.Attachment = {
    id: "att_abcdefghijklmnopqrst",
    storage_key: "ab/att_abcdefghijklmnopqrst",
    filename: "note.txt",
    media_type: "text/plain",
    byte_size: 5,
    sha256: "hash",
    kind: @attachment.Text,
    status: "ready",
    created_at: 1,
    deleted_at: 0,
  }
  ignore(@attachment.insert(connection, attachment))
  let input : @content.Message = {
    role: @content.User,
    content: Some(
      @content.Parts([
        @content.TextPart("read"),
        @content.FileRef(attachment.id, attachment.filename),
      ]),
    ),
    name: None,
    tool_call_id: None,
    reasoning_content: None,
    tool_calls: [],
    refusal: None,
  }
  ignore(
    begin_turn(
      connection,
      "root",
      "user-root",
      "chat",
      "read [File: note.txt]",
      2,
      idempotency_key="initial-key",
      request_hash="initial-hash",
      canonical_message=Some(input),
    ),
  )
  match get_turn_by_idempotency(connection, "chat", "initial-key") {
    Ok(Some(turn)) => assert_eq(turn.id, "root")
    _ => fail("expected idempotent turn lookup")
  }
  ignore(fail_turn(connection, "root", "llm_error", "failed", 3))
  let original = user_message_for_turn(connection, "root").unwrap()
  assert_eq(original.message, input)
  ignore(
    begin_turn(
      connection,
      "retry-2",
      "user-retry-2",
      "chat",
      "read [File: note.txt]",
      4,
      idempotency_key="retry-key-2",
      request_hash="retry-hash-2",
      canonical_message=Some(original.message),
      retry_source_turn_id="root",
    ),
  )
  let retry2 = get_turn(connection, "retry-2").unwrap()
  assert_eq(retry2.retry_of_turn_id, "root")
  assert_eq(retry2.attempt, 2)
  ignore(fail_turn(connection, "retry-2", "llm_error", "failed again", 5))
  ignore(
    begin_turn(
      connection,
      "retry-3",
      "user-retry-3",
      "chat",
      "read [File: note.txt]",
      6,
      canonical_message=Some(original.message),
      retry_source_turn_id="retry-2",
    ),
  )
  let retry3 = get_turn(connection, "retry-3").unwrap()
  assert_eq(retry3.retry_of_turn_id, "root")
  assert_eq(retry3.attempt, 3)
  assert_eq(
    user_message_for_turn(connection, "retry-3").unwrap().message,
    input,
  )
  let refs = connection.prepare(
    "SELECT COUNT(*) FROM _moonyao_message_attachments WHERE message_id IN ('user-root','user-retry-2','user-retry-3')",
  )
  ignore(refs.step())
  let ref_count : Int = refs.column(index=0)
  refs.finalize()
  assert_eq(ref_count, 3)
  match
    begin_turn(
      connection,
      "retry-active",
      "user-retry-active",
      "chat",
      "read",
      7,
      retry_source_turn_id="retry-3",
    ) {
    Err(error) => assert_eq(error.code, @errors.TurnConflict)
    Ok(_) => fail("expected active retry rejection")
  }
  ignore(fail_turn(connection, "retry-3", "llm_error", "third failure", 8))
  ignore(
    begin_turn(connection, "completed", "user-completed", "chat", "done", 9),
  )
  ignore(
    complete_turn(
      connection,
      "assistant-completed",
      "chat",
      "completed",
      "done",
      { prompt_tokens: 1, completion_tokens: 1 },
      10,
    ),
  )
  match
    begin_turn(
      connection,
      "retry-completed",
      "user-retry-completed",
      "chat",
      "done",
      11,
      retry_source_turn_id="completed",
    ) {
    Err(error) => {
      assert_eq(error.code, @errors.TurnConflict)
      assert_eq(error.path, "turn.retry")
    }
    Ok(_) => fail("expected completed retry rejection")
  }
  connection.close()
}
