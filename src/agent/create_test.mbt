///|
fn create_context() -> TurnContextSnapshot {
  context_snapshot(
    "ctx_1",
    "req_1",
    "chat_1",
    "turn_1",
    "todo",
    "default",
    { "source": "request", "keep": true },
    1000,
    2000,
  ).unwrap()
}

///|
fn create_messages() -> Array[@content.Message] {
  [
    @content.text_message(@content.System, "Be concise"),
    {
      role: @content.User,
      content: Some(
        @content.Parts([
          @content.TextPart("Describe"),
          @content.ImageRef("att_abcdefghijklmnopqrst", @content.Auto),
        ]),
      ),
      name: None,
      tool_call_id: None,
      reasoning_content: None,
      tool_calls: [],
      refusal: None,
    },
  ]
}

///|
test "Create input and null decision preserve effective defaults" {
  let messages = create_messages()
  let input = create_input_json(
    create_context(),
    messages,
    "default",
    0.2,
    1024,
  )
  let encoded = input.stringify()
  assert_true(encoded.contains("\"version\":1"))
  assert_true(
    encoded.contains("\"attachment_id\":\"att_abcdefghijklmnopqrst\""),
  )
  match
    apply_create_decision(
      Json::null(),
      messages,
      "default",
      0.2,
      1024,
      create_context(),
    ) {
    Ok(decision) => {
      assert_eq(decision.messages, messages)
      assert_eq(decision.temperature, 0.2)
      assert_eq(decision.snapshot, Json::null())
    }
    Err(error) => fail(error.message)
  }
}

///|
test "Create decision replaces messages and overrides generation and context" {
  let output : Json = {
    "messages": [{ "role": "user", "content": "rewritten" }],
    "connector": "default",
    "generation": { "temperature": 0.1, "max_tokens": 1200 },
    "context": {
      "locale": "zh-CN",
      "theme": "default",
      "route": "chat",
      "metadata": { "source": "hook", "scenario": "support" },
    },
  }
  match
    apply_create_decision(
      output,
      create_messages(),
      "default",
      0.2,
      1024,
      create_context(),
    ) {
    Ok(decision) => {
      assert_eq(decision.messages, [
        @content.text_message(@content.User, "rewritten"),
      ])
      assert_eq(decision.temperature, 0.1)
      assert_eq(decision.max_tokens, 1200)
      assert_eq(decision.context.locale, "zh-CN")
      assert_true(
        decision.context.metadata.stringify().contains("\"keep\":true"),
      )
      assert_true(
        decision.context.metadata.stringify().contains("\"source\":\"hook\""),
      )
    }
    Err(error) => fail(error.message)
  }
}

///|
test "Create decision rejects unknown options and attachment forgery" {
  let cases : Array[(Json, String)] = [
    ({ "delegate": {} }, "create.decision.delegate"),
    ({ "connector": "other" }, "create.connector"),
    ({ "generation": { "temperature": 3.0 } }, "create.generation.temperature"),
    ({ "generation": { "max_tokens": 0 } }, "create.generation.max_tokens"),
    ({ "context": { "agent_id": "other" } }, "create.context.agent_id"),
    (
      { "context": { "metadata": { "value": "x".repeat(33000) } } },
      "create.context.metadata",
    ),
    (
      {
        "messages": [
          {
            "role": "user",
            "content": [
              {
                "type": "image",
                "attachment_id": "att_forgedabcdefghijkl",
                "detail": "auto",
              },
            ],
          },
        ],
      },
      "create.messages",
    ),
  ]
  for item in cases {
    let (output, path) = item
    match
      apply_create_decision(
        output,
        create_messages(),
        "default",
        0.2,
        1024,
        create_context(),
      ) {
      Err(error) => assert_eq(error.path, path)
      Ok(_) => fail("expected invalid Create decision")
    }
  }
}

///|
test "legacy provider messages convert to canonical hook messages" {
  assert_eq(
    canonical_from_chat({ role: @llm.User, content: "hello" }),
    @content.text_message(@content.User, "hello"),
  )
  let tool = canonical_from_chat({
    role: @llm.Tool,
    content: "{\"tool_call_id\":\"call_1\",\"name\":\"create\",\"content\":\"ok\"}",
  })
  assert_eq(tool.role, @content.Tool)
  assert_eq(tool.tool_call_id, Some("call_1"))
  assert_eq(tool.content, Some(@content.Text("ok")))
}
