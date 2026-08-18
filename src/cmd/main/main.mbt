///|
fn usage_error() -> @errors.EngineError {
  @errors.invalid_argument(
    "usage: moonyao check <app-dir> | migrate <app-dir> | run <app-dir> <process> <json>",
    "$",
  )
}

///|
fn database_path(app_dir : String, configured : String) -> String {
  if configured.has_prefix("/") {
    configured
  } else {
    app_dir + "/" + configured
  }
}

///|
fn check_command(app_dir : String) -> Result[String, @errors.EngineError] {
  match @app.load(app_dir) {
    Ok(application) =>
      Ok(
        "checked application '\{application.name}' with \{application.models.length()} model(s)",
      )
    Err(error) => Err(error)
  }
}

///|
fn migrate_command(app_dir : String) -> Result[String, @errors.EngineError] {
  let application = match @app.load(app_dir) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let path = database_path(app_dir, application.database)
  let connection = match @sqlite.open_result(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  for model in application.models {
    match @model.migrate(connection, model) {
      Ok(_) => ()
      Err(error) => {
        ignore(@sqlite.close_result(connection))
        return Err(error)
      }
    }
  }
  match @sqlite.close_result(connection) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let output : Json = {
    "database": path,
    "migrated": application.models.length(),
  }
  Ok(output.stringify())
}

///|
fn run_process_command(
  app_dir : String,
  process : String,
  input_source : String,
) -> Result[String, @errors.EngineError] {
  let application = match @app.load(app_dir) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let input = @json.parse(input_source) catch {
    (_ : @json.ParseError) =>
      return Err(@errors.invalid_argument("input is not valid JSON", "$"))
  }
  let path = database_path(app_dir, application.database)
  if !@fs.path_exists(path) {
    return Err(
      @errors.database_error("database does not exist; run migrate first", path),
    )
  }
  let connection = match @sqlite.open_result(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let registry = @process.Registry::new(application.models)
  let result = registry.run(connection, process, input)
  let close_result = @sqlite.close_result(connection)
  match result {
    Err(error) => Err(error)
    Ok(output) =>
      match close_result {
        Err(error) => Err(error)
        Ok(_) => Ok(output.stringify())
      }
  }
}

///|
fn execute(args : Array[String]) -> Result[String, @errors.EngineError] {
  match args {
    ["check", app_dir] => check_command(app_dir)
    ["migrate", app_dir] => migrate_command(app_dir)
    ["run", app_dir, process, input] =>
      run_process_command(app_dir, process, input)
    ["bootstrap"] => Ok(@moonyao.bootstrap_message())
    _ => Err(usage_error())
  }
}

///|
fn main {
  let args = @env.args()
  let command_args = args[1:].to_owned()
  match execute(command_args) {
    Ok(output) => println(output)
    Err(error) => {
      println(error.to_json().stringify())
      if error.code == @errors.InvalidArgument {
        @sys.exit(2)
      } else {
        @sys.exit(1)
      }
    }
  }
}
