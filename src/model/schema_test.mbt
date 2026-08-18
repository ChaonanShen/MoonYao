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
