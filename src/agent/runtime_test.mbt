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
    create_process: "",
    next_process: "",
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
async test "canonical turn persists multipart input and attachment references" {
  ignore(@async.now())
  let connection = @sqlite3.Connection::open(":memory:")
  ignore(@conversation.migrate(connection))
  let attachment : @attachment.Attachment = {
    id: "att_abcdefghijklmnopqrst",
    storage_key: "ab/att_abcdefghijklmnopqrst",
    filename: "notes.txt",
    media_type: "text/plain",
    byte_size: 5,
    sha256: @attachment.digest(b"hello"),
    kind: @attachment.Text,
    status: "ready",
    created_at: 1,
    deleted_at: 0,
  }
  match @attachment.insert(connection, attachment) {
    Err(error) => fail(error.message)
    Ok(_) => ()
  }
  let message : @content.Message = {
    role: @content.User,
    content: Some(
      @content.Parts([
        @content.TextPart("Read this"),
        @content.FileRef(attachment.id, attachment.filename),
      ]),
    ),
    name: None,
    tool_call_id: None,
    reasoning_content: None,
    tool_calls: [],
    refusal: None,
  }
  let wire : Json = {
    "role": "user",
    "content": [
      { "type": "text", "text": "Read this" },
      { "type": "text", "text": "hello" },
    ],
  }
  match
    run_turn_message(
      connection,
      {
        id: "todo",
        name: "Todo",
        description: "",
        connector: "default",
        options: { temperature: 0.0, max_tokens: 32 },
        prompts: [],
        tools: [],
        tool_names: [],
        create_process: "",
        next_process: "",
        before_process: "",
        after_process: "",
      },
      {
        id: "default",
        connector_type: "openai_chat",
        base_url: "http://127.0.0.1:1/v1",
        api_key_env: "TEST_KEY",
        model: "fake",
        timeout_ms: 1000,
      },
      Client::Fake({
        events: [@llm.Started, @llm.TextDelta("done"), @llm.Completed],
        content: "done",
        usage: { prompt_tokens: 1, completion_tokens: 1 },
        error: None,
      }),
      None,
      message,
      "Read this [File: notes.txt]",
      messages => {
        if messages == [message] {
          Ok([wire])
        } else {
          Err(@errors.internal_error("unexpected projection input", "test"))
        }
      },
      {
        chat_id: "canonical-chat",
        turn_id: "canonical-turn",
        user_message_id: "canonical-user",
        assistant_message_id: "canonical-assistant",
      },
      1,
      (_, _) => Err(@errors.internal_error("unexpected invocation", "test")),
      _ => (),
    ) {
    Err(error) => fail(error.message)
    Ok(result) => assert_eq(result.content, "done")
  }
  match @conversation.list_canonical(connection, "canonical-chat") {
    Ok(messages) => {
      assert_eq(messages.length(), 2)
      assert_eq(messages[0].message, message)
    }
    Err(error) => fail(error.message)
  }
  match @conversation.list_messages(connection, "canonical-chat", 10, 0) {
    Ok(messages) => {
      assert_eq(messages[0].kind, "multipart")
      assert_true(messages[0].content.contains("notes.txt"))
    }
    Err(error) => fail(error.message)
  }
  connection.close()
}

