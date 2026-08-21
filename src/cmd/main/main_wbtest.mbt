///|
test "check is side-effect free while migrate and run use the configured database" {
  let app_dir = "testdata/apps/cli-sandbox"
  let database = app_dir + "/todo.db"
  if @fs.path_exists(database) {
    @fs.remove_file(database)
  }
  match execute(["check", app_dir]) {
    Ok(output) => assert_true(output.has_prefix("checked application"))
    Err(error) => abort(error.message)
  }
  assert_false(@fs.path_exists(database))
  match execute(["migrate", app_dir]) {
    Ok(output) => assert_true(output.contains("\"migrated\":1"))
    Err(error) => abort(error.message)
  }
  assert_true(@fs.path_exists(database))
  let created = match
    execute([
      "run", app_dir, "models.todo.Create", "{\"data\":{\"title\":\"from cli\"}}",
    ]) {
    Ok(output) => output
    Err(error) => abort(error.message)
  }
  assert_true(created.contains("\"title\":\"from cli\""))
  let flowed = match
    execute([
      "run", app_dir, "flows.create_todo", "{\"body\":{\"title\":\"from flow\"}}",
    ]) {
    Ok(output) => output
    Err(error) => abort(error.message)
  }
  assert_true(flowed.contains("\"title\":\"from flow\""))
  match execute(["run", app_dir, "models.todo.Find", "{\"id\":999}"]) {
    Err(error) => assert_eq(error.code, @errors.RecordNotFound)
    Ok(_) => abort("expected missing record")
  }
  @fs.remove_file(database)
}

///|
test "CLI rejects invalid JSON and unsupported command shapes" {
  match execute(["run", "testdata/apps/cli-sandbox", "models.todo.List", "{"]) {
    Err(error) => assert_eq(error.code, @errors.InvalidArgument)
    Ok(_) => abort("expected invalid JSON")
  }
  match execute(["migrate"]) {
    Err(error) => assert_eq(error.code, @errors.InvalidArgument)
    Ok(_) => abort("expected usage error")
  }
}

///|
fn tcp_test_agent() -> @agent.Agent {
  {
    id: "todo",
    name: "Todo Assistant",
    description: "Manages tasks.",
    connector: "default",
    options: { temperature: 0.0, max_tokens: 32 },
    prompts: [{ role: @llm.System, content: "private" }],
    tools: [],
    tool_names: [],
    create_process: "",
    next_process: "",
    before_process: "",
    after_process: "",
  }
}

///|
async test "platform responses cross real TCP with security headers" {
  @async.with_task_group() <| group => {
    let server = @asynchttp.Server(@socket.Addr::parse("127.0.0.1:0"))
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever(allow_failure=true) <| ((request, _, connection) => {
        if request.path == "/unicode" {
          send_platform_response(
            connection,
            {
              status: 200,
              content_type: "text/plain; charset=utf-8",
              body: "你好",
              location: "",
            },
            "request-id",
          )
          return
        }
        let database = @sqlite3.Connection::open(":memory:")
        ignore(@conversation.migrate(database))
        let action = @moonhttp.dispatch_platform(
          [tcp_test_agent()],
          database,
          request_verb(request.meth),
          request.path,
          {},
          Map([]),
          "new-chat",
          1,
        )
        match action {
          Ok(Some(@moonhttp.Response(response))) =>
            send_platform_response(connection, response, "request-id")
          Err(error) => send_platform_error(connection, error, "request-id")
          _ =>
            send_platform_error(
              connection,
              @errors.route_not_found(request.path),
              "request-id",
            )
        }
        database.close()
      })
    }
    let base = "http://127.0.0.1:" + server.addr.port().to_string()
    let (health, health_body) = @asynchttp.get(base + "/v1/health")
    assert_eq(health.code, 200)
    assert_true(health_body.text().contains("\"ready\":true"))
    assert_eq(health.headers.get("x-request-id"), Some("request-id"))
    assert_eq(health.headers.get("x-content-type-options"), Some("nosniff"))
    assert_eq(health.headers.get("referrer-policy"), Some("no-referrer"))
    assert_true(
      health.headers
      .get("content-security-policy")
      .unwrap()
      .contains("frame-ancestors 'none'"),
    )
    assert_eq(health.headers.get("access-control-allow-origin"), None)
    let (page, page_body) = @asynchttp.get(base + "/agent/")
    assert_eq(page.code, 200)
    assert_true(
      page.headers.get("content-type").unwrap().has_prefix("text/html"),
    )
    assert_true(page_body.text().contains("MoonYao Agent"))
    let (unicode, unicode_body) = @asynchttp.get(base + "/unicode")
    assert_eq(unicode.code, 200)
    assert_eq(unicode.headers.get("content-length"), Some("6"))
    assert_eq(unicode_body.text(), "你好")
    server.close()
  }
}

