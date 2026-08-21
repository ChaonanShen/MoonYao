///|
fn provider_test_request(stream? : Bool = false) -> ChatRequest {
  {
    model: "provider-model",
    messages: [],
    wire_messages: Some([
      { "role": "system", "content": "Be concise" },
      {
        "role": "user",
        "content": [
          { "type": "text", "text": "Describe" },
          {
            "type": "image_url",
            "image_url": { "url": "data:image/png;base64,iVBORw0KGgo=" },
          },
        ],
      },
      {
        "role": "assistant",
        "content": "",
        "tool_calls": [
          {
            "id": "call_1",
            "type": "function",
            "function": { "name": "lookup", "arguments": "{\"id\":1}" },
          },
        ],
      },
      {
        "role": "tool",
        "tool_call_id": "call_1",
        "name": "lookup",
        "content": "{\"title\":\"one\"}",
      },
    ]),
    temperature: 0.2,
    max_tokens: 128,
    stream,
    tools: [
      {
        name: "lookup",
        description: "Look up an item.",
        input_schema: {
          "type": "object",
          "properties": { "id": { "type": "integer" } },
          "required": ["id"],
        },
      },
    ],
  }
}

///|
test "Anthropic projection maps canonical images, tools, and results" {
  let value = anthropic_request_json(provider_test_request()).unwrap()
  let source = value.stringify()
  assert_true(source.contains("\"system\":\"Be concise\""))
  assert_true(source.contains("\"type\":\"image\""))
  assert_true(source.contains("\"media_type\":\"image/png\""))
  assert_true(source.contains("\"type\":\"tool_use\""))
  assert_true(source.contains("\"type\":\"tool_result\""))
  assert_true(source.contains("\"input_schema\""))
}

///|
test "Gemini projection maps canonical images, tools, and results" {
  let value = gemini_request_json(provider_test_request()).unwrap()
  let source = value.stringify()
  assert_true(source.contains("\"systemInstruction\""))
  assert_true(source.contains("\"inlineData\""))
  assert_true(source.contains("\"functionCall\""))
  assert_true(source.contains("\"functionResponse\""))
  assert_true(source.contains("\"functionDeclarations\""))
}

///|
test "Anthropic completion parser emits provider-neutral events" {
  let source = (
    {
      "content": [
        { "type": "text", "text": "hello" },
        {
          "type": "tool_use",
          "id": "call_1",
          "name": "lookup",
          "input": { "id": 1 },
        },
      ],
      "usage": { "input_tokens": 3, "output_tokens": 4 },
    } : Json).stringify()
  let (events, content, usage) = parse_anthropic_completion(source).unwrap()
  assert_eq(content, "hello")
  assert_eq(usage, { prompt_tokens: 3, completion_tokens: 4 })
  assert_true(events.contains(TextDelta("hello")))
  assert_true(
    events.contains(
      ToolCallCompleted({
        id: "call_1",
        name: "lookup",
        arguments_json: "{\"id\":1}",
      }),
    ),
  )
}

///|
test "Gemini completion parser emits provider-neutral events" {
  let source = (
    {
      "candidates": [
        {
          "content": {
            "role": "model",
            "parts": [
              { "text": "hello" },
              { "functionCall": { "name": "lookup", "args": { "id": 1 } } },
            ],
          },
        },
      ],
      "usageMetadata": { "promptTokenCount": 5, "candidatesTokenCount": 6 },
    } : Json).stringify()
  let (events, content, usage) = parse_gemini_completion(source).unwrap()
  assert_eq(content, "hello")
  assert_eq(usage, { prompt_tokens: 5, completion_tokens: 6 })
  assert_true(events.contains(TextDelta("hello")))
  assert_true(
    events.contains(
      ToolCallCompleted({
        id: "gemini_call_0",
        name: "lookup",
        arguments_json: "{\"id\":1}",
      }),
    ),
  )
}

///|
test "connector parser accepts named supported providers" {
  for
    item in [
      ("anthropic", "anthropic_messages"),
      ("gemini", "gemini_generate_content"),
    ] {
    let (id, kind) = item
    let connector = parse_connector(
      {
        "id": id,
        "type": kind,
        "base_url": "https://provider.example.com/v1",
        "api_key_env": "PROVIDER_API_KEY",
        "model": "provider-model",
        "timeout_ms": 60000,
      },
      "connectors/" + id + ".json",
    ).unwrap()
    assert_eq(connector.id, id)
    assert_eq(connector.connector_type, kind)
  }
}