///|
async test "Create hook receives canonical input and persists its decision" {
  ignore(@async.now())
  let connection = @sqlite3.Connection::open(":memory:")
  ignore(@conversation.migrate(connection))
  let attachment : @attachment.Attachment = {
    id: "att_createabcdefghijkl",
    storage_key: "cr/att_createabcdefghijkl",
    filename: "pixel.png",
    media_type: "image/png",
    byte_size: 8,
    sha256: "digest",
    kind: @attachment.Image,
    status: "ready",
    created_at: 1,
    deleted_at: 0,
  }
  ignore(@attachment.insert(connection, attachment))
  let message : @content.Message = {
    role: @content.User,
    content: Some(
      @content.Parts([
        @content.TextPart("Describe"),
        @content.ImageRef(attachment.id, @content.Auto),
      ]),
    ),
    name: None,
    tool_call_id: None,
    reasoning_content: None,
    tool_calls: [],
    refusal: None,
  }
  let agent : Agent = {
    id: "todo",
    name: "Todo",
    description: "",
    connector: "default",
    options: { temperature: 0.2, max_tokens: 128 },
    prompts: [],
    tools: [],
    tool_names: [],
    create_process: "flows.create",
    next_process: "",
    before_process: "",
    after_process: "",
  }
  let mut saw_input = false
  let mut saw_projection = false
  let events : Array[@llm.CompletionEvent] = []
  match
    run_turn_message(
      connection,
      agent,
      {
        id: "default",
        connector_type: "openai_chat",
        base_url: "http://127.0.0.1:1/v1",
        api_key_env: "TEST_KEY",
        model: "fake",
        timeout_ms: 1000,
      },
      Client::Fake(fake_text_response("created")),
      None,
      message,
      "Describe [Image]",
      messages => {
        saw_projection = messages ==
          [@content.text_message(@content.User, "rewritten")]
        Ok([{ "role": "user", "content": "rewritten" }])
      },
      {
        chat_id: "create-chat",
        turn_id: "create-turn",
        user_message_id: "create-user",
        assistant_message_id: "create-assistant",
      },
      1,
      (process, input) => {
        saw_input = process == "flows.create" &&
          input.stringify().contains("\"version\":1") &&
          input.stringify().contains(attachment.id) &&
          input.stringify().contains("\"temperature\":0.2")
        Ok(
          (
            {
              "messages": [{ "role": "user", "content": "rewritten" }],
              "generation": { "temperature": 0.1, "max_tokens": 64 },
              "context": {
                "locale": "zh-CN",
                "metadata": { "source": "create-test" },
              },
            } : Json),
        )
      },
      event => events.push(event),
    ) {
    Ok(result) => assert_eq(result.content, "created")
    Err(error) => fail(error.message)
  }
  assert_true(saw_input)
  assert_true(saw_projection)
  assert_true(events.contains(@llm.HookStarted("create")))
  assert_true(events.contains(@llm.HookCompleted("create")))
  match @conversation.create_snapshot(connection, "create-turn") {
    Ok((context, decision)) => {
      assert_true(context.stringify().contains("\"locale\":\"zh-CN\""))
      assert_true(decision.stringify().contains("\"max_tokens\":64"))
    }
    Err(error) => fail(error.message)
  }
  connection.close()
}

///|
async test "Create Process failure finalizes the active turn once" {
  ignore(@async.now())
  let connection = @sqlite3.Connection::open(":memory:")
  ignore(@conversation.migrate(connection))
  let agent : Agent = {
    ..tool_test_agent(),
    tools: [],
    tool_names: [],
    create_process: "flows.create",
  }
  let events : Array[@llm.CompletionEvent] = []
  match
    run_turn(
      connection,
      agent,
      tool_test_connector(),
      Client::Fake(fake_text_response("unused")),
      None,
      "hello",
      tool_test_ids("create-failure"),
      1,
      (_, _) => Err(@errors.tool_error("Create failed")),
      event => events.push(event),
    ) {
    Err(error) => assert_eq(error.code, @errors.ToolError)
    Ok(_) => fail("expected Create failure")
  }
  match @conversation.active_turn_id(connection, "chat-create-failure") {
    Ok(value) => assert_eq(value, "")
    Err(error) => fail(error.message)
  }
  let mut failures = 0
  for event in events {
    if event is @llm.Failed(_) {
      failures = failures + 1
    }
  }
  assert_eq(failures, 1)
  connection.close()
}

