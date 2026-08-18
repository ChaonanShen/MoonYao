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