///|
async test "HTTP turns stream public events and persist completion" {
  @async.with_task_group() <| group => {
    let provider = @asynchttp.Server(@socket.Addr::parse("127.0.0.1:0"))
    let provider_requests = Ref(0)
    group.spawn_bg(no_wait=true) <| () => {
      provider.run_forever(allow_failure=true) <| ((_, body, connection) => {
        provider_requests.val = provider_requests.val + 1
        ignore(body.read_all())
        connection.send_response(200, "OK", extra_headers={
          "Content-Type": "text/event-stream",
        })
        connection.write_string(
          "data: {\"choices\":[{\"delta\":{\"content\":\"hel\"}}]}\n\n",
        )
        connection.flush()
        @async.sleep(20)
        connection.write_string(
          "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\ndata: {\"choices\":[],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":1}}\n\ndata: [DONE]\n\n",
        )
        connection.end_response()
      })
    }
    let connector : @llm.Connector = {
      id: "default",
      connector_type: "openai_chat",
      base_url: "http://127.0.0.1:" + provider.addr.port().to_string(),
      api_key_env: "MOONYAO_P7_TEST_KEY",
      model: "fake",
      timeout_ms: 1000,
    }
    @env.set_env_var("MOONYAO_P7_TEST_KEY", "test-key")
    defer @env.unset_env_var("MOONYAO_P7_TEST_KEY")
    let application : @app.Application = {
      name: "test",
      database: "",
      models: [],
      flows: [],
      globals: Map([]),
      apis: [],
      listen: "127.0.0.1:0",
      connectors: [connector],
      agents: [tcp_test_agent()],
    }
    let database = @sqlite3.Connection::open(":memory:")
    ignore(@conversation.migrate(database))
    ignore(
      @conversation.create_chat(database, "stream-chat", "todo", "Stream", 1),
    )
    ignore(@conversation.create_chat(database, "json-chat", "todo", "JSON", 1))
    ignore(
      @conversation.create_chat(database, "openai-chat", "todo", "OpenAI", 1),
    )
    ignore(
      @conversation.create_chat(
        database, "idempotent-chat", "todo", "Idempotent", 1,
      ),
    )
    ignore(
      @conversation.create_chat(
        database, "disconnect-chat", "todo", "Disconnect", 1,
      ),
    )
    let platform = @asynchttp.Server(@socket.Addr::parse("127.0.0.1:0"))
    group.spawn_bg(no_wait=true) <| () => {
      platform.run_forever(allow_failure=true) <| ((request, body, connection) => {
        ignore(body.read_all())
        if request.path == "/resume" {
          let turn = @conversation.get_turn_by_idempotency(
              database, "idempotent-chat", "same-key",
            )
            .unwrap()
            .unwrap()
          stream_turn_events(database, turn.id, 1, connection, "resume-request")
          return
        }
        let stream = request.path == "/stream" ||
          request.path == "/disconnect" ||
          request.path == "/openai-stream"
        run_http_turn(
          application,
          database,
          if request.path == "/stream" {
            "stream-chat"
          } else if request.path == "/openai" ||
            request.path == "/openai-stream" {
            "openai-chat"
          } else if request.path == "/disconnect" {
            "disconnect-chat"
          } else if request.path == "/idempotent" ||
            request.path == "/idempotent-conflict" {
            "idempotent-chat"
          } else {
            "json-chat"
          },
          @moonhttp.turn_input({
            "content": if request.path == "/idempotent-conflict" {
              "different"
            } else {
              "hello"
            },
          }).unwrap(),
          "/unused-attachments",
          stream,
          if request.path == "/idempotent" ||
            request.path == "/idempotent-conflict" {
            "same-key"
          } else {
            ""
          },
          "",
          if request.path == "/openai" || request.path == "/openai-stream" {
            Some("todo")
          } else {
            None
          },
          connection,
          "turn-request",
          @agent.TurnSupervisor::new(),
          group,
        )
      })
    }
    let base = "http://127.0.0.1:" + platform.addr.port().to_string()
    let (stream_response, stream_body) = @asynchttp.post(
      base + "/stream",
      "{}",
      headers={ "Content-Type": "application/json" },
    )
    let events = stream_body.text()
    assert_eq(stream_response.code, 200)
    assert_true(
      stream_response.headers
      .get("content-type")
      .unwrap()
      .has_prefix("text/event-stream"),
    )
    assert_true(events.contains("event: turn.started"))
    assert_true(events.contains("event: message.delta"))
    assert_true(events.contains("event: message.completed"))
    assert_true(events.contains("event: turn.completed"))
    assert_true(events.contains("\"next\":null"))
    assert_false(events.contains("tool.arguments.delta"))
    let (json_response, json_body) = @asynchttp.post(base + "/json", "{}", headers={
      "Content-Type": "application/json",
    })
    assert_eq(json_response.code, 200)
    assert_true(json_body.text().contains("\"content\":\"hello\""))
    assert_true(json_body.text().contains("\"next\":null"))
    let (openai_response, openai_body) = @asynchttp.post(
      base + "/openai",
      "{}",
      headers={ "Content-Type": "application/json" },
    )
    assert_eq(openai_response.code, 200)
    assert_true(openai_body.text().contains("\"object\":\"chat.completion\""))
    assert_true(openai_body.text().contains("\"role\":\"assistant\""))
    assert_true(openai_body.text().contains("\"total_tokens\":3"))
    let (openai_stream_response, openai_stream_body) = @asynchttp.post(
      base + "/openai-stream",
      "{}",
      headers={ "Content-Type": "application/json" },
    )
    assert_eq(openai_stream_response.code, 200)
    assert_true(openai_stream_body.text().contains("chat.completion.chunk"))
    assert_true(openai_stream_body.text().contains("data: [DONE]"))
    let before_idempotent = provider_requests.val
    let (first_idempotent, _) = @asynchttp.post(base + "/idempotent", "{}", headers={
      "Content-Type": "application/json",
    })
    assert_eq(first_idempotent.code, 200)
    let (second_idempotent, second_body) = @asynchttp.post(
      base + "/idempotent",
      "{}",
      headers={ "Content-Type": "application/json" },
    )
    assert_eq(second_idempotent.code, 200)
    assert_true(second_body.text().contains("\"idempotent_replay\":true"))
    assert_eq(provider_requests.val, before_idempotent + 1)
    let (conflict, conflict_body) = @asynchttp.post(
      base + "/idempotent-conflict",
      "{}",
      headers={ "Content-Type": "application/json" },
    )
    assert_eq(conflict.code, 409)
    assert_true(conflict_body.text().contains("idempotency-key"))
    let (resume_response, resume_body) = @asynchttp.get(base + "/resume")
    let resumed = resume_body.text()
    assert_eq(resume_response.code, 200)
    assert_false(resumed.contains("id: 1\n"))
    assert_true(resumed.contains("event: message.delta"))
    assert_true(resumed.contains("event: turn.completed"))
    let disconnected = @socket.Tcp::connect(platform.addr)
    disconnected.write(
      "POST /disconnect HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nAccept: text/event-stream\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}",
    )
    @async.sleep(10)
    disconnected.close()
    @async.sleep(100)
    match @conversation.active_turn_id(database, "disconnect-chat") {
      Ok(value) => assert_eq(value, "")
      Err(error) => fail(error.message)
    }
    match @conversation.completed_messages(database, "disconnect-chat") {
      Ok(messages) => assert_eq(messages.length(), 2)
      Err(error) => fail(error.message)
    }
    match @conversation.active_turn_id(database, "stream-chat") {
      Ok(value) => assert_eq(value, "")
      Err(error) => fail(error.message)
    }
    platform.close()
    provider.close()
    database.close()
  }
}
