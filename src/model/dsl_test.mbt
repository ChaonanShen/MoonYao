///|
test "model parser accepts the documented todo model" {
  let input : Json = {
    "name": "todo",
    "table": "todos",
    "columns": [
      { "name": "id", "type": "id" },
      { "name": "title", "type": "string", "nullable": false },
      { "name": "done", "type": "bool", "default": false },
    ],
  }
  match parse_model(input, "models/todo.json") {
    Ok(model) => {
      assert_eq(model.name, "todo")
      assert_eq(model.table, "todos")
      assert_eq(model.columns.length(), 3)
      assert_eq(model.columns[2].column_type, Bool)
    }
    Err(error) => fail(error.message)
  }
}

///|
test "model parser rejects unknown types and duplicate columns" {
  let unknown_type : Json = {
    "name": "todo",
    "table": "todos",
    "columns": [{ "name": "title", "type": "json" }],
  }
  match parse_model(unknown_type, "models/todo.json") {
    Err(error) => {
      assert_eq(error.code, InvalidDsl)
      assert_eq(error.path, "models/todo.json.columns[0].type")
    }
    Ok(_) => fail("expected invalid DSL")
  }
  let duplicate : Json = {
    "name": "todo",
    "table": "todos",
    "columns": [
      { "name": "title", "type": "string" },
      { "name": "title", "type": "text" },
    ],
  }
  match parse_model(duplicate, "models/todo.json") {
    Err(error) => assert_eq(error.path, "models/todo.json.columns[1].name")
    Ok(_) => fail("expected invalid DSL")
  }
}

///|
test "model parser rejects unknown keys and unsafe identifiers" {
  let unknown_key : Json = {
    "name": "todo",
    "table": "todos",
    "columns": [{ "name": "title", "type": "string", "unexpected": true }],
  }
  match parse_model(unknown_key, "models/todo.json") {
    Err(error) =>
      assert_eq(error.path, "models/todo.json.columns[0].unexpected")
    Ok(_) => fail("expected invalid DSL")
  }
  let unsafe_name : Json = {
    "name": "todo",
    "table": "todos;drop",
    "columns": [{ "name": "title", "type": "string" }],
  }
  match parse_model(unsafe_name, "models/todo.json") {
    Err(error) => assert_eq(error.code, InvalidDsl)
    Ok(_) => fail("expected invalid DSL")
  }
}
