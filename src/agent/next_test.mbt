///|
fn next_context() -> TurnContextSnapshot {
  context_snapshot(
    "ctx_next",
    "req_next",
    "chat_next",
    "turn_next",
    "todo",
    "default",
    { "source": "request", "keep": true },
    1000,
    2000,
  ).unwrap()
}

///|
test "Next payload preserves ordered tool results" {
  let tools : Array[NextToolResult] = [
    {
      tool_call_id: "call_1",
      name: "create",
      arguments: { "title": "one" },
      result: Some({ "id": 1 }),
      error: None,
    },
    {
      tool_call_id: "call_2",
      name: "delete",
      arguments: { "id": 2 },
      result: None,
      error: Some({ "code": "tool_error", "message": "failed" }),
    },
  ]
  let payload = next_input_json(
    next_context(),
    [@content.text_message(@content.User, "work")],
    "done",
    { prompt_tokens: 3, completion_tokens: 2 },
    tools,
  )
  guard payload is Object(object) else { fail("expected Next payload object") }
  guard object.get("tools") is Some(Array(encoded_tools)) else {
    fail("expected Next tool array")
  }
  assert_true(encoded_tools[0].stringify().contains("call_1"))
  assert_true(encoded_tools[1].stringify().contains("call_2"))
  let encoded = payload.stringify()
  assert_true(encoded.contains("\"finish_reason\":\"stop\""))
  assert_true(encoded.contains("\"prompt_tokens\":3"))
}

///|
test "Next standard and custom decisions are strict" {
  match apply_next_decision({ "action": "return" }, next_context()) {
    Ok(decision) => assert_eq(decision.data, None)
    Err(error) => fail(error.message)
  }
  match
    apply_next_decision(
      {
        "action": "data",
        "data": { "answer": "custom" },
        "metadata": { "source": "next" },
      },
      next_context(),
    ) {
    Ok(decision) => {
      assert_eq(decision.data, Some(({ "answer": "custom" } : Json)))
      assert_true(
        decision.context.metadata.stringify().contains("\"keep\":true"),
      )
      assert_true(
        decision.context.metadata.stringify().contains("\"source\":\"next\""),
      )
    }
    Err(error) => fail(error.message)
  }
}

///|
test "Next rejects unknown actions, fields, and oversized output" {
  let cases : Array[(Json, String)] = [
    ({ "action": "delegate" }, "next.action"),
    ({ "action": "return", "data": {} }, "next.data"),
    ({ "action": "data" }, "next.data"),
    ({ "action": "data", "data": {}, "extra": true }, "next.decision.extra"),
    ({ "action": "data", "data": "x".repeat(262145) }, "next.data"),
    (
      {
        "action": "data",
        "data": {},
        "metadata": { "value": "x".repeat(33000) },
      },
      "next.metadata",
    ),
  ]
  for item in cases {
    let (output, path) = item
    match apply_next_decision(output, next_context()) {
      Err(error) => assert_eq(error.path, path)
      Ok(_) => fail("expected invalid Next decision")
    }
  }
}
