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
    tools: [],
    tool_names: [],
    before_process: "",
    after_process: "",
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
        index.to_int64(),
        (_, _) => Err(@errors.internal_error("unexpected invocation", "test")),
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
      kind: "text",
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
      kind: "text",
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
      kind: "text",
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
      kind: "text",
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
      kind: "text",
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
      kind: "text",
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
      kind: "text",
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
      kind: "text",
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
    tools: [],
    tool_names: [],
    before_process: "",
    after_process: "",
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
      (_, _) => Err(@errors.internal_error("unexpected invocation", "test")),
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

///|
fn tool_test_agent() -> Agent {
  {
    id: "todo",
    name: "Todo",
    description: "",
    connector: "default",
    options: { temperature: 0.2, max_tokens: 128 },
    prompts: [{ role: @llm.System, content: "Use tools." }],
    tools: [
      {
        name: "create_todo",
        description: "Create one Todo.",
        process: "models.todo.Create",
        input_schema: {
          "type": "object",
          "properties": {
            "data": {
              "type": "object",
              "properties": { "title": { "type": "string", "minLength": 1 } },
              "required": ["title"],
              "additionalProperties": false,
            },
          },
          "required": ["data"],
          "additionalProperties": false,
        },
      },
    ],
    tool_names: ["create_todo"],
    before_process: "",
    after_process: "",
  }
}

///|
fn tool_test_connector() -> @llm.Connector {
  {
    id: "default",
    connector_type: "openai_chat",
    base_url: "http://127.0.0.1:1/v1",
    api_key_env: "TEST_KEY",
    model: "fake",
    timeout_ms: 1000,
  }
}

///|
fn tool_test_ids(suffix : String) -> Ids {
  {
    chat_id: "chat" + suffix,
    turn_id: "turn" + suffix,
    user_message_id: "user" + suffix,
    assistant_message_id: "assistant" + suffix,
  }
}

///|
fn fake_tool_response(arguments : String) -> FakeResponse {
  let call : @llm.ToolCall = {
    id: "call-1",
    name: "create_todo",
    arguments_json: arguments,
  }
  {
    events: [@llm.Started, @llm.ToolCallCompleted(call), @llm.Completed],
    content: "",
    usage: { prompt_tokens: 2, completion_tokens: 1 },
    error: None,
  }
}

///|
fn fake_text_response(content : String) -> FakeResponse {
  {
    events: [@llm.Started, @llm.TextDelta(content), @llm.Completed],
    content,
    usage: { prompt_tokens: 2, completion_tokens: 1 },
    error: None,
  }
}

///|
async test "bounded tool loop validates, invokes, and persists transcript" {
  ignore(@async.now())
  let connection = @sqlite3.Connection::open(":memory:")
  ignore(@conversation.migrate(connection))
  let mut invoked = 0
  let mut invoked_process = ""
  let mut saw_ship = false
  let observed : Array[@llm.CompletionEvent] = []
  match
    run_turn(
      connection,
      tool_test_agent(),
      tool_test_connector(),
      Client::FakeSequence([
        fake_tool_response("{\"data\":{\"title\":\"ship\"}}"),
        fake_text_response("Created Todo 1."),
      ]),
      None,
      "Create ship",
      tool_test_ids("1"),
      1,
      (process, input) => {
        invoked = invoked + 1
        invoked_process = process
        saw_ship = input.stringify().contains("ship")
        Ok(({ "id": 1, "title": "ship" } : Json))
      },
      event => observed.push(event),
    ) {
    Ok(result) => assert_eq(result.content, "Created Todo 1.")
    Err(error) => fail(error.message)
  }
  assert_eq(invoked, 1)
  assert_eq(invoked_process, "models.todo.Create")
  assert_true(saw_ship)
  assert_true(observed.any(event => event is @llm.ToolStarted(_, _)))
  match @conversation.completed_messages(connection, "chat1") {
    Ok(messages) => {
      assert_eq(messages.length(), 4)
      assert_eq(messages[1].kind, "tool_calls")
      assert_eq(messages[2].kind, "tool_result")
    }
    Err(error) => fail(error.message)
  }
  connection.close()
}

///|
async test "schema errors are returned to the model without invoking a Process" {
  ignore(@async.now())
  let connection = @sqlite3.Connection::open(":memory:")
  ignore(@conversation.migrate(connection))
  let mut invoked = false
  match
    run_turn(
      connection,
      tool_test_agent(),
      tool_test_connector(),
      Client::FakeSequence([
        fake_tool_response("{}"),
        fake_text_response("Please provide a title."),
      ]),
      None,
      "Create one",
      tool_test_ids("2"),
      1,
      (_, _) => {
        invoked = true
        Ok(Json::null())
      },
      _ => (),
    ) {
    Ok(result) => assert_eq(result.content, "Please provide a title.")
    Err(error) => fail(error.message)
  }
  assert_false(invoked)
  connection.close()
}

