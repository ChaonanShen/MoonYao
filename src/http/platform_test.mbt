///|
fn platform_agent() -> @agent.Agent {
  {
    id: "todo",
    name: "Todo Assistant",
    description: "Manages tasks.",
    connector: "default",
    options: { temperature: 0.7, max_tokens: 99 },
    prompts: [{ role: @llm.System, content: "private prompt" }],
    tools: [
      {
        name: "create_todo",
        description: "Create a task.",
        process: "models.todo.Create",
        input_schema: { "type": "object" },
      },
    ],
    tool_names: ["create_todo"],
    create_process: "",
    next_process: "",
    before_process: "flows.private",
    after_process: "",
  }
}

///|
test "platform metadata is public and redacted" {
  let agent = platform_agent()
  let encoded = agent_json(agent).stringify()
  assert_true(encoded.contains("create_todo"))
  assert_false(encoded.contains("private prompt"))
  assert_false(encoded.contains("models.todo.Create"))
  assert_false(encoded.contains("temperature"))
  assert_false(encoded.contains("before_process"))
}

///|
test "platform dispatcher implements agent and chat APIs" {
  let connection = @sqlite3.Connection::open(":memory:")
  match @conversation.migrate(connection) {
    Err(error) => fail(error.message)
    Ok(_) => ()
  }
  let agents = [platform_agent()]
  let empty : Map[String, String] = Map([])
  match
    dispatch_platform(
      agents,
      connection,
      "GET",
      "/v1/health",
      {},
      empty,
      "unused",
      1,
    ) {
    Ok(Some(Response(value))) => {
      assert_eq(value.status, 200)
      assert_true(value.body.contains("\"ready\":true"))
    }
    _ => fail("expected health response")
  }
  assert_true(
    dispatch_platform(
      agents,
      connection,
      "GET",
      "/v1-custom",
      {},
      empty,
      "unused",
      1,
    )
    is Ok(None),
  )
  match
    dispatch_platform(
      agents,
      connection,
      "POST",
      "/v1/chats",
      { "agent_id": "todo", "title": "" },
      empty,
      "chat",
      1700000000000,
    ) {
    Ok(Some(Response(value))) => {
      assert_eq(value.status, 201)
      assert_true(value.body.contains("\"id\":\"chat\""))
      assert_true(value.body.contains("\"created_at\":1700000000000"))
    }
    _ => fail("expected create response")
  }
  match
    dispatch_platform(
      agents,
      connection,
      "GET",
      "/v1/chats",
      {},
      { "agent_id": "todo", "limit": "20", "offset": "0" },
      "unused",
      3,
    ) {
    Ok(Some(Response(value))) => assert_true(value.body.contains("\"total\":1"))
    _ => fail("expected chat list")
  }
  match
    dispatch_platform(
      agents,
      connection,
      "PATCH",
      "/v1/chats/chat",
      { "title": "Renamed" },
      empty,
      "unused",
      4,
    ) {
    Ok(Some(Response(value))) => assert_true(value.body.contains("Renamed"))
    _ => fail("expected rename response")
  }
  match
    dispatch_platform(
      agents,
      connection,
      "POST",
      "/v1/chats/chat/turns",
      { "content": "hello" },
      empty,
      "unused",
      5,
    ) {
    Ok(Some(Turn(id, content))) => {
      assert_eq(id, "chat")
      assert_eq(content.preview, "hello")
      assert_false(content.canonical)
    }
    _ => fail("expected turn action")
  }
  ignore(
    @conversation.begin_turn(connection, "turn", "user", "chat", "hello", 5),
  )
  match
    dispatch_platform(
      agents,
      connection,
      "GET",
      "/v1/turns/turn",
      {},
      empty,
      "unused",
      5,
    ) {
    Ok(Some(Response(value))) => {
      assert_eq(value.status, 200)
      assert_true(value.body.contains("\"status\":\"active\""))
    }
    _ => fail("expected turn status response")
  }
  match
    dispatch_platform(
      agents,
      connection,
      "POST",
      "/v1/turns/turn/cancel",
      {},
      empty,
      "unused",
      5,
    ) {
    Ok(Some(CancelTurn(id))) => assert_eq(id, "turn")
    _ => fail("expected cancel action")
  }
  match
    dispatch_platform(
      agents,
      connection,
      "DELETE",
      "/v1/chats/chat",
      {},
      empty,
      "unused",
      6,
    ) {
    Err(error) => assert_eq(error.code, @errors.TurnConflict)
    _ => fail("expected active turn conflict")
  }
  match
    dispatch_platform(
      agents,
      connection,
      "GET",
      "/v1/chats/chat/messages",
      {},
      { "include_internal": "true" },
      "unused",
      6,
    ) {
    Err(error) => assert_eq(error.path, "query.include_internal")
    _ => fail("expected internal transcript rejection")
  }
  connection.close()
}