///|
async test "twenty sequential turns leave no active turn" {
  ignore(@async.now())
  let connection = @sqlite3.Connection::open(":memory:")
  ignore(@conversation.migrate(connection))
  let agent : Agent = {
    id: "todo",
    name: "Todo",
    description: "",
    connector: "default",
    options: { temperature: 0.0, max_tokens: 32 },
    prompts: [{ role: @llm.System, content: "Be concise." }],
    tools: [],
    tool_names: [],
    create_process: "",
    next_process: "",
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
  for index = 1; index <= 20; index = index + 1 {
    let suffix = index.to_string()
    let response : FakeResponse = {
      events: [@llm.Started, @llm.TextDelta("ok"), @llm.Completed],
      content: "ok",
      usage: { prompt_tokens: index, completion_tokens: 1 },
      error: None,
    }
    match
      run_turn(
        connection,
        agent,
        connector,
        Client::Fake(response),
        if index == 1 {
          None
        } else {
          Some("smoke-chat")
        },
        "turn" + suffix,
        {
          chat_id: "smoke-chat",
          turn_id: "turn" + suffix,
          user_message_id: "user" + suffix,
          assistant_message_id: "assistant" + suffix,
        },
        index.to_int64(),
        (_, _) => Err(@errors.internal_error("unexpected invocation", "test")),
        _ => (),
      ) {
      Ok(result) => assert_eq(result.content, "ok")
      Err(error) => fail(error.message)
    }
  }
  match @conversation.completed_messages(connection, "smoke-chat") {
    Ok(messages) => assert_eq(messages.length(), 40)
    Err(error) => fail(error.message)
  }
  match @conversation.active_turn_id(connection, "smoke-chat") {
    Ok(value) => assert_eq(value, "")
    Err(error) => fail(error.message)
  }
  connection.close()
}

///|
async fn run_concurrent_chat_smoke(suffix : String) -> Unit {
  let connection = @sqlite3.Connection::open(":memory:")
  ignore(@conversation.migrate(connection))
  let response : FakeResponse = {
    events: [@llm.Started, @llm.TextDelta("ok-" + suffix), @llm.Completed],
    content: "ok-" + suffix,
    usage: { prompt_tokens: 1, completion_tokens: 1 },
    error: None,
  }
  match
    run_turn(
      connection,
      {
        id: "todo",
        name: "Todo",
        description: "",
        connector: "default",
        options: { temperature: 0.0, max_tokens: 32 },
        prompts: [],
        tools: [],
        tool_names: [],
        create_process: "",
        next_process: "",
        before_process: "",
        after_process: "",
      },
      tool_test_connector(),
      Client::Fake(response),
      None,
      "hello-" + suffix,
      tool_test_ids(suffix),
      1,
      (_, _) => Err(@errors.internal_error("unexpected invocation", "test")),
      _ => (),
    ) {
    Ok(result) => assert_eq(result.content, "ok-" + suffix)
    Err(error) => fail(error.message)
  }
  connection.close()
}

///|
async test "different chats can complete concurrently" {
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => { run_concurrent_chat_smoke("a") }
    group.spawn_bg() <| () => { run_concurrent_chat_smoke("b") }
  }
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
    create_process: "",
    next_process: "",
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
    create_process: "",
    next_process: "",
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
  fake_tool_response_with_id("call-1", arguments)
}