///|
async test "tool allowlist violations fail without Process invocation" {
  ignore(@async.now())
  let connection = @sqlite3.Connection::open(":memory:")
  ignore(@conversation.migrate(connection))
  let call : @llm.ToolCall = { id: "bad", name: "admin", arguments_json: "{}" }
  let response : FakeResponse = {
    events: [@llm.Started, @llm.ToolCallCompleted(call), @llm.Completed],
    content: "",
    usage: { prompt_tokens: 1, completion_tokens: 1 },
    error: None,
  }
  let mut invoked = false
  match
    run_turn(
      connection,
      tool_test_agent(),
      tool_test_connector(),
      Client::Fake(response),
      None,
      "Do admin",
      tool_test_ids("3"),
      1,
      (_, _) => {
        invoked = true
        Ok(Json::null())
      },
      _ => (),
    ) {
    Err(error) => assert_eq(error.code, @errors.ToolError)
    Ok(_) => fail("expected allowlist failure")
  }
  assert_false(invoked)
  connection.close()
}

///|
async test "optional Process hooks can rewrite input and finish output" {
  ignore(@async.now())
  let connection = @sqlite3.Connection::open(":memory:")
  ignore(@conversation.migrate(connection))
  let agent : Agent = {
    ..tool_test_agent(),
    tools: [],
    tool_names: [],
    before_process: "flows.before",
    after_process: "flows.after",
  }
  let mut saw_before = false
  let mut saw_after = false
  match
    run_turn(
      connection,
      agent,
      tool_test_connector(),
      Client::Fake(fake_text_response("draft")),
      None,
      "hello",
      tool_test_ids("4"),
      1,
      (process, input) => {
        if process == "flows.before" {
          saw_before = input.stringify().contains("hello")
          Ok(
            (
              {
                "messages": [{ "role": "user", "content": "rewritten" }],
                "metadata": { "checked": true },
              } : Json),
          )
        } else {
          saw_after = input.stringify().contains("checked")
          Ok(({ "action": "finish", "content": "final" } : Json))
        }
      },
      _ => (),
    ) {
    Ok(result) => assert_eq(result.content, "final")
    Err(error) => fail(error.message)
  }
  assert_true(saw_before)
  assert_true(saw_after)
  connection.close()
}

///|
async test "tool loop enforces LLM round and tool-call budgets" {
  ignore(@async.now())
  let connection = @sqlite3.Connection::open(":memory:")
  ignore(@conversation.migrate(connection))
  let rounds : Array[FakeResponse] = []
  for index = 0; index < 8; index = index + 1 {
    rounds.push(fake_tool_response("{\"data\":{\"title\":\"loop\"}}"))
  }
  match
    run_turn(
      connection,
      tool_test_agent(),
      tool_test_connector(),
      Client::FakeSequence(rounds),
      None,
      "Loop",
      tool_test_ids("5"),
      1,
      (_, _) => Ok(({ "id": 1 } : Json)),
      _ => (),
    ) {
    Err(error) => assert_eq(error.code, @errors.TurnLimitExceeded)
    Ok(_) => fail("expected round limit")
  }
  let calls : Array[@llm.CompletionEvent] = [@llm.Started]
  for index = 0; index < 33; index = index + 1 {
    calls.push(
      @llm.ToolCallCompleted({
        id: "call-" + index.to_string(),
        name: "create_todo",
        arguments_json: "{\"data\":{\"title\":\"bulk\"}}",
      }),
    )
  }
  calls.push(@llm.Completed)
  let too_many : FakeResponse = {
    events: calls,
    content: "",
    usage: { prompt_tokens: 1, completion_tokens: 1 },
    error: None,
  }
  match
    run_turn(
      connection,
      tool_test_agent(),
      tool_test_connector(),
      Client::Fake(too_many),
      None,
      "Bulk",
      tool_test_ids("6"),
      1,
      (_, _) => Ok(Json::null()),
      _ => (),
    ) {
    Err(error) => assert_eq(error.code, @errors.TurnLimitExceeded)
    Ok(_) => fail("expected tool-call limit")
  }
  connection.close()
}

///|
async test "after hook continuation shares a limit with the LLM loop" {
  ignore(@async.now())
  let connection = @sqlite3.Connection::open(":memory:")
  ignore(@conversation.migrate(connection))
  let agent : Agent = {
    ..tool_test_agent(),
    tools: [],
    tool_names: [],
    after_process: "flows.after",
  }
  match
    run_turn(
      connection,
      agent,
      tool_test_connector(),
      Client::FakeSequence([
        fake_text_response("one"),
        fake_text_response("two"),
        fake_text_response("three"),
      ]),
      None,
      "continue",
      tool_test_ids("7"),
      1,
      (_, _) => {
        Ok(
          (
            {
              "action": "continue",
              "messages": [{ "role": "user", "content": "again" }],
            } : Json),
        )
      },
      _ => (),
    ) {
    Err(error) => assert_eq(error.code, @errors.TurnLimitExceeded)
    Ok(_) => fail("expected continuation limit")
  }
  connection.close()
}
