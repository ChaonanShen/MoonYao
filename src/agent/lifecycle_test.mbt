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

///|
test "completion and cancellation races emit one terminal event" {
  let connection = @sqlite3.Connection::open(":memory:")
  ignore(@conversation.migrate(connection))
  for index = 0; index < 100; index = index + 1 {
    let suffix = index.to_string()
    let chat_id = "chat_" + suffix
    let turn_id = "turn_" + suffix
    ignore(@conversation.create_chat(connection, chat_id, "todo", "race", 1))
    ignore(
      @conversation.begin_turn(
        connection,
        turn_id,
        "user_" + suffix,
        chat_id,
        "hello",
        2,
      ),
    )
    let snapshot = context_snapshot(
      "ctx_" + suffix,
      "req_" + suffix,
      chat_id,
      turn_id,
      "todo",
      "default",
      {},
      1,
      1000,
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
    if index % 2 == 0 {
      ignore(
        finalize_turn(
          runtime,
          "assistant_" + suffix,
          Completed("done", { prompt_tokens: 1, completion_tokens: 1 }),
          3,
        ),
      )
      ignore(finalize_turn(runtime, "assistant_" + suffix, Cancelled, 4))
      assert_eq(
        @conversation.get_turn(connection, turn_id).unwrap().status,
        "completed",
      )
    } else {
      ignore(finalize_turn(runtime, "assistant_" + suffix, Cancelled, 3))
      ignore(
        finalize_turn(
          runtime,
          "assistant_" + suffix,
          Completed("late", { prompt_tokens: 1, completion_tokens: 1 }),
          4,
        ),
      )
      assert_eq(
        @conversation.get_turn(connection, turn_id).unwrap().status,
        "cancelled",
      )
    }
    assert_eq(events.length(), 1)
  }
  for index = 0; index < 100; index = index + 1 {
    let suffix = index.to_string()
    let chat_id = "timeout_chat_" + suffix
    let turn_id = "timeout_turn_" + suffix
    ignore(@conversation.create_chat(connection, chat_id, "todo", "race", 1))
    ignore(
      @conversation.begin_turn(
        connection,
        turn_id,
        "timeout_user_" + suffix,
        chat_id,
        "hello",
        2,
      ),
    )
    let snapshot = context_snapshot(
      "timeout_ctx_" + suffix,
      "timeout_req_" + suffix,
      chat_id,
      turn_id,
      "todo",
      "default",
      {},
      1,
      1000,
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
    if index % 2 == 0 {
      ignore(finalize_turn(runtime, "unused_" + suffix, TimedOut, 3))
      ignore(finalize_turn(runtime, "unused_" + suffix, Cancelled, 4))
      assert_eq(
        @conversation.get_turn(connection, turn_id).unwrap().status,
        "timed_out",
      )
    } else {
      ignore(finalize_turn(runtime, "unused_" + suffix, Cancelled, 3))
      ignore(finalize_turn(runtime, "unused_" + suffix, TimedOut, 4))
      assert_eq(
        @conversation.get_turn(connection, turn_id).unwrap().status,
        "cancelled",
      )
    }
    assert_eq(events.length(), 1)
  }
  connection.close()
}

///|
async test "supervisor hard cancellation and deadline persist control outcomes" {
  @async.with_task_group() <| group => {
    let connection = @sqlite3.Connection::open(":memory:")
    ignore(@conversation.migrate(connection))
    ignore(
      @conversation.create_chat(connection, "cancel-chat", "todo", "cancel", 1),
    )
    ignore(
      @conversation.begin_turn(
        connection, "cancel-turn", "cancel-user", "cancel-chat", "hello", 2,
      ),
    )
    let cancellation = TurnCancellation::new()
    let deadline_at = @env.now().reinterpret_as_int64() + 5000
    let events : Array[@llm.CompletionEvent] = []
    let task = group.spawn(allow_failure=true) <| () => {
      supervise_turn(
        connection,
        "cancel-turn",
        cancellation,
        deadline_at,
        event => events.push(event),
        () => {
          @async.sleep(1000)
          Ok({
            chat_id: "cancel-chat",
            turn_id: "cancel-turn",
            content: "late",
            next: None,
            events: [],
            history_truncated: false,
            usage: { prompt_tokens: 0, completion_tokens: 0 },
          })
        },
      )
    }
    let supervisor = TurnSupervisor::new()
    ignore(
      supervisor.register("cancel-turn", cancellation, deadline_at, () => {
        task.cancel()
      }),
    )
    @async.sleep(10)
    ignore(@conversation.request_turn_cancel(connection, "cancel-turn", 10))
    assert_true(supervisor.request_cancel("cancel-turn", 10))
    match task.wait() {
      Err(error) => assert_eq(error.code, @errors.TurnCancelled)
      Ok(_) => fail("expected cancelled turn")
    }
    assert_eq(
      @conversation.get_turn(connection, "cancel-turn").unwrap().status,
      "cancelled",
    )
    assert_eq(events, [@llm.Cancelled])

    ignore(
      @conversation.create_chat(
        connection, "timeout-chat", "todo", "timeout", 1,
      ),
    )
    ignore(
      @conversation.begin_turn(
        connection, "timeout-turn", "timeout-user", "timeout-chat", "hello", 2,
      ),
    )
    let timeout_events : Array[@llm.CompletionEvent] = []
    let timeout = supervise_turn(
      connection,
      "timeout-turn",
      TurnCancellation::new(),
      @env.now().reinterpret_as_int64() + 10,
      event => timeout_events.push(event),
      () => {
        @async.sleep(1000)
        Ok({
          chat_id: "timeout-chat",
          turn_id: "timeout-turn",
          content: "late",
          next: None,
          events: [],
          history_truncated: false,
          usage: { prompt_tokens: 0, completion_tokens: 0 },
        })
      },
    )
    match timeout {
      Err(error) => assert_eq(error.code, @errors.TurnTimedOut)
      Ok(_) => fail("expected timed out turn")
    }
    assert_eq(
      @conversation.get_turn(connection, "timeout-turn").unwrap().status,
      "timed_out",
    )
    assert_eq(timeout_events, [@llm.TimedOut])

    ignore(
      @conversation.create_chat(
        connection, "shutdown-chat", "todo", "shutdown", 1,
      ),
    )
    ignore(
      @conversation.begin_turn(
        connection, "shutdown-turn", "shutdown-user", "shutdown-chat", "hello", 2,
      ),
    )
    let shutdown_events : Array[@llm.CompletionEvent] = []
    let shutdown_cancellation = TurnCancellation::new()
    let shutdown_task = group.spawn(allow_failure=true) <| () => {
      supervise_turn(
        connection,
        "shutdown-turn",
        shutdown_cancellation,
        @env.now().reinterpret_as_int64() + 5000,
        event => shutdown_events.push(event),
        () => {
          @async.sleep(1000)
          Ok({
            chat_id: "shutdown-chat",
            turn_id: "shutdown-turn",
            content: "late",
            next: None,
            events: [],
            history_truncated: false,
            usage: { prompt_tokens: 0, completion_tokens: 0 },
          })
        },
      )
    }
    @async.sleep(10)
    shutdown_task.cancel()
    match shutdown_task.wait() {
      Err(error) => assert_eq(error.code, @errors.TurnInterrupted)
      Ok(_) => fail("expected interrupted turn")
    }
    assert_eq(
      @conversation.get_turn(connection, "shutdown-turn").unwrap().status,
      "interrupted",
    )
    assert_eq(shutdown_events, [@llm.Interrupted])
    connection.close()
  }
}
