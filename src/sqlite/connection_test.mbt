///|
test "SQLite adapter uses prepared parameters in an in-memory database" {
  let connection = open(":memory:")
  let create = connection.prepare(
    "CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL)",
  )
  create.step_once()
  create.finalize()

  let insert = connection.prepare("INSERT INTO notes (id, title) VALUES (?, ?)")
  insert.bind(index=1, 1)
  insert.bind(index=2, "title with a quote: ' OR 1=1 --")
  insert.step_once()
  insert.finalize()

  let query = connection.prepare("SELECT title FROM notes WHERE id = ?")
  query.bind(index=1, 1)
  assert_true(query.step())
  let title : String = query.column(index=0)
  assert_eq(title, "title with a quote: ' OR 1=1 --")
  assert_false(query.step())
  query.finalize()
  connection.close()
}
