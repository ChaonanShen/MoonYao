///|
test "agent and prompt DSL accept the documented shape" {
  let parsed = parse_agent(
    {
      "id": "todo",
      "name": "Todo Assistant",
      "connector": "default",
      "options": { "temperature": 0.2, "max_tokens": 1024 },
    },
    "todo",
    "agents/todo/agent.json",
  )
  match parsed {
    Ok(agent) => assert_eq(agent.options.max_tokens, 1024)
    Err(error) => fail(error.message)
  }
  match
    parse_prompts(
      [{ "role": "system", "content": "Be concise." }],
      "agents/todo/prompts.json",
    ) {
    Ok(prompts) => assert_eq(prompts.length(), 1)
    Err(error) => fail(error.message)
  }
}

///|
test "agent DSL rejects directory mismatch, P6 keys, and non-system prompts" {
  match
    parse_agent(
      { "id": "other", "name": "Todo", "connector": "default" },
      "todo",
      "agents/todo/agent.json",
    ) {
    Err(error) => assert_eq(error.path, "agents/todo/agent.json.id")
    Ok(_) => fail("expected mismatch")
  }
  match
    parse_agent(
      { "id": "todo", "name": "Todo", "connector": "default", "tools": [] },
      "todo",
      "agents/todo/agent.json",
    ) {
    Err(error) => assert_eq(error.path, "agents/todo/agent.json.tools")
    Ok(_) => fail("expected unknown P6 key")
  }
  match
    parse_prompts(
      [{ "role": "user", "content": "bad" }],
      "agents/todo/prompts.json",
    ) {
    Err(error) => assert_eq(error.code, @errors.InvalidDsl)
    Ok(_) => fail("expected role error")
  }
}
