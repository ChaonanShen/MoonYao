///|
test "migration v4 persists bounded Create lifecycle snapshots" {
  let connection = @sqlite3.Connection::open(":memory:")
  ignore(migrate(connection))
  ignore(create_chat(connection, "chat", "todo", "Test", 1))
  ignore(begin_turn(connection, "turn", "user", "chat", "hello", 2))
  let context : Json = {
    "context_id": "ctx_turn",
    "chat_id": "chat",
    "turn_id": "turn",
  }
  let decision : Json = {
    "generation": { "temperature": 0.1, "max_tokens": 1200 },
  }
  match save_create_snapshot(connection, "turn", context, decision) {
    Ok(_) => ()
    Err(error) => fail(error.message)
  }
  match create_snapshot(connection, "turn") {
    Ok((stored_context, stored_decision)) => {
      assert_eq(stored_context, context)
      assert_eq(stored_decision, decision)
    }
    Err(error) => fail(error.message)
  }
  match
    save_create_snapshot(
      connection,
      "turn",
      { "metadata": "x".repeat(33000) },
      Json::null(),
    ) {
    Err(error) => assert_eq(error.path, "turn.context")
    Ok(_) => fail("expected context snapshot budget")
  }
  match migrate(connection) {
    Ok(_) => ()
    Err(error) => fail(error.message)
  }
  connection.close()
}
