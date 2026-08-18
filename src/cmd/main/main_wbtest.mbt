///|
test "check is side-effect free while migrate and run use the configured database" {
  let app_dir = "testdata/apps/cli-sandbox"
  let database = app_dir + "/todo.db"
  if @fs.path_exists(database) {
    @fs.remove_file(database)
  }
  match execute(["check", app_dir]) {
    Ok(output) => assert_true(output.has_prefix("checked application"))
    Err(error) => abort(error.message)
  }
  assert_false(@fs.path_exists(database))
  match execute(["migrate", app_dir]) {
    Ok(output) => assert_true(output.contains("\"migrated\":1"))
    Err(error) => abort(error.message)
  }
  assert_true(@fs.path_exists(database))
  let created = match
    execute([
      "run", app_dir, "models.todo.Create", "{\"data\":{\"title\":\"from cli\"}}",
    ]) {
    Ok(output) => output
    Err(error) => abort(error.message)
  }
  assert_true(created.contains("\"title\":\"from cli\""))
  match execute(["run", app_dir, "models.todo.Find", "{\"id\":999}"]) {
    Err(error) => assert_eq(error.code, @errors.RecordNotFound)
    Ok(_) => abort("expected missing record")
  }
  @fs.remove_file(database)
}

///|
test "CLI rejects invalid JSON and unsupported command shapes" {
  match execute(["run", "example/todo", "models.todo.List", "{"]) {
    Err(error) => assert_eq(error.code, @errors.InvalidArgument)
    Ok(_) => abort("expected invalid JSON")
  }
  match execute(["migrate"]) {
    Err(error) => assert_eq(error.code, @errors.InvalidArgument)
    Ok(_) => abort("expected usage error")
  }
}
