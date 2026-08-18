///|
async test "fake client runs three persisted turns and restart-compatible history" {
  ignore(@async.now())
  let connection = @sqlite3.Connection::open(":memory:")
  ignore(@conversation.migrate(connection))
  let agent : Agent = {
    id: "todo",
    name: "Todo",
    description: "",
    connector: "default",
    options: { temperature: 0.2, max_tokens: 128 },
    prompts: [{ role: @llm.System, content: "Be concise." }],
  }
  let connector : @llm.Connector = {
    id: "default",
    connector_type: "openai_chat",
    base_url: "http://127.0.0.1:1/v1",
    api_key_env: "TEST_KEY",
    model: "fake",
    timeout_ms: 1000,
  }
  for index = 1; index <= 3; index = index + 1 {
    let suffix = index.to_string()
    let ids : Ids = {
      chat_id: "chat",
      turn_id: "turn" + suffix,
      user_message_id: "user" + suffix,
      assistant_message_id: "assistant" + suffix,
    }
    let response : FakeResponse = {
      events: [@llm.Started, @llm.TextDelta("answer" + suffix), @llm.Completed],
      content: "answer" + suffix,
      usage: ({ prompt_tokens: index, completion_tokens: 1 } : @llm.Usage),
      error: None,
    }
    let fake : Client = Client::Fake(response)
    let existing = if index == 1 { None } else { Some("chat") }
    match
      run_turn(
        connection,
        agent,
        connector,
        fake,
        existing,
        "question" + suffix,
        ids,
        index,
        _ => (),
      ) {
      Ok(result) => assert_eq(result.content, "answer" + suffix)
      Err(error) => fail(error.message)
    }
  }
  match @conversation.completed_messages(connection, "chat") {
    Ok(messages) => assert_eq(messages.length(), 6)
    Err(error) => fail(error.message)
  }
  connection.close()
}

///|
test "history keeps whole recent turns and rejects oversized current input" {
  let stored : Array[@conversation.Message] = [
    {
      id: "1",
      chat_id: "c",
      turn_id: "t",
      sequence: 1,
      role: "user",
      content: "u",
      status: "completed",
      created_at: 1,
    },
    {
      id: "2",
      chat_id: "c",
      turn_id: "t",
      sequence: 2,
      role: "assistant",
      content: "a",
      status: "completed",
      created_at: 1,
    },
  ]
  match build_history([{ role: @llm.System, content: "s" }], stored, "now") {
    Ok(history) => {
      assert_eq(history.messages.length(), 4)
      assert_eq(history.messages[3].content, "now")
    }
    Err(error) => fail(error.message)
  }
  match build_history([], [], "x".repeat(262145)) {
    Err(error) => assert_eq(error.code, @errors.InvalidArgument)
    Ok(_) => fail("expected size error")
  }
}

///|
test "history truncation keeps a contiguous recent suffix" {
  let huge = "x".repeat(262140)
  let stored : Array[@conversation.Message] = [
    {
      id: "1",
      chat_id: "c",
      turn_id: "old",
      sequence: 1,
      role: "user",
      content: "o",
      status: "completed",
      created_at: 1,
    },
    {
      id: "2",
      chat_id: "c",
      turn_id: "old",
      sequence: 2,
      role: "assistant",
      content: "o",
      status: "completed",
      created_at: 1,
    },
    {
      id: "3",
      chat_id: "c",
      turn_id: "large",
      sequence: 3,
      role: "user",
      content: huge,
      status: "completed",
      created_at: 2,
    },
    {
      id: "4",
      chat_id: "c",
      turn_id: "large",
      sequence: 4,
      role: "assistant",
      content: "x",
      status: "completed",
      created_at: 2,
    },
    {
      id: "5",
      chat_id: "c",
      turn_id: "new",
      sequence: 5,
      role: "user",
      content: "n",
      status: "completed",
      created_at: 3,
    },
    {
      id: "6",
      chat_id: "c",
      turn_id: "new",
      sequence: 6,
      role: "assistant",
      content: "n",
      status: "completed",
      created_at: 3,
    },
  ]
  match build_history([], stored, "now") {
    Ok(history) => {
      assert_true(history.truncated)
      assert_eq(history.messages.length(), 3)
      assert_eq(history.messages[0].content, "n")
    }
    Err(error) => fail(error.message)
  }
}

///|
async test "invalid current input has no database side effects" {
  ignore(@async.now())
  let connection = @sqlite3.Connection::open(":memory:")
  ignore(@conversation.migrate(connection))
  let agent : Agent = {
    id: "todo",
    name: "Todo",
    description: "",
    connector: "default",
    options: { temperature: 0.2, max_tokens: 128 },
    prompts: [{ role: @llm.System, content: "system" }],
  }
  let connector : @llm.Connector = {
    id: "default",
    connector_type: "openai_chat",
    base_url: "http://127.0.0.1:1/v1",
    api_key_env: "TEST_KEY",
    model: "fake",
    timeout_ms: 1000,
  }
  let response : FakeResponse = {
    events: [],
    content: "unused",
    usage: { prompt_tokens: -1, completion_tokens: -1 },
    error: None,
  }
  let ids : Ids = {
    chat_id: "chat",
    turn_id: "turn",
    user_message_id: "user",
    assistant_message_id: "assistant",
  }
  match
    run_turn(
      connection,
      agent,
      connector,
      Client::Fake(response),
      None,
      "",
      ids,
      1,
      _ => (),
    ) {
    Err(error) => assert_eq(error.code, @errors.InvalidArgument)
    Ok(_) => fail("expected invalid input")
  }
  match @conversation.list_chats(connection, 10, 0) {
    Ok(chats) => assert_eq(chats.length(), 0)
    Err(error) => fail(error.message)
  }
  connection.close()
}
