///|
fn usage_error() -> @errors.EngineError {
  @errors.invalid_argument(
    "usage: moonyao check <app-dir> | migrate <app-dir> | run <app-dir> <process> <json> | serve <app-dir>",
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
        "checked application '\{application.name}' with \{application.models.length()} model(s) and \{application.flows.length()} flow(s)",
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
  let registry = @process.Registry::with_flows(
    application.models,
    application.flows,
    application.globals,
  )
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
fn all_routes(application : @app.Application) -> Array[@moonhttp.Route] {
  let routes : Array[@moonhttp.Route] = []
  for api in application.apis {
    for route in api.routes {
      routes.push(route)
    }
  }
  routes
}

///|
fn request_verb(value : @asynchttp.RequestMethod) -> String {
  match value {
    @asynchttp.Get => "GET"
    @asynchttp.Post => "POST"
    @asynchttp.Patch => "PATCH"
    @asynchttp.Delete => "DELETE"
    _ => ""
  }
}

///|
async fn serve_command(app_dir : String) -> Unit {
  let application = match @app.load(app_dir) {
    Ok(value) => value
    Err(error) => abort(error.to_json().stringify())
  }
  let path = database_path(app_dir, application.database)
  if !@fs.path_exists(path) {
    abort(
      @errors.database_error(
        "database does not exist; run migrate first", "database",
      )
      .to_json()
      .stringify(),
    )
  }
  let server = @asynchttp.Server(@socket.Addr::parse(application.listen))
  let routes = all_routes(application)
  server.run_forever(allow_failure=true) <| ((request, body, connection) => {
    let body_source = match request.meth {
      @asynchttp.Post | @asynchttp.Patch => body.read_all().text()
      _ => ""
    }
    let parsed : Result[Json, @errors.EngineError] = if body_source.length() >
      1048576 {
      Err(@errors.invalid_argument("request body is too large", "body"))
    } else if request.meth == @asynchttp.Post ||
      request.meth == @asynchttp.Patch {
      match request.headers.get("content-type") {
        Some(value) if value.has_prefix("application/json") =>
          Ok(@json.parse(body_source)) catch {
            _ =>
              Err(
                @errors.invalid_argument(
                  "request body is not valid JSON", "body",
                ),
              )
          }
        _ =>
          Err(
            @errors.invalid_argument(
              "content-type must be application/json", "headers.content-type",
            ),
          )
      }
    } else {
      Ok(Json::object(Map([])))
    }
    let path_parts : Array[String] = []
    request.path.split("?").each(part => path_parts.push(part.to_owned()))
    let query = if path_parts.length() == 2 {
      @moonhttp.parse_query(path_parts[1])
    } else {
      Ok(Map([]))
    }
    let database = match @sqlite.open_result(path) {
      Ok(value) => value
      Err(error) => abort(error.message)
    }
    let registry = @process.Registry::with_flows(
      application.models,
      application.flows,
      application.globals,
    )
    let result = match (parsed, query) {
      (Err(error), _) | (_, Err(error)) => Err(error)
      (Ok(value), Ok(query_values)) =>
        @moonhttp.invoke(routes, registry, database, {
          verb: request_verb(request.meth),
          path: path_parts[0],
          body: value,
          query: query_values,
          headers: request.headers,
        })
    }
    ignore(@sqlite.close_result(database))
    match result {
      Ok(output) => {
        let response = output.stringify()
        connection.send_response(200, "OK", extra_headers={
          "Content-Type": "application/json; charset=utf-8",
          "Content-Length": response.length().to_string(),
          "X-Request-Id": "moonyao",
        })
        connection.write_string(response)
        connection.end_response()
      }
      Err(error) => {
        let response = error.to_json().stringify()
        let response_headers = {
          "Content-Type": "application/json; charset=utf-8",
          "Content-Length": response.length().to_string(),
          "X-Request-Id": "moonyao",
        }
        if error.code == @errors.MethodNotAllowed {
          response_headers.set("Allow", error.path)
        }
        connection.send_response(
          @moonhttp.status_for(error),
          "Error",
          extra_headers=response_headers,
        )
        connection.write_string(response)
        connection.end_response()
      }
    }
  })
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
  if command_args.length() == 2 && command_args[0] == "serve" {
    @async.run_async_main(() => serve_command(command_args[1]))
    return
  }
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
