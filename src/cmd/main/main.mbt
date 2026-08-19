///|
fn usage_error() -> @errors.EngineError {
  @errors.invalid_argument(
    "usage: moonyao check <app-dir> | migrate <app-dir> | run <app-dir> <process> <json> | serve <app-dir> | agent chat <app-dir> <agent-id> <message> [--chat <chat-id>]",
    "$",
  )
}

///|
fn dotenv_value(source : String) -> String {
  let value = source.trim().to_owned()
  if value.length() >= 2 {
    let first = value[0]
    let last = value[value.length() - 1]
    if (first == '"' && last == '"') || (first == '\'' && last == '\'') {
      return value[1:value.length() - 1].to_owned()
    }
  }
  value
}

///|
fn load_dotenv(path : String) -> Unit {
  let source = @fs.read_file_to_string(path) catch { _ => return }
  for raw_line in source.split("\n") {
    let line = raw_line.trim()
    if line.length() == 0 || line.has_prefix("#") {
      continue
    }
    let assignment = if line.has_prefix("export ") {
      line[7:].trim()
    } else {
      line
    }
    let parts : Array[String] = []
    assignment.split("=").each(part => parts.push(part.to_owned()))
    if parts.length() < 2 {
      continue
    }
    let key = parts[0].trim().to_owned()
    if key.length() == 0 || @env.get_env_var(key) is Some(_) {
      continue
    }
    let value = StringBuilder::new()
    for index = 1; index < parts.length(); index = index + 1 {
      if index > 1 {
        value.write_char('=')
      }
      value.write_string(parts[index])
    }
    @env.set_env_var(key, dotenv_value(value.to_string()))
  }
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
    "conversation_schema": 2,
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
    @llm.ToolCallStarted(index, id, name) =>
      {
        "event": "tool.arguments.started",
        "index": index,
        "tool_call_id": id,
        "name": name,
      }
    @llm.ToolArgumentsDelta(index, _) =>
      { "event": "tool.arguments.delta", "index": index }
    @llm.ToolCallCompleted(call) =>
      {
        "event": "tool.arguments.completed",
        "tool_call_id": call.id,
        "name": call.name,
      }
    @llm.ToolStarted(id, name) =>
      { "event": "tool.started", "tool_call_id": id, "name": name }
    @llm.ToolCompleted(id, name, ok, summary) =>
      {
        "event": "tool.completed",
        "tool_call_id": id,
        "name": name,
        "ok": ok,
        "summary": summary,
      }
    @llm.HookStarted(kind) => { "event": "hook.started", "kind": kind }
    @llm.HookCompleted(kind) => { "event": "hook.completed", "kind": kind }
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
  let now = @env.now().reinterpret_as_int64()
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
    (process, input) => {
      let registry = @process.Registry::with_flows(
        application.models,
        application.flows,
        application.globals,
      )
      registry.run(connection, process, input)
    },
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
fn find_agent(
  agents : Array[@agent.Agent],
  id : String,
) -> Result[@agent.Agent, @errors.EngineError] {
  for agent in agents {
    if agent.id == id {
      return Ok(agent)
    }
  }
  Err(@errors.agent_not_found())
}

///|
fn title_for_http(content : String) -> String {
  let output = StringBuilder::new()
  let mut count = 0
  for character in content {
    if count >= 80 {
      break
    }
    output.write_char(character)
    count = count + 1
  }
  output.to_string()
}

///|
fn request_id() -> String {
  match random_id() {
    Ok(value) => value
    Err(_) => "moonyao"
  }
}

///|
fn platform_headers(
  content_type : String,
  request_id : String,
) -> Map[String, String] {
  {
    "Content-Type": content_type,
    "X-Request-Id": request_id,
    "Content-Security-Policy": "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    "Cache-Control": "no-cache",
  }
}

///|
fn utf8_length(value : String) -> Int {
  let mut bytes = 0
  for character in value {
    let code = character.to_int()
    bytes = bytes +
      (if code <= 0x7f {
        1
      } else if code <= 0x7ff {
        2
      } else if code <= 0xffff {
        3
      } else {
        4
      })
  }
  bytes
}

///|
async fn send_platform_response(
  connection : @asynchttp.ServerConnection,
  response : @moonhttp.PlatformResponse,
  id : String,
) -> Unit {
  let headers = platform_headers(response.content_type, id)
  headers.set("Content-Length", utf8_length(response.body).to_string())
  if response.location.length() > 0 {
    headers.set("Location", response.location)
  }
  connection.send_response(
    response.status,
    if response.status == 200 || response.status == 201 {
      "OK"
    } else if response.status == 302 {
      "Found"
    } else {
      "Error"
    },
    extra_headers=headers,
  )
  connection.write_string(response.body)
  connection.end_response()
}

///|
async fn send_platform_error(
  connection : @asynchttp.ServerConnection,
  error : @errors.EngineError,
  id : String,
) -> Unit {
  let body = error.to_json().stringify()
  let headers = platform_headers("application/json; charset=utf-8", id)
  headers.set("Content-Length", utf8_length(body).to_string())
  if error.code == @errors.MethodNotAllowed {
    headers.set("Allow", error.path)
  }
  connection.send_response(
    @moonhttp.status_code(error),
    "Error",
    extra_headers=headers,
  )
  connection.write_string(body)
  connection.end_response()
}

///|
async fn run_http_turn(
  application : @app.Application,
  database : @sqlite3.Connection,
  chat_id : String,
  content : @moonhttp.TurnInput,
  attachment_root : String,
  stream : Bool,
  connection : @asynchttp.ServerConnection,
  id : String,
) -> Unit {
  let chat = match @conversation.get_chat(database, chat_id) {
    Ok(value) => value
    Err(error) => {
      send_platform_error(connection, error, id)
      return
    }
  }
  let selected = match find_agent(application.agents, chat.agent_id) {
    Ok(value) => value
    Err(error) => {
      send_platform_error(connection, error, id)
      return
    }
  }
  let connector = match application.connector {
    Some(value) => value
    None => {
      send_platform_error(
        connection,
        @errors.llm_error("connector is not configured"),
        id,
      )
      return
    }
  }
  let api_key = match @env.get_env_var(connector.api_key_env) {
    Some(value) if value.length() > 0 => value
    _ => {
      send_platform_error(
        connection,
        @errors.llm_error("connector API key is not configured"),
        id,
      )
      return
    }
  }
  let fresh_id = fn() -> String { request_id() }
  let ids : @agent.Ids = {
    chat_id: fresh_id(),
    turn_id: fresh_id(),
    user_message_id: fresh_id(),
    assistant_message_id: fresh_id(),
  }
  if chat.title.length() == 0 {
    match
      @conversation.rename_chat(
        database,
        chat_id,
        title_for_http(content.preview),
        @env.now().reinterpret_as_int64(),
      ) {
      Err(error) => {
        send_platform_error(connection, error, id)
        return
      }
      Ok(_) => ()
    }
  }
  let registry = @process.Registry::with_flows(
    application.models,
    application.flows,
    application.globals,
  )
  let wire_message : Json? = if content.canonical {
    match
      @llm.project_messages([content.message], attachment_id => {
        let metadata = match @attachment.get(database, attachment_id) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let data = match @attachment.read_local(attachment_root, metadata) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        Ok({
          id: metadata.id,
          filename: metadata.filename,
          media_type: metadata.media_type,
          data,
        })
      }) {
      Ok(values) => Some(values[0])
      Err(error) => {
        send_platform_error(connection, error, id)
        return
      }
    }
  } else {
    None
  }
  if !stream {
    let result = match wire_message {
      Some(wire) =>
        @agent.run_turn_message(
          database,
          selected,
          connector,
          @agent.OpenAI(connector, api_key),
          Some(chat_id),
          content.message,
          content.preview,
          wire,
          ids,
          @env.now().reinterpret_as_int64(),
          (process, input) => registry.run(database, process, input),
          _ => (),
        )
      None =>
        @agent.run_turn(
          database,
          selected,
          connector,
          @agent.OpenAI(connector, api_key),
          Some(chat_id),
          content.preview,
          ids,
          @env.now().reinterpret_as_int64(),
          (process, input) => registry.run(database, process, input),
          _ => (),
        )
    }
    match result {
      Err(error) => send_platform_error(connection, error, id)
      Ok(value) => {
        let current_chat = match @conversation.get_chat(database, chat_id) {
          Ok(item) => item
          Err(error) => {
            send_platform_error(connection, error, id)
            return
          }
        }
        let turn = match @conversation.get_turn(database, value.turn_id) {
          Ok(item) => item
          Err(error) => {
            send_platform_error(connection, error, id)
            return
          }
        }
        let body = @moonhttp.success({
          "chat": @moonhttp.chat_json(current_chat, ""),
          "turn": @moonhttp.turn_json(turn),
          "message": {
            "id": ids.assistant_message_id,
            "chat_id": chat_id,
            "turn_id": value.turn_id,
            "role": "assistant",
            "kind": "text",
            "content": value.content,
            "status": "completed",
          },
          "usage": {
            "prompt_tokens": value.usage.prompt_tokens,
            "completion_tokens": value.usage.completion_tokens,
          },
        }).stringify()
        send_platform_response(
          connection,
          {
            status: 200,
            content_type: "application/json; charset=utf-8",
            body,
            location: "",
          },
          id,
        )
      }
    }
    return
  }
  let headers = platform_headers("text/event-stream; charset=utf-8", id)
  headers.set("Connection", "keep-alive")
  headers.set("X-Accel-Buffering", "no")
  connection.send_response(200, "OK", extra_headers=headers)
  connection.flush()
  let frames : Array[String] = []
  let mut sequence = 1
  frames.push(
    @moonhttp.sse_frame(sequence, "turn.started", {
      "sequence": sequence,
      "chat_id": chat_id,
      "turn_id": ids.turn_id,
    }),
  )
  let mut terminal = false
  let mut done = false
  let mut open = true
  @async.with_task_group() <| group => {
    group.spawn_bg(allow_failure=true) <| () => {
      let mut index = 0
      let mut last_write = @env.now()
      while open && (!done || index < frames.length()) {
        if index < frames.length() {
          try {
            while index < frames.length() {
              connection.write_string(frames[index])
              index = index + 1
            }
            connection.flush()
            last_write = @env.now()
          } catch {
            _ => open = false
          }
        } else {
          @async.sleep(25)
          if @env.now() - last_write >= 15000 {
            try {
              connection.write_string(@moonhttp.heartbeat())
              connection.flush()
              last_write = @env.now()
            } catch {
              _ => open = false
            }
          }
        }
      }
    }
    let event_sink = fn(event : @llm.CompletionEvent) -> Unit {
      match
        @moonhttp.public_event(
          event,
          sequence + 1,
          chat_id,
          ids.turn_id,
          ids.assistant_message_id,
        ) {
        Some((name, data)) => {
          sequence = sequence + 1
          if name == "turn.failed" {
            terminal = true
          }
          frames.push(@moonhttp.sse_frame(sequence, name, data))
        }
        None => ()
      }
    }
    let result = match wire_message {
      Some(wire) =>
        @agent.run_turn_message(
          database,
          selected,
          connector,
          @agent.OpenAI(connector, api_key),
          Some(chat_id),
          content.message,
          content.preview,
          wire,
          ids,
          @env.now().reinterpret_as_int64(),
          (process, input) => registry.run(database, process, input),
          event_sink,
        )
      None =>
        @agent.run_turn(
          database,
          selected,
          connector,
          @agent.OpenAI(connector, api_key),
          Some(chat_id),
          content.preview,
          ids,
          @env.now().reinterpret_as_int64(),
          (process, input) => registry.run(database, process, input),
          event_sink,
        )
    }
    match result {
      Ok(value) => {
        sequence = sequence + 1
        frames.push(
          @moonhttp.sse_frame(sequence, "message.completed", {
            "sequence": sequence,
            "chat_id": chat_id,
            "turn_id": value.turn_id,
            "message": {
              "id": ids.assistant_message_id,
              "role": "assistant",
              "kind": "text",
              "content": value.content,
              "status": "completed",
            },
          }),
        )
        sequence = sequence + 1
        let turn = match @conversation.get_turn(database, value.turn_id) {
          Ok(item) => @moonhttp.turn_json(item)
          Err(_) =>
            { "id": value.turn_id, "chat_id": chat_id, "status": "completed" }
        }
        frames.push(
          @moonhttp.sse_frame(sequence, "turn.completed", {
            "sequence": sequence,
            "chat_id": chat_id,
            "turn_id": value.turn_id,
            "turn": turn,
            "usage": {
              "prompt_tokens": value.usage.prompt_tokens,
              "completion_tokens": value.usage.completion_tokens,
            },
          }),
        )
      }
      Err(error) if !terminal => {
        sequence = sequence + 1
        frames.push(
          @moonhttp.sse_frame(sequence, "turn.failed", {
            "sequence": sequence,
            "chat_id": chat_id,
            "turn_id": ids.turn_id,
            "error": {
              "code": error.code.as_string(),
              "message": error.message,
            },
          }),
        )
      }
      Err(_) => ()
    }
    done = true
  }
  if open {
    connection.end_response() catch {
      _ => ()
    }
  }
}

///|
async fn serve_command(app_dir : String) -> Unit {
  let application = match @app.load(app_dir) {
    Ok(value) => value
    Err(error) => abort(error.to_json().stringify())
  }
  let path = database_path(app_dir, application.database)
  let data_root = app_dir + "/data"
  let attachments_root = data_root + "/attachments"
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
      15000000 {
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
    let id = request_id()
    let platform = match (parsed, query) {
      (Err(error), _) | (_, Err(error)) => Err(error)
      (Ok(value), Ok(query_values)) =>
        @moonhttp.dispatch_platform(
          application.agents,
          database,
          request_verb(request.meth),
          path_parts[0],
          value,
          query_values,
          request_id(),
          @env.now().reinterpret_as_int64(),
        )
    }
    match platform {
      Err(error) => {
        ignore(@sqlite.close_result(database))
        if path_parts[0] == "/v1" ||
          path_parts[0].has_prefix("/v1/") ||
          path_parts[0] == "/agent" ||
          path_parts[0].has_prefix("/agent/") {
          send_platform_error(connection, error, id)
        } else {
          let response = error.to_json().stringify()
          let response_headers = {
            "Content-Type": "application/json; charset=utf-8",
            "Content-Length": utf8_length(response).to_string(),
            "X-Request-Id": id,
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
      Ok(Some(@moonhttp.Response(response))) => {
        ignore(@sqlite.close_result(database))
        send_platform_response(connection, response, id)
      }
      Ok(
        Some(
          @moonhttp.UploadAttachment(filename, media_type, data, attachment_id)
        )
      ) => {
        let kind = match @attachment.classify(data, media_type) {
          Ok(value) => value
          Err(error) => {
            ignore(@sqlite.close_result(database))
            send_platform_error(connection, error, id)
            return
          }
        }
        if !@fs.path_exists(data_root) {
          @fs.create_dir(data_root) catch {
            _ => {
              ignore(@sqlite.close_result(database))
              send_platform_error(
                connection,
                @errors.internal_error(
                  "could not create data directory", "attachment",
                ),
                id,
              )
              return
            }
          }
        }
        if !@fs.path_exists(attachments_root) {
          @fs.create_dir(attachments_root) catch {
            _ => {
              ignore(@sqlite.close_result(database))
              send_platform_error(
                connection,
                @errors.internal_error(
                  "could not create attachment directory", "attachment",
                ),
                id,
              )
              return
            }
          }
        }
        let storage_key = match @attachment.storage_key(attachment_id) {
          Ok(value) => value
          Err(error) => {
            ignore(@sqlite.close_result(database))
            send_platform_error(connection, error, id)
            return
          }
        }
        let value : @attachment.Attachment = {
          id: attachment_id,
          storage_key,
          filename,
          media_type,
          byte_size: data.length(),
          sha256: @attachment.digest(data),
          kind,
          status: "ready",
          created_at: @env.now().reinterpret_as_int64(),
          deleted_at: 0,
        }
        match @attachment.write_local(attachments_root, value, data) {
          Err(error) => {
            ignore(@sqlite.close_result(database))
            send_platform_error(connection, error, id)
          }
          Ok(_) =>
            match @attachment.insert(database, value) {
              Err(error) => {
                @fs.remove_file(attachments_root + "/" + storage_key) catch {
                  _ => ()
                }
                ignore(@sqlite.close_result(database))
                send_platform_error(connection, error, id)
              }
              Ok(_) => {
                ignore(@sqlite.close_result(database))
                send_platform_response(
                  connection,
                  {
                    status: 201,
                    content_type: "application/json; charset=utf-8",
                    body: @moonhttp.success(@moonhttp.attachment_json(value)).stringify(),
                    location: "",
                  },
                  id,
                )
              }
            }
        }
      }
      Ok(Some(@moonhttp.Turn(chat_id, content))) => {
        let stream = match request.headers.get("accept") {
          Some(value) => value.contains("text/event-stream")
          None => false
        }
        run_http_turn(
          application, database, chat_id, content, attachments_root, stream, connection,
          id,
        )
        ignore(@sqlite.close_result(database))
      }
      Ok(None) => {
        let registry = @process.Registry::with_flows(
          application.models,
          application.flows,
          application.globals,
        )
        let result = match (parsed, query) {
          (Ok(value), Ok(query_values)) =>
            @moonhttp.invoke(routes, registry, database, {
              verb: request_verb(request.meth),
              path: path_parts[0],
              body: value,
              query: query_values,
              headers: request.headers,
            })
          _ => abort("validated request was unavailable")
        }
        ignore(@sqlite.close_result(database))
        match result {
          Ok(output) => {
            let response = output.stringify()
            connection.send_response(200, "OK", extra_headers={
              "Content-Type": "application/json; charset=utf-8",
              "Content-Length": utf8_length(response).to_string(),
              "X-Request-Id": id,
            })
            connection.write_string(response)
            connection.end_response()
          }
          Err(error) => {
            let response = error.to_json().stringify()
            let response_headers = {
              "Content-Type": "application/json; charset=utf-8",
              "Content-Length": utf8_length(response).to_string(),
              "X-Request-Id": id,
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
  load_dotenv(".env.local")
  load_dotenv(".env")
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
