///|
test "turn context snapshot is bounded and excludes runtime services" {
  let snapshot = context_snapshot(
    "ctx_1",
    "req_1",
    "chat_1",
    "turn_1",
    "todo",
    "default",
    { "source": "test" },
    1000,
    301000,
  ).unwrap()
  let encoded = context_json(snapshot).stringify()
  assert_true(encoded.contains("\"context_id\":\"ctx_1\""))
  assert_true(encoded.contains("\"metadata\":{\"source\":\"test\"}"))
  assert_false(encoded.contains("api_key"))
  assert_false(encoded.contains("connection"))
  assert_false(encoded.contains("database"))
  match
    context_snapshot(
      "chat_1",
      "req_1",
      "chat_1",
      "turn_1",
      "todo",
      "default",
      {},
      1000,
      2000,
    ) {
    Err(error) => assert_eq(error.path, "context.id")
    Ok(_) => fail("expected distinct context identity")
  }
  match
    context_snapshot(
      "ctx_1",
      "req_1",
      "chat_1",
      "turn_1",
      "todo",
      "default",
      Json::array([]),
      1000,
      2000,
    ) {
    Err(error) => assert_eq(error.path, "context.metadata")
    Ok(_) => fail("expected object metadata")
  }
  match
    context_snapshot(
      "ctx_1",
      "req_1",
      "chat_1",
      "turn_1",
      "todo",
      "default",
      { "value": "x".repeat(33000) },
      1000,
      2000,
    ) {
    Err(error) => assert_eq(error.path, "context.metadata")
    Ok(_) => fail("expected bounded metadata")
  }
  match
    context_snapshot(
      "ctx_1",
      "req_1",
      "chat_1",
      "turn_1",
      "todo",
      "default",
      {},
      1000,
      301001,
    ) {
    Err(error) => assert_eq(error.path, "context.deadline_at")
    Ok(_) => fail("expected bounded deadline")
  }
}

///|
test "turn lifecycle accepts only declared transitions" {
  let context = context_snapshot(
    "ctx_1",
    "req_1",
    "chat_1",
    "turn_1",
    "todo",
    "default",
    {},
    1000,
    2000,
  ).unwrap()
  let lifecycle = begin_lifecycle(context)
  let begun = lifecycle.advance(Begun).unwrap()
  let history = begun.advance(HistoryLoaded).unwrap()
  let creating = history.advance(Creating).unwrap()
  let running = creating.advance(Running).unwrap()
  let next = running.advance(Next).unwrap()
  let finalizing = next.advance(Finalizing).unwrap()
  let terminal = finalizing.advance(Terminal).unwrap()
  assert_eq(terminal.phase, Terminal)
  match terminal.advance(Running) {
    Err(error) => assert_eq(error.path, "turn.phase")
    Ok(_) => fail("expected terminal phase to be final")
  }
  assert_eq(
    begin_lifecycle(context).advance(Finalizing).unwrap().phase,
    Finalizing,
  )
}

///|
test "finalize persists and emits one terminal event" {
  let connection = @sqlite3.Connection::open(":memory:")
  ignore(@conversation.migrate(connection))
  ignore(@conversation.create_chat(connection, "chat_1", "todo", "Test", 1))
  ignore(
    @conversation.begin_turn(
      connection, "turn_1", "user_1", "chat_1", "hello", 2,
    ),
  )
  let snapshot = context_snapshot(
    "ctx_1",
    "req_1",
    "chat_1",
    "turn_1",
    "todo",
    "default",
    {},
    1000,
    2000,
  ).unwrap()
  let events : Array[@llm.CompletionEvent] = []
  let runtime : TurnRuntimeContext = {
    snapshot,
    connection,
    invoke: (_, _) => {
      Err(@errors.internal_error("unexpected invocation", "test"))
    },
    sink: event => events.push(event),
  }
  let failure = @errors.llm_error("provider failed")
  match finalize_turn(runtime, "assistant_1", Failed(failure), 3) {
    Err(error) => assert_eq(error, failure)
    Ok(_) => fail("failure outcome must return its error")
  }
  assert_eq(events, [@llm.Failed("llm_error")])
  match @conversation.active_turn_id(connection, "chat_1") {
    Ok(value) => assert_eq(value, "")
    Err(error) => fail(error.message)
  }
  match finalize_turn(runtime, "assistant_1", Failed(failure), 4) {
    Err(error) => assert_eq(error.code, @errors.TurnConflict)
    Ok(_) => fail("terminal turn must reject a second finalization")
  }
  assert_eq(events.length(), 1)
  connection.close()
}