///|
test "platform inputs and pagination are strict" {
  assert_eq(status_code(@errors.llm_error("provider request timed out")), 504)
  assert_eq(status_code(@errors.llm_error("provider returned HTTP 500")), 502)
  match pagination({ "limit": "20", "offset": "2" }, ["limit", "offset"]) {
    Ok((limit, offset)) => {
      assert_eq(limit, 20)
      assert_eq(offset, 2)
    }
    Err(error) => fail(error.message)
  }
  match pagination({ "limit": "0" }, ["limit"]) {
    Err(error) => assert_eq(error.path, "query.limit")
    Ok(_) => fail("expected invalid limit")
  }
  match create_chat_input({ "agent_id": "todo", "extra": true }) {
    Err(error) => assert_eq(error.path, "body.extra")
    Ok(_) => fail("expected unknown body field")
  }
  match turn_input({ "content": "hello" }) {
    Ok(content) => {
      assert_eq(content.preview, "hello")
      assert_false(content.canonical)
      assert_eq(content.timeout_ms, 300000)
      assert_eq(content.metadata, Json::object(Map([])))
    }
    Err(error) => fail(error.message)
  }
  match rename_chat_input({ "title": "月".repeat(200) }) {
    Ok(title) => assert_eq(title.length(), 200)
    Err(error) => fail(error.message)
  }
  match turn_input({ "content": "月".repeat(21846) }) {
    Err(error) => assert_eq(error.path, "body.content")
    Ok(_) => fail("expected UTF-8 byte limit")
  }
  match
    turn_input({
      "content": "hello",
      "options": { "timeout_ms": 120000, "metadata": { "source": "test" } },
    }) {
    Ok(content) => {
      assert_eq(content.timeout_ms, 120000)
      assert_eq(content.metadata, ({ "source": "test" } : Json))
    }
    Err(error) => fail(error.message)
  }
  for invalid in [999, 300001] {
    match
      turn_input({ "content": "hello", "options": { "timeout_ms": invalid } }) {
      Err(error) => assert_eq(error.path, "body.options.timeout_ms")
      Ok(_) => fail("expected timeout bound rejection")
    }
  }
  match
    turn_input({ "content": "hello", "options": { "metadata": "private" } }) {
    Err(error) => assert_eq(error.path, "body.options.metadata")
    Ok(_) => fail("expected metadata object")
  }
  let first = turn_input({
    "content": "hello",
    "options": { "metadata": { "b": 2, "a": 1 } },
  }).unwrap()
  let second = turn_input({
    "options": { "metadata": { "a": 1, "b": 2 } },
    "content": "hello",
  }).unwrap()
  assert_eq(turn_request_hash(first, ""), turn_request_hash(second, ""))
  match validate_idempotency_key("turn:client_1-2.3") {
    Ok(_) => ()
    Err(error) => fail(error.message)
  }
  for invalid in ["", "bad key", "x".repeat(129)] {
    match validate_idempotency_key(invalid) {
      Err(error) => assert_eq(error.path, "headers.idempotency-key")
      Ok(_) => fail("expected invalid idempotency key")
    }
  }
  match event_cursor("-1", "query.after") {
    Err(error) => assert_eq(error.path, "query.after")
    Ok(_) => fail("expected invalid event cursor")
  }
  assert_eq(
    turn_event_cursor("turn:3", "turn", "headers.last-event-id").unwrap(),
    3,
  )
  match turn_event_cursor("other:3", "turn", "headers.last-event-id") {
    Err(error) => assert_eq(error.path, "headers.last-event-id")
    Ok(_) => fail("expected cross-turn cursor rejection")
  }
}

