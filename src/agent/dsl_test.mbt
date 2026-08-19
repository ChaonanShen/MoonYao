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
  match
    parse_agent(
      {
        "id": "todo",
        "name": "Todo",
        "connector": "default",
        "hooks": { "create": "flows.create", "next": "flows.next" },
      },
      "todo",
      "agents/todo/agent.json",
    ) {
    Ok(agent) => {
      assert_eq(agent.create_process, "flows.create")
      assert_eq(agent.next_process, "flows.next")
    }
    Err(error) => fail(error.message)
  }
}

///|
test "agent DSL rejects directory mismatch, duplicate tools, and non-system prompts" {
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
      {
        "id": "todo",
        "name": "Todo",
        "connector": "default",
        "tools": ["create", "create"],
      },
      "todo",
      "agents/todo/agent.json",
    ) {
    Err(error) => assert_eq(error.path, "agents/todo/agent.json.tools[1]")
    Ok(_) => fail("expected duplicate tool")
  }
  match
    parse_prompts(
      [{ "role": "user", "content": "bad" }],
      "agents/todo/prompts.json",
    ) {
    Err(error) => assert_eq(error.code, @errors.InvalidDsl)
    Ok(_) => fail("expected role error")
  }
  match
    parse_agent(
      {
        "id": "todo",
        "name": "Todo",
        "connector": "default",
        "hooks": { "create": "flows.create" },
        "before_process": "flows.before",
      },
      "todo",
      "agents/todo/agent.json",
    ) {
    Err(error) => assert_eq(error.path, "agents/todo/agent.json.hooks.create")
    Ok(_) => fail("expected new and legacy hook conflict")
  }
  match
    parse_agent(
      {
        "id": "todo",
        "name": "Todo",
        "connector": "default",
        "hooks": { "next": "flows.next" },
        "after_process": "flows.after",
      },
      "todo",
      "agents/todo/agent.json",
    ) {
    Err(error) => assert_eq(error.path, "agents/todo/agent.json.hooks.next")
    Ok(_) => fail("expected Next and legacy after hook conflict")
  }
}
