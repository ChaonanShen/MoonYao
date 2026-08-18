///|
test "errors use the documented JSON envelope" {
  let error = invalid_dsl(
    "column name is invalid", "models/todo.json.columns[1].name",
  )
  assert_eq(
    error.to_json().stringify(),
    "{\"error\":{\"code\":\"invalid_dsl\",\"message\":\"column name is invalid\",\"path\":\"models/todo.json.columns[1].name\"}}",
  )
}
