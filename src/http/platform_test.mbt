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
      assert_eq(content, "hello")
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
    Ok(content) => assert_eq(content, "hello")
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
  assert_true(
    agent_js.contains(
      "catch(error){await openChat(state.chatId).catch(()=>{});showError(error)}",
    ),
  )
  assert_false(agent_html.contains("https://"))
  assert_false(agent_js.contains("https://"))
}