///|
async test "Anthropic and Gemini adapters complete fake HTTP streams" {
  @async.with_task_group() <| group => {
    let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever(allow_failure=true) <| ((request, body, connection) => {
        let source = body.read_all().text()
        if request.headers.get("x-api-key") != Some("test-key") &&
          request.headers.get("x-goog-api-key") != Some("test-key") {
          connection.send_response(401, "Unauthorized")
          connection.end_response()
          return
        }
        if request.path == "/v1/messages" && source.contains("\"stream\":true") {
          connection.send_response(200, "OK", extra_headers={
            "Content-Type": "text/event-stream",
          })
          let frames : Array[Json] = [
            {
              "type": "message_start",
              "message": { "usage": { "input_tokens": 2, "output_tokens": 0 } },
            },
            {
              "type": "content_block_start",
              "index": 0,
              "content_block": { "type": "text", "text": "" },
            },
            {
              "type": "content_block_delta",
              "index": 0,
              "delta": { "type": "text_delta", "text": "anthropic stream" },
            },
            { "type": "content_block_stop", "index": 0 },
            { "type": "message_delta", "usage": { "output_tokens": 3 } },
            { "type": "message_stop" },
          ]
          for data in frames {
            connection.write_string("data: " + data.stringify() + "\n\n")
          }
          connection.end_response()
        } else if request.path == "/v1/messages" {
          let response : Json = {
            "content": [{ "type": "text", "text": "anthropic" }],
            "usage": { "input_tokens": 2, "output_tokens": 1 },
          }
          connection.send_response(200, "OK", extra_headers={
            "Content-Type": "application/json",
          })
          connection.write_string(response.stringify())
          connection.end_response()
        } else if request.path.has_prefix(
            "/v1beta/models/provider-model:streamGenerateContent",
          ) {
          connection.send_response(200, "OK", extra_headers={
            "Content-Type": "text/event-stream",
          })
          let response : Json = {
            "candidates": [
              { "content": { "parts": [{ "text": "gemini stream" }] } },
            ],
            "usageMetadata": {
              "promptTokenCount": 4,
              "candidatesTokenCount": 2,
            },
          }
          connection.write_string("data: " + response.stringify() + "\n\n")
          connection.end_response()
        } else if request.path ==
          "/v1beta/models/provider-model:generateContent" {
          let response : Json = {
            "candidates": [{ "content": { "parts": [{ "text": "gemini" }] } }],
            "usageMetadata": {
              "promptTokenCount": 4,
              "candidatesTokenCount": 1,
            },
          }
          connection.send_response(200, "OK", extra_headers={
            "Content-Type": "application/json",
          })
          connection.write_string(response.stringify())
          connection.end_response()
        } else {
          connection.send_response(404, "Not Found")
          connection.end_response()
        }
      })
    }
    let base = "http://127.0.0.1:" + server.addr.port().to_string()
    let cases = [
      (
        {
          id: "anthropic",
          connector_type: "anthropic_messages",
          base_url: base + "/v1",
          api_key_env: "TEST_KEY",
          model: "provider-model",
          timeout_ms: 1000,
        } : Connector),
      (
        {
          id: "gemini",
          connector_type: "gemini_generate_content",
          base_url: base + "/v1beta",
          api_key_env: "TEST_KEY",
          model: "provider-model",
          timeout_ms: 1000,
        } : Connector),
    ]
    for connector in cases {
      for stream in [false, true] {
        let events : Array[CompletionEvent] = []
        let result = complete_provider_until(
          connector,
          {
            model: connector.model,
            messages: [{ role: User, content: "hello" }],
            wire_messages: None,
            temperature: 0.2,
            max_tokens: 16,
            stream,
            tools: [],
          },
          "test-key",
          event => events.push(event),
          @async.now() + 2000L,
        )
        let (_, content, usage) = match result {
          Ok(value) => value
          Err(error) =>
            fail(connector.id + "/" + stream.to_string() + ": " + error.message)
        }
        assert_true(
          content.contains(
            if connector.id == "anthropic" {
              "anthropic"
            } else {
              "gemini"
            },
          ),
        )
        assert_true(usage.prompt_tokens > 0)
        assert_true(events.contains(Started))
        assert_true(events.any(event => event is TextDelta(_)))
      }
    }
    server.close()
  }
}
