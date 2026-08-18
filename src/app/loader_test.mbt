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
