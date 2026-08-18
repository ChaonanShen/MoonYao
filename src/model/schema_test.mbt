///|
test "schema migration is idempotent" {
  let model = match
    parse_model(
      {
        "name": "todo",
        "table": "todos",
        "columns": [
          { "name": "id", "type": "id" },
          { "name": "done", "type": "bool", "default": false },
        ],
      },
      "models/todo.json",
    ) {
    Ok(value) => value
    Err(error) => fail(error.message)
  }
  let connection = @sqlite3.Connection::open(":memory:")
  match migrate(connection, model) {
    Ok(_) => ()
    Err(error) => fail(error.message)
  }
  match migrate(connection, model) {
    Ok(_) => ()
    Err(error) => fail(error.message)
  }
  let statement = connection.prepare(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
  )
  statement.bind(index=1, "todos")
  assert_true(statement.step())
  statement.finalize()
  connection.close()
}

///|
test "schema renders scalar defaults and rejects unsupported NULL semantics" {
  let defaults = match
    parse_model(
      {
        "name": "sample",
        "table": "samples",
        "columns": [
          { "name": "id", "type": "id" },
          { "name": "title", "type": "string", "default": "it's ready" },
        ],
      },
      "models/sample.json",
    ) {
    Ok(value) => value
    Err(error) => abort(error.message)
  }
  match create_table_sql(defaults) {
    Ok(sql) => assert_true(sql.contains("DEFAULT 'it''s ready'"))
    Err(error) => abort(error.message)
  }
  let nullable = match
    parse_model(
      {
        "name": "sample",
        "table": "samples",
        "columns": [
          { "name": "id", "type": "id" },
          { "name": "note", "type": "text", "nullable": true },
        ],
      },
      "models/sample.json",
    ) {
    Ok(value) => value
    Err(error) => abort(error.message)
  }
  match create_table_sql(nullable) {
    Err(error) => assert_eq(error.code, InvalidDsl)
    Ok(_) => abort("expected unsupported nullable column")
  }
}
