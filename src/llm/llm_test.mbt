///|
test "connector parser is strict and normalizes its base URL" {
  let parsed = parse_connector(
    {
      "id": "default",
      "type": "openai_chat",
      "base_url": "https://api.openai.com/v1/",
      "api_key_env": "OPENAI_API_KEY",
      "model": "gpt-4o-mini",
      "timeout_ms": 60000,
    },
    "connectors/default.json",
  )
  match parsed {
    Ok(connector) => assert_eq(connector.base_url, "https://api.openai.com/v1")
    Err(error) => fail(error.message)
  }
  match
    parse_connector(
      {
        "id": "default",
        "type": "openai_chat",
        "base_url": "http://example.com/v1",
        "api_key_env": "secret-value",
        "model": "gpt",
        "timeout_ms": 10,
      },
      "connectors/default.json",
    ) {
    Err(error) => assert_eq(error.code, @errors.InvalidDsl)
    Ok(_) => fail("expected invalid connector")
  }
  match
    parse_connector(
      {
        "id": "default",
        "type": "openai_chat",
        "base_url": "https://api.openai.com/v1",
        "api_key_env": "OPENAI_API_KEY",
        "model": "gpt",
        "timeout_ms": 1000.5,
      },
      "connectors/default.json",
    ) {
    Err(error) => assert_eq(error.code, @errors.InvalidDsl)
    Ok(_) => fail("expected integer timeout")
  }
}

///|
test "non-stream requests omit stream-only options" {
  let request : ChatRequest = {
    model: "fake",
    messages: [{ role: User, content: "hi" }],
    temperature: 0.0,
    max_tokens: 8,
    stream: false,
  }
  guard request_json(request) is Object(object) else {
    fail("expected request object")
  }
  assert_false(object.contains("stream_options"))
}

///|
test "completion parser accepts text and rejects empty choices" {
  match
    parse_completion(
      "{\"choices\":[{\"message\":{\"content\":\"hello\"}}],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":1}}",
    ) {
    Ok((content, usage)) => {
      assert_eq(content, "hello")
      assert_eq(usage.prompt_tokens, 2)
    }
    Err(error) => fail(error.message)
  }
  match parse_completion("{\"choices\":[]}") {
    Err(error) => assert_eq(error.code, @errors.LlmError)
    Ok(_) => fail("expected no-choice error")
  }
}

///|
test "SSE parser handles CRLF, multiple events, usage, and termination" {
  let source = "data: {\"choices\":[{\"delta\":{\"content\":\"hel\"}}]}\r\n\r\ndata: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\ndata: {\"choices\":[],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":1}}\n\ndata: [DONE]\n\n"
  match parse_sse(source) {
    Ok((events, content, usage)) => {
      assert_eq(content, "hello")
      assert_eq(usage.prompt_tokens, 3)
      assert_eq(events.length(), 5)
    }
    Err(error) => fail(error.message)
  }
  match parse_sse("data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n") {
    Err(error) => assert_eq(error.code, @errors.LlmError)
    Ok(_) => fail("expected truncated stream error")
  }
}

///|
async test "HTTP connector streams chunks and maps status and timeout errors" {
  @async.with_task_group() <| group => {
    let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever(allow_failure=true) <| ((request, body, connection) => {
        let request_body = body.read_all().text()
        if request.path == "/v1/chat/completions" {
          assert_eq(
            request.headers.get("authorization"),
            Some("Bearer test-key"),
          )
          assert_true(request_body.contains("\"model\":\"fake\""))
          connection.send_response(200, "OK", extra_headers={
            "Content-Type": "text/event-stream",
          })
          connection
          ..write_string(
            "data: {\"choices\":[{\"delta\":{\"content\":\"hel\"}}]}\r\n\r\n",
          )
          .flush()
          @async.sleep(20)
          connection.write_string(
            "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\ndata: [DONE]\n\n",
          )
          connection.end_response()
        } else if request.path == "/error/chat/completions" {
          connection.send_response(500, "Error", extra_headers={
            "Content-Length": "6",
          })
          connection.write_string("secret")
          connection.end_response()
        } else {
          @async.sleep(1100)
          connection.send_response(200, "OK", extra_headers={
            "Content-Length": "2",
          })
          connection.write_string("{}")
          connection.end_response()
        }
      })
    }
    let base : Connector = {
      id: "default",
      connector_type: "openai_chat",
      base_url: "http://127.0.0.1:\{server.addr.port()}/v1",
      api_key_env: "TEST_KEY",
      model: "fake",
      timeout_ms: 1000,
    }
    let request : ChatRequest = {
      model: "fake",
      messages: [{ role: User, content: "hi" }],
      temperature: 0.0,
      max_tokens: 8,
      stream: true,
    }
    let observed : Array[CompletionEvent] = []
    match
      complete_http(base, request, "test-key", event => observed.push(event)) {
      Ok((_, content, _)) => {
        assert_eq(content, "hello")
        assert_eq(observed.length(), 3)
      }
      Err(error) => fail(error.message)
    }
    let error_connector : Connector = {
      ..base,
      base_url: "http://127.0.0.1:\{server.addr.port()}/error",
    }
    match complete_http(error_connector, request, "test-key", _ => ()) {
      Err(error) => {
        assert_eq(error.code, @errors.LlmError)
        assert_false(error.message.contains("secret"))
      }
      Ok(_) => fail("expected HTTP error")
    }
    let timeout_connector : Connector = {
      ..base,
      base_url: "http://127.0.0.1:\{server.addr.port()}/timeout",
    }
    match complete_http(timeout_connector, request, "test-key", _ => ()) {
      Err(error) => assert_eq(error.code, @errors.LlmError)
      Ok(_) => fail("expected timeout")
    }
    server.close()
  }
}
