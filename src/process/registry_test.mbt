///|
fn todo_model() -> @model.Model {
  match
    @model.parse_model(
      {
        "name": "todo",
        "table": "todos",
        "columns": [
          { "name": "id", "type": "id" },
          { "name": "title", "type": "string" },
          { "name": "done", "type": "bool", "default": false },
        ],
      },
      "models/todo.json",
    ) {
    Ok(value) => value
    Err(error) => abort(error.message)
  }
}

///|
fn expect_ok(result : Result[Json, @errors.EngineError]) -> Json {
  match result {
    Ok(value) => value
    Err(error) => abort(error.to_json().stringify())
  }
}

///|
test "registry exposes five CRUD processes and preserves bound values" {
  let model = todo_model()
  let connection = @sqlite3.Connection::open(":memory:")
  match @model.migrate(connection, model) {
    Ok(_) => ()
    Err(error) => abort(error.message)
  }
  let registry = Registry::new([model])
  assert_eq(registry.names().length(), 5)
  assert_true(registry.names().contains("models.todo.Create"))
  let malicious = "title with a quote: ' OR 1=1 --"
  let created = expect_ok(
    registry.run(connection, "models.todo.Create", {
      "data": { "title": malicious },
    }),
  )
  guard created is Object(created_row) else { abort("expected created row") }
  assert_eq(created_row.get("title"), Some(Json::string(malicious)))
  assert_eq(created_row.get("done"), Some(Json::boolean(false)))
  let id = created_row.get("id").unwrap()
  let found = expect_ok(
    registry.run(connection, "models.todo.Find", { "id": id }),
  )
  guard found is Object(found_row) else { abort("expected found row") }
  assert_eq(found_row.get("title"), Some(Json::string(malicious)))

  let updated = expect_ok(
    registry.run(connection, "models.todo.Update", {
      "id": id,
      "data": { "done": true },
    }),
  )
  guard updated is Object(updated_row) else { abort("expected updated row") }
  assert_eq(updated_row.get("done"), Some(Json::boolean(true)))

  ignore(
    expect_ok(
      registry.run(connection, "models.todo.Create", {
        "data": { "title": "second" },
      }),
    ),
  )
  let listed = expect_ok(
    registry.run(connection, "models.todo.List", {
      "where": { "done": false },
      "limit": 20,
      "offset": 0,
    }),
  )
  guard listed is Array(rows) else { abort("expected list") }
  assert_eq(rows.length(), 1)

  let deleted = expect_ok(
    registry.run(connection, "models.todo.Delete", { "id": id }),
  )
  guard deleted is Object(deleted_row) else { abort("expected deleted row") }
  assert_eq(deleted_row.get("id"), Some(id))
  match registry.run(connection, "models.todo.Find", { "id": id }) {
    Err(error) => assert_eq(error.code, @errors.RecordNotFound)
    Ok(_) => abort("expected missing record")
  }
  connection.close()
}

///|
test "CRUD validation returns stable errors and leaves the connection usable" {
  let model = todo_model()
  let connection = @sqlite3.Connection::open(":memory:")
  match @model.migrate(connection, model) {
    Ok(_) => ()
    Err(error) => abort(error.message)
  }
  let registry = Registry::new([model])
  let cases = [
    registry.run(connection, "models.todo.Create", {
      "data": { "title": "x", "unknown": 1 },
    }),
    registry.run(connection, "models.todo.List", {
      "where": { "done": { "eq": false } },
    }),
    registry.run(connection, "models.todo.List", { "limit": -1 }),
    registry.run(connection, "models.todo.List", { "limit": 1.0e100 }),
    registry.run(connection, "models.todo.Update", { "id": 1, "data": {} }),
  ]
  for result in cases {
    match result {
      Err(error) => assert_eq(error.code, @errors.InvalidArgument)
      Ok(_) => abort("expected invalid argument")
    }
  }
  match registry.run(connection, "models.todo.Unknown", {}) {
    Err(error) => assert_eq(error.code, @errors.ProcessNotFound)
    Ok(_) => abort("expected missing process")
  }
  let created = registry.run(connection, "models.todo.Create", {
    "data": { "title": "still works" },
  })
  match created {
    Ok(_) => ()
    Err(error) => abort(error.message)
  }
  connection.close()
}