///|
test "platform dispatches retry and event replay actions safely" {
  let connection = @sqlite3.Connection::open(":memory:")
  ignore(@conversation.migrate(connection))
  ignore(@conversation.create_chat(connection, "chat", "todo", "Retry", 1))
  ignore(
    @conversation.begin_turn(connection, "failed", "user", "chat", "hello", 2),
  )
  ignore(
    @conversation.fail_turn(connection, "failed", "llm_error", "failed", 3),
  )
  match
    dispatch_platform(
      [platform_agent()],
      connection,
      "POST",
      "/v1/turns/failed/retry",
      {},
      Map([]),
      "unused",
      4,
    ) {
    Ok(Some(RetryTurn(id))) => assert_eq(id, "failed")
    _ => fail("expected retry action")
  }
  match
    dispatch_platform(
      [platform_agent()],
      connection,
      "GET",
      "/v1/turns/failed/events",
      {},
      { "after": "1" },
      "unused",
      4,
    ) {
    Ok(Some(ReplayEvents(id, after))) => {
      assert_eq(id, "failed")
      assert_eq(after, 1)
    }
    _ => fail("expected event replay action")
  }
  ignore(
    @conversation.begin_turn(
      connection, "active", "active-user", "chat", "hi", 5,
    ),
  )
  match
    dispatch_platform(
      [platform_agent()],
      connection,
      "POST",
      "/v1/turns/active/retry",
      {},
      Map([]),
      "unused",
      6,
    ) {
    Err(error) => assert_eq(error.path, "turn.retry")
    _ => fail("expected active retry rejection")
  }
  connection.close()
}

///|
test "platform accepts canonical turns and attachment routes" {
  let connection = @sqlite3.Connection::open(":memory:")
  match @conversation.migrate(connection) {
    Err(error) => fail(error.message)
    Ok(_) => ()
  }
  let canonical : Json = {
    "message": {
      "role": "user",
      "content": [
        { "type": "text", "text": "Describe this" },
        {
          "type": "image",
          "attachment_id": "att_abcdefghijklmnopqrst",
          "detail": "auto",
        },
      ],
    },
  }
  match turn_input(canonical) {
    Ok(content) => {
      assert_true(content.canonical)
      assert_true(content.preview.contains("Describe this"))
      assert_true(content.preview.contains("[Image]"))
    }
    Err(error) => fail(error.message)
  }
  match turn_input({ "content": "hello", "message": {} }) {
    Err(error) => assert_eq(error.path, "body")
    Ok(_) => fail("expected mutually exclusive turn input")
  }
  match
    dispatch_platform(
      [platform_agent()],
      connection,
      "POST",
      "/v1/attachments",
      {
        "filename": "note.txt",
        "media_type": "text/plain",
        "data_base64": "aGVsbG8=",
      },
      Map([]),
      "upload",
      7,
    ) {
    Ok(Some(UploadAttachment(filename, media_type, data, id))) => {
      assert_eq(filename, "note.txt")
      assert_eq(media_type, "text/plain")
      assert_eq(data, b"hello")
      assert_eq(id, "att_upload")
    }
    _ => fail("expected attachment upload action")
  }
  match
    dispatch_platform(
      [platform_agent()],
      connection,
      "POST",
      "/v1/attachments",
      {
        "filename": "note.txt",
        "media_type": "text/plain",
        "data_base64": "not base64",
      },
      Map([]),
      "upload",
      7,
    ) {
    Err(error) => assert_eq(error.path, "body.data_base64")
    _ => fail("expected invalid base64 rejection")
  }
  let attachment : @attachment.Attachment = {
    id: "att_abcdefghijklmnopqrst",
    storage_key: "abcdefghijklmnopqrst",
    filename: "note.txt",
    media_type: "text/plain",
    byte_size: 5,
    sha256: "digest",
    kind: @attachment.Text,
    status: "ready",
    created_at: 8,
    deleted_at: 0,
  }
  match @attachment.insert(connection, attachment) {
    Err(error) => fail(error.message)
    Ok(_) => ()
  }
  match
    dispatch_platform(
      [platform_agent()],
      connection,
      "GET",
      "/v1/attachments/att_abcdefghijklmnopqrst",
      {},
      Map([]),
      "unused",
      9,
    ) {
    Ok(Some(Response(value))) => {
      assert_eq(value.status, 200)
      assert_true(value.body.contains("\"filename\":\"note.txt\""))
      assert_false(value.body.contains("storage_key"))
    }
    _ => fail("expected attachment metadata response")
  }
  connection.close()
}

