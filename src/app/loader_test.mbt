///|
test "application loader reads a valid application" {
  match load("testdata/apps/valid") {
    Ok(application) => {
      assert_eq(application.name, "Todo Demo")
      assert_eq(application.models.length(), 1)
    }
    Err(error) => fail(error.message)
  }
}

///|
test "application loader resolves both release examples" {
  @env.set_env_var("LLM_BASE_URL", "https://api.deepseek.com/v1")
  @env.set_env_var("LLM_API_KEY_ENV", "LLM_API_KEY")
  @env.set_env_var("LLM_MODEL", "deepseek-chat")
  defer {
    @env.unset_env_var("LLM_BASE_URL")
    @env.unset_env_var("LLM_API_KEY_ENV")
    @env.unset_env_var("LLM_MODEL")
  }
  for path in ["example/todo", "example/todo-agent"] {
    match load(path) {
      Ok(application) => {
        assert_eq(application.models.length(), 1)
        assert_eq(application.flows.length(), 1)
        assert_eq(application.apis.length(), 1)
        assert_eq(application.agents.length(), 1)
        assert_eq(application.agents[0].id, "todo")
        assert_eq(application.agents[0].prompts.length(), 1)
        assert_eq(application.agents[0].tools.length(), 4)
        assert_true(application.connector is Some(_))
      }
      Err(error) => fail(path + ": " + error.message + " at " + error.path)
    }
  }
}

///|
test "application loader retains model file diagnostics" {
  match load("testdata/apps/invalid-unknown-type") {
    Err(error) => assert_eq(error.path, "models/todo.json.columns[0].type")
    Ok(_) => fail("expected invalid DSL")
  }
}

///|
test "application loader rejects duplicate model names" {
  match load("testdata/apps/invalid-duplicate-model") {
    Err(error) => assert_eq(error.path, "models/second.json.name")
    Ok(_) => fail("expected invalid DSL")
  }
}

///|
test "application loader rejects Flow cycles and forward references" {
  match load("testdata/apps/invalid-flow-cycle") {
    Err(error) => assert_eq(error.code, @errors.InvalidDsl)
    Ok(_) => fail("expected Flow cycle")
  }
  match load("testdata/apps/invalid-flow-forward") {
    Err(error) => assert_eq(error.code, @errors.InvalidDsl)
    Ok(_) => fail("expected forward reference")
  }
}
