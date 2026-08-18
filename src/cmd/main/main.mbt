///|
fn usage_error() -> @errors.EngineError {
  @errors.invalid_argument(
    "usage: moonyao check <app-dir> | migrate <app-dir> | run <app-dir> <process> <json> | serve <app-dir> | agent chat <app-dir> <agent-id> <message> [--chat <chat-id>]",
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
        "checked application '\{application.name}' with \{application.models.length()} model(s), \{application.flows.length()} flow(s), and \{application.agents.length()} agent(s)",
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
  match @conversation.migrate(connection) {
    Ok(_) => ()
    Err(error) => {
      ignore(@sqlite.close_result(connection))
      return Err(error)
    }
  }
  match @sqlite.close_result(connection) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let output : Json = {
    "database": path,
    "migrated": application.models.length(),
    "conversation_schema": 1,
  }
  Ok(output.stringify())
}

///|
let id_random : @random.Rand = @random.Rand::new()

///|
fn write_hex(output : StringBuilder, value : UInt64) -> Unit {
  let alphabet = "0123456789abcdef"
  for index = 15; index >= 0; index = index - 1 {
    let digit = ((value >> (index * 4)) & 15UL).to_int()
    output.write_char(alphabet.code_unit_at(digit).unsafe_to_char())
  }
}

///|
fn random_id() -> Result[String, @errors.EngineError] {
  let output = StringBuilder::new()
  write_hex(output, id_random.uint64())
  write_hex(output, id_random.uint64())
  Ok(output.to_string())
}

///|
fn completion_event_json(event : @llm.CompletionEvent) -> Json {
  match event {
    @llm.Started => { "event": "turn.started" }
    @llm.TextDelta(content) => { "event": "message.delta", "content": content }
    @llm.Usage(usage) =>
      {
        "event": "usage",
        "prompt_tokens": usage.prompt_tokens,
        "completion_tokens": usage.completion_tokens,
      }
    @llm.Completed => { "event": "message.completed" }
    @llm.Failed(code) => { "event": "turn.failed", "code": code }
  }
}

///|
async fn agent_chat_command(
  app_dir : String,
  agent_id : String,
  message : String,
  chat_id : String?,
) -> Result[Array[String], @errors.EngineError] {
  let application = match @app.load(app_dir) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut selected : @agent.Agent? = None
  for agent in application.agents {
    if agent.id == agent_id {
      selected = Some(agent)
    }
  }
  let agent = match selected {
    Some(value) => value
    None => return Err(@errors.invalid_argument("agent was not found", "agent"))
  }
  let connector = match application.connector {
    Some(value) => value
    None =>
      return Err(
        @errors.invalid_dsl(
          "connector is not configured", "connectors/default.json",
        ),
      )
  }
  let api_key = match @env.get_env_var(connector.api_key_env) {
    Some(value) if value.length() > 0 => value
    _ => return Err(@errors.llm_error("connector API key is not configured"))
  }
  let path = database_path(app_dir, application.database)
  if !@fs.path_exists(path) {
    return Err(
      @errors.database_error(
        "database does not exist; run migrate first", "database",
      ),
    )
  }
  let connection = match @sqlite.open_result(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let now = @env.now().to_int()
  match @conversation.recover_active(connection, now) {
    Err(error) => {
      ignore(@sqlite.close_result(connection))
      return Err(error)
    }
    Ok(_) => ()
  }
  let ids : @agent.Ids = {
    chat_id: match random_id() {
      Ok(value) => value
      Err(error) => {
        ignore(@sqlite.close_result(connection))
        return Err(error)
      }
    },
    turn_id: match random_id() {
      Ok(value) => value
      Err(error) => {
        ignore(@sqlite.close_result(connection))
        return Err(error)
      }
    },
    user_message_id: match random_id() {
      Ok(value) => value
      Err(error) => {
        ignore(@sqlite.close_result(connection))
        return Err(error)
      }
    },
    assistant_message_id: match random_id() {
      Ok(value) => value
      Err(error) => {
        ignore(@sqlite.close_result(connection))
        return Err(error)
      }
    },
  }
  let result = @agent.run_turn(
    connection,
    agent,
    connector,
    @agent.OpenAI(connector, api_key),
    chat_id,
    message,
    ids,
    now,
    event => println(completion_event_json(event).stringify()),
  )
  let close_result = @sqlite.close_result(connection)
  match result {
    Err(error) => Err(error)
    Ok(turn) =>
      match close_result {
        Err(error) => Err(error)
        Ok(_) => {
          let lines : Array[String] = []
          let final_event : Json = {
            "event": "turn.completed",
            "chat_id": turn.chat_id,
            "turn_id": turn.turn_id,
            "content": turn.content,
            "history_truncated": turn.history_truncated,
          }
          lines.push(final_event.stringify())
          Ok(lines)
        }
      }
  }
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
  let chat_args : (String, String, String, String?)? = match command_args {
    ["agent", "chat", app_dir, agent_id, message] =>
      Some((app_dir, agent_id, message, None))
    ["agent", "chat", app_dir, agent_id, message, "--chat", chat_id] =>
      Some((app_dir, agent_id, message, Some(chat_id)))
    _ => None
  }
  match chat_args {
    Some((app_dir, agent_id, message, chat_id)) => {
      @async.run_async_main(() => {
        match agent_chat_command(app_dir, agent_id, message, chat_id) {
          Ok(lines) =>
            for line in lines {
              println(line)
            }
          Err(error) => {
            println(error.to_json().stringify())
            @sys.exit(if error.code == @errors.InvalidArgument { 2 } else { 1 })
          }
        }
      })
      return
    }
    None => ()
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