///|
fn fake_tool_response_with_id(id : String, arguments : String) -> FakeResponse {
  let call : @llm.ToolCall = {
    id,
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
async test "synchronous Process cancellation is reported and discards its result" {
  ignore(@async.now())
  let connection = @sqlite3.Connection::open(":memory:")
  ignore(@conversation.migrate(connection))
  let cancellation = TurnCancellation::new()
  let events : Array[@llm.CompletionEvent] = []
  match
    run_turn_controlled(
      connection,
      tool_test_agent(),
      tool_test_connector(),
      Client::Fake(fake_tool_response("{\"data\":{\"title\":\"cancel me\"}}")),
      None,
      "Create and cancel",
      tool_test_ids("soft-cancel"),
      1,
      {
        ..default_turn_execution_options(),
        cancellation,
        deadline_at: @env.now().reinterpret_as_int64() + 5000,
        metadata: {},
      },
      (_, _) => {
        cancellation.request(@env.now().reinterpret_as_int64())
        Ok(({ "id": 1 } : Json))
      },
      event => events.push(event),
    ) {
    Err(error) => assert_eq(error.code, @errors.TurnCancelled)
    Ok(_) => fail("expected soft cancellation")
  }
  let turn = @conversation.get_turn(connection, "turnsoft-cancel").unwrap()
  assert_eq(turn.status, "cancelled")
  assert_true(
    events.contains(@llm.CancellationPendingProcess("models.todo.Create")),
  )
  assert_eq(events.filter(event => event is @llm.Cancelled).length(), 1)
  let final_messages = connection.prepare(
    "SELECT COUNT(*) FROM _moonyao_messages WHERE turn_id = 'turnsoft-cancel' AND role = 'assistant' AND kind = 'text'",
  )
  ignore(final_messages.step())
  let final_count : Int = final_messages.column(index=0)
  final_messages.finalize()
  assert_eq(final_count, 0)
  connection.close()
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
async test "model can repair invalid tool arguments after a tool error" {
  ignore(@async.now())
  let connection = @sqlite3.Connection::open(":memory:")
  ignore(@conversation.migrate(connection))
  let mut invoked = 0
  match
    run_turn(
      connection,
      tool_test_agent(),
      tool_test_connector(),
      Client::FakeSequence([
        fake_tool_response("{}"),
        fake_tool_response_with_id(
          "call-2", "{\"data\":{\"title\":\"repaired\"}}",
        ),
        fake_text_response("Created after correction."),
      ]),
      None,
      "Create one",
      tool_test_ids("2"),
      1,
      (_, _) => {
        invoked = invoked + 1
        Ok(({ "id": 1, "title": "repaired" } : Json))
      },
      _ => (),
    ) {
    Ok(result) => assert_eq(result.content, "Created after correction.")
    Err(error) => fail(error.message)
  }
  assert_eq(invoked, 1)
  connection.close()
}

///|
fn multi_tool_agent() -> Agent {
  {
    ..tool_test_agent(),
    tools: [
      {
        name: "create_todo",
        description: "create_todo",
        process: "models.todo.Create",
        input_schema: {
          "type": "object",
          "properties": {
            "data": {
              "type": "object",
              "properties": { "title": { "type": "string" } },
              "required": ["title"],
              "additionalProperties": false,
            },
          },
          "required": ["data"],
          "additionalProperties": false,
        },
      },
      {
        name: "list_todos",
        description: "list_todos",
        process: "models.todo.List",
        input_schema: {
          "type": "object",
          "properties": {},
          "additionalProperties": false,
        },
      },
      {
        name: "complete_todo",
        description: "complete_todo",
        process: "models.todo.Update",
        input_schema: {
          "type": "object",
          "properties": {
            "id": { "type": "integer" },
            "data": {
              "type": "object",
              "properties": { "done": { "type": "boolean" } },
              "required": ["done"],
              "additionalProperties": false,
            },
          },
          "required": ["id", "data"],
          "additionalProperties": false,
        },
      },
      {
        name: "delete_todo",
        description: "delete_todo",
        process: "models.todo.Delete",
        input_schema: {
          "type": "object",
          "properties": { "id": { "type": "integer" } },
          "required": ["id"],
          "additionalProperties": false,
        },
      },
    ],
    tool_names: ["create_todo", "list_todos", "complete_todo", "delete_todo"],
  }
}

///|
async test "multiple Todo tools preserve order and call ids" {
  ignore(@async.now())
  let connection = @sqlite3.Connection::open(":memory:")
  ignore(@conversation.migrate(connection))
  let calls : Array[@llm.ToolCall] = [
    {
      id: "create-1",
      name: "create_todo",
      arguments_json: "{\"data\":{\"title\":\"ship\"}}",
    },
    { id: "list-1", name: "list_todos", arguments_json: "{}" },
    {
      id: "complete-1",
      name: "complete_todo",
      arguments_json: "{\"id\":1,\"data\":{\"done\":true}}",
    },
    { id: "delete-1", name: "delete_todo", arguments_json: "{\"id\":1}" },
  ]
  let events : Array[@llm.CompletionEvent] = [@llm.Started]
  for call in calls {
    events.push(@llm.ToolCallCompleted(call))
  }
  events.push(@llm.Completed)
  let processes : Array[String] = []
  let completed_ids : Array[String] = []
  match
    run_turn(
      connection,
      multi_tool_agent(),
      tool_test_connector(),
      Client::FakeSequence([
        {
          events,
          content: "",
          usage: { prompt_tokens: 4, completion_tokens: 1 },
          error: None,
        },
        fake_text_response("Finished all four operations."),
      ]),
      None,
      "Create, list, complete, and delete one Todo",
      tool_test_ids("multi"),
      1,
      (process, _) => {
        processes.push(process)
        Ok(({ "ok": true } : Json))
      },
      event => {
        match event {
          @llm.ToolCompleted(id, _, _, _) => completed_ids.push(id)
          _ => ()
        }
      },
    ) {
    Ok(result) => assert_eq(result.content, "Finished all four operations.")
    Err(error) => fail(error.message)
  }
  assert_eq(processes, [
    "models.todo.Create", "models.todo.List", "models.todo.Update", "models.todo.Delete",
  ])
  assert_eq(completed_ids, ["create-1", "list-1", "complete-1", "delete-1"])
  match @conversation.completed_messages(connection, "chatmulti") {
    Ok(messages) => assert_eq(messages.length(), 7)
    Err(error) => fail(error.message)
  }
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
    create_process: "",
    next_process: "",
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
async test "Next hook receives tool results and returns persisted custom data" {
  ignore(@async.now())
  let connection = @sqlite3.Connection::open(":memory:")
  ignore(@conversation.migrate(connection))
  let agent : Agent = { ..tool_test_agent(), next_process: "flows.next" }
  let mut saw_next = false
  let events : Array[@llm.CompletionEvent] = []
  match
    run_turn(
      connection,
      agent,
      tool_test_connector(),
      Client::FakeSequence([
        fake_tool_response("{\"data\":{\"title\":\"from next\"}}"),
        fake_text_response("standard answer"),
      ]),
      None,
      "create one",
      tool_test_ids("next"),
      1,
      (process, input) => {
        if process == "flows.next" {
          let source = input.stringify()
          saw_next = source.contains("\"version\":1") &&
            source.contains("\"tool_call_id\":\"call-1\"") &&
            source.contains("\"title\":\"from next\"") &&
            source.contains("\"result\":{\"id\":1}")
          Ok(
            (
              {
                "action": "data",
                "data": {
                  "answer": "custom answer",
                  "ui": { "kind": "notice" },
                },
                "metadata": { "next": true },
              } : Json),
          )
        } else {
          Ok(({ "id": 1 } : Json))
        }
      },
      event => events.push(event),
    ) {
    Ok(result) => {
      assert_eq(result.content, "standard answer")
      assert_eq(
        result.next,
        Some(({ "answer": "custom answer", "ui": { "kind": "notice" } } : Json)),
      )
    }
    Err(error) => fail(error.message)
  }
  assert_true(saw_next)
  assert_true(events.contains(@llm.HookStarted("next")))
  assert_true(events.contains(@llm.HookCompleted("next")))
  match @conversation.next_snapshot(connection, "turnnext") {
    Ok((context, decision)) => {
      assert_true(context.stringify().contains("\"next\":true"))
      assert_true(decision.stringify().contains("custom answer"))
    }
    Err(error) => fail(error.message)
  }
  let journal = @conversation.list_events(connection, "turnnext", 0, 100).unwrap()
  assert_eq(journal.last().unwrap().event, "turn.completed")
  assert_true(
    journal.last().unwrap().data.stringify().contains("custom answer"),
  )
  connection.close()
}

///|
async test "Next Process failure does not persist a completed assistant message" {
  ignore(@async.now())
  let connection = @sqlite3.Connection::open(":memory:")
  ignore(@conversation.migrate(connection))
  let agent : Agent = {
    ..tool_test_agent(),
    tools: [],
    tool_names: [],
    next_process: "flows.next",
  }
  match
    run_turn(
      connection,
      agent,
      tool_test_connector(),
      Client::Fake(fake_text_response("generated but rejected")),
      None,
      "hello",
      tool_test_ids("next-failure"),
      1,
      (_, _) => Err(@errors.tool_error("Next failed")),
      _ => (),
    ) {
    Err(error) => assert_eq(error.code, @errors.ToolError)
    Ok(_) => fail("expected Next failure")
  }
  match @conversation.active_turn_id(connection, "chatnext-failure") {
    Ok(value) => assert_eq(value, "")
    Err(error) => fail(error.message)
  }
  match @conversation.list_messages(connection, "chatnext-failure", 10, 0) {
    Ok(messages) => {
      assert_eq(messages.length(), 1)
      assert_eq(messages[0].role, "user")
    }
    Err(error) => fail(error.message)
  }
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