///|
test "SSE frames escape data and expose only public runtime events" {
  let frame = sse_frame(3, "message.delta", { "delta": "a\nb" })
  assert_true(frame.has_prefix("id: 3\nevent: message.delta\n"))
  assert_true(frame.contains("a\\nb"))
  assert_eq(heartbeat(), ": heartbeat\n\n")
  match public_event(@llm.TextDelta("hi"), 2, "chat", "turn", "message") {
    Some((name, data)) => {
      assert_eq(name, "message.delta")
      assert_true(data.stringify().contains("\"sequence\":2"))
    }
    None => fail("expected public event")
  }
  match
    public_event(
      @llm.ProviderRetrying(2, 3, 100, "server_error"),
      3,
      "chat",
      "turn",
      "message",
    ) {
    Some((name, data)) => {
      assert_eq(name, "provider.retrying")
      assert_true(data.stringify().contains("\"attempt\":2"))
      assert_true(data.stringify().contains("\"reason\":\"server_error\""))
    }
    None => fail("expected provider retry event")
  }
  assert_true(
    public_event(
      @llm.ToolArgumentsDelta(0, "secret"),
      2,
      "chat",
      "turn",
      "message",
    )
    is None,
  )
  assert_true(public_event(@llm.Started, 1, "chat", "turn", "message") is None)
}

///|
test "embedded CUI uses safe DOM rendering and no external build chain" {
  assert_true(agent_html.contains("/agent/app.js"))
  assert_true(agent_css.contains("@media"))
  assert_true(agent_js.contains("textContent"))
  assert_false(agent_js.contains("innerHTML"))
  assert_true(agent_js.contains("event.key===\"Enter\"&&!event.shiftKey"))
  assert_true(agent_js.contains("!event.isComposing"))
  assert_true(agent_js.contains("requestSubmit()"))
  assert_true(agent_html.contains("attachment-input"))
  assert_true(agent_html.contains("cancel-turn"))
  assert_true(agent_html.contains("retry-turn"))
  assert_true(agent_js.contains("/v1/attachments"))
  assert_true(agent_js.contains("data_base64"))
  assert_true(agent_js.contains("const message={role:\"user\",content:parts}"))
  assert_true(agent_js.contains("Idempotency-Key"))
  assert_true(agent_js.contains("/events?after=${state.lastSequence}"))
  assert_true(agent_js.contains("sequence<=state.lastSequence"))
  assert_true(agent_js.contains("error.status&&error.status<500"))
  assert_true(
    agent_js.contains("state.activeTurnId=turnId;setBusy(true,\"Running\")"),
  )
  assert_true(agent_js.contains("/cancel"))
  assert_true(agent_js.contains("/retry"))
  assert_true(agent_js.contains("Retry may repeat Process side effects"))
  assert_true(agent_js.contains("files.length>8"))
  assert_false(agent_html.contains("https://"))
  assert_false(agent_js.contains("https://"))
}
