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
    group.spawn_bg(no_wait=true) <| () => {
      provider.run_forever(allow_failure=true) <| ((_, body, connection) => {
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
      connector: Some(connector),
      agents: [tcp_test_agent()],
    }
    let database = @sqlite3.Connection::open(":memory:")
    ignore(@conversation.migrate(database))
    ignore(
      @conversation.create_chat(database, "stream-chat", "todo", "Stream", 1),
    )
    ignore(@conversation.create_chat(database, "json-chat", "todo", "JSON", 1))
    let platform = @asynchttp.Server(@socket.Addr::parse("127.0.0.1:0"))
    group.spawn_bg(no_wait=true) <| () => {
      platform.run_forever(allow_failure=true) <| ((request, body, connection) => {
        ignore(body.read_all())
        let stream = request.path == "/stream"
        run_http_turn(
          application,
          database,
          if stream {
            "stream-chat"
          } else {
            "json-chat"
          },
          "hello",
          stream,
          connection,
          "turn-request",
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
    assert_false(events.contains("tool.arguments.delta"))
    let (json_response, json_body) = @asynchttp.post(base + "/json", "{}", headers={
      "Content-Type": "application/json",
    })
    assert_eq(json_response.code, 200)
    assert_true(json_body.text().contains("\"content\":\"hello\""))
    match @conversation.active_turn_id(database, "stream-chat") {
      Ok(value) => assert_eq(value, "")
      Err(error) => fail(error.message)
    }
    platform.close()
    provider.close()
    database.close()
  }
}
