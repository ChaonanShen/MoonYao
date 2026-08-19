///|
pub fn success(data : Json) -> Json {
  { "data": data }
}

///|
pub fn paginated(data : Json, limit : Int, offset : Int, total : Int) -> Json {
  { "data": data, "meta": { "limit": limit, "offset": offset, "total": total } }
}

///|
pub fn status_code(error : @errors.EngineError) -> Int {
  if error.code == @errors.LlmError &&
    error.message == "provider request timed out" {
    return 504
  }
  match error.code {
    @errors.InvalidDsl | @errors.InvalidArgument => 400
    @errors.AgentNotFound | @errors.ChatNotFound | @errors.RouteNotFound => 404
    @errors.MethodNotAllowed => 405
    @errors.TurnConflict => 409
    @errors.TurnCancelled => 409
    @errors.TurnTimedOut => 504
    @errors.TurnInterrupted => 503
    @errors.TurnLimitExceeded => 422
    @errors.LlmError => 502
    @errors.ToolError | @errors.DatabaseError | @errors.InternalError => 500
    @errors.ModelNotFound
    | @errors.ProcessNotFound
    | @errors.FlowNotFound
    | @errors.RecordNotFound => 404
  }
}

///|
pub fn agent_json(agent : @agent.Agent) -> Json {
  let tools : Array[Json] = agent.tools.map(tool => {
    "name": tool.name,
    "description": tool.description,
  })
  {
    "id": agent.id,
    "name": agent.name,
    "description": agent.description,
    "tools": Json::array(tools),
  }
}

///|
pub fn chat_json(chat : @conversation.Chat, active_turn_id : String) -> Json {
  {
    "id": chat.id,
    "agent_id": chat.agent_id,
    "title": chat.title,
    "status": chat.status,
    "active_turn_id": if active_turn_id.length() > 0 {
      Json::string(active_turn_id)
    } else {
      Json::null()
    },
    "created_at": Json::number(chat.created_at.to_double()),
    "updated_at": Json::number(chat.updated_at.to_double()),
  }
}

///|
pub fn turn_json(turn : @conversation.Turn) -> Json {
  let result : Map[String, Json] = {
    "id": turn.id,
    "chat_id": turn.chat_id,
    "status": turn.status,
    "retry_of_turn_id": if turn.retry_of_turn_id.length() > 0 {
      Json::string(turn.retry_of_turn_id)
    } else {
      Json::null()
    },
    "attempt": turn.attempt,
    "prompt_tokens": turn.prompt_tokens,
    "completion_tokens": turn.completion_tokens,
    "cancel_requested_at": Json::number(turn.cancel_requested_at.to_double()),
    "deadline_at": Json::number(turn.deadline_at.to_double()),
    "started_at": Json::number(turn.started_at.to_double()),
    "finished_at": Json::number(turn.finished_at.to_double()),
  }
  if turn.error_code.length() > 0 {
    result.set("error", {
      "code": turn.error_code,
      "message": turn.error_message,
    })
  }
  Json::object(result)
}

///|
pub fn turn_event_json(event : @conversation.TurnEvent) -> Json {
  {
    "turn_id": event.turn_id,
    "sequence": event.sequence,
    "event": event.event,
    "data": event.data,
    "created_at": Json::number(event.created_at.to_double()),
  }
}

///|
pub fn message_json(value : @conversation.PublicMessage) -> Json {
  let message = value.message
  let content = if message.kind == "text" {
    Json::string(message.content)
  } else {
    @json.parse(message.content) catch {
      _ => Json::null()
    }
  }
  {
    "id": message.id,
    "chat_id": message.chat_id,
    "turn_id": message.turn_id,
    "sequence": message.sequence,
    "role": message.role,
    "kind": message.kind,
    "content": content,
    "status": message.status,
    "turn_status": value.turn_status,
    "created_at": Json::number(message.created_at.to_double()),
  }
}

///|
fn parse_non_negative(
  source : String,
  path : String,
) -> Result[Int, @errors.EngineError] {
  let value = @string.parse_int(source) catch {
    _ => return Err(@errors.invalid_argument("expected an integer", path))
  }
  if value < 0 {
    Err(@errors.invalid_argument("expected a non-negative integer", path))
  } else {
    Ok(value)
  }
}

///|
pub fn pagination(
  query : Map[String, String],
  allowed : Array[String],
) -> Result[(Int, Int), @errors.EngineError] {
  for key in query.keys() {
    if !allowed.contains(key) {
      return Err(
        @errors.invalid_argument("unknown query parameter", "query." + key),
      )
    }
  }
  let limit = match query.get("limit") {
    None => 20
    Some(source) =>
      match parse_non_negative(source, "query.limit") {
        Ok(value) => value
        Err(error) => return Err(error)
      }
  }
  let offset = match query.get("offset") {
    None => 0
    Some(source) =>
      match parse_non_negative(source, "query.offset") {
        Ok(value) => value
        Err(error) => return Err(error)
      }
  }
  if limit < 1 || limit > 100 {
    return Err(
      @errors.invalid_argument("limit must be between 1 and 100", "query.limit"),
    )
  }
  Ok((limit, offset))
}

///|
fn strict_object(
  value : Json,
  allowed : Array[String],
  path : String,
) -> Result[Map[String, Json], @errors.EngineError] {
  guard value is Object(object) else {
    return Err(@errors.invalid_argument("expected an object", path))
  }
  for key in object.keys() {
    if !allowed.contains(key) {
      return Err(@errors.invalid_argument("unknown field", path + "." + key))
    }
  }
  Ok(object)
}

///|
fn has_at_most_characters(value : String, maximum : Int) -> Bool {
  let mut count = 0
  for _ in value {
    count = count + 1
    if count > maximum {
      return false
    }
  }
  true
}

///|
fn has_at_most_utf8_bytes(value : String, maximum : Int) -> Bool {
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
    if bytes > maximum {
      return false
    }
  }
  true
}

///|
pub fn create_chat_input(
  value : Json,
) -> Result[(String, String), @errors.EngineError] {
  let object = match strict_object(value, ["agent_id", "title"], "body") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let agent_id = match object.get("agent_id") {
    Some(String(value)) if value.length() > 0 => value
    _ =>
      return Err(
        @errors.invalid_argument("agent_id is required", "body.agent_id"),
      )
  }
  let title = match object.get("title") {
    None => ""
    Some(String(value)) if has_at_most_characters(value, 200) => value
    _ =>
      return Err(@errors.invalid_argument("invalid chat title", "body.title"))
  }
  Ok((agent_id, title))
}

///|
pub fn rename_chat_input(value : Json) -> Result[String, @errors.EngineError] {
  let object = match strict_object(value, ["title"], "body") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  match object.get("title") {
    Some(String(value)) if value.length() >= 1 &&
      has_at_most_characters(value, 200) => Ok(value)
    _ =>
      Err(
        @errors.invalid_argument(
          "title must contain 1 to 200 characters", "body.title",
        ),
      )
  }
}

///|
pub(all) struct TurnInput {
  preview : String
  message : @content.Message
  canonical : Bool
  timeout_ms : Int
  metadata : Json
} derive(Eq, Debug)

///|
pub fn retry_turn_input(message : @content.Message) -> TurnInput {
  {
    preview: message_preview(message),
    message,
    canonical: true,
    timeout_ms: 300000,
    metadata: Json::object(Map([])),
  }
}

///|
fn stable_json_source(value : Json) -> String {
  match value {
    Object(object) => {
      let keys : Array[String] = []
      for key in object.keys() {
        keys.push(key)
      }
      keys.sort()
      let output = StringBuilder::new()
      output.write_char('{')
      for index = 0; index < keys.length(); index = index + 1 {
        if index > 0 {
          output.write_char(',')
        }
        output.write_string(Json::string(keys[index]).stringify())
        output.write_char(':')
        output.write_string(
          stable_json_source(object.get(keys[index]).unwrap()),
        )
      }
      output.write_char('}')
      output.to_string()
    }
    Array(items) => {
      let output = StringBuilder::new()
      output.write_char('[')
      for index = 0; index < items.length(); index = index + 1 {
        if index > 0 {
          output.write_char(',')
        }
        output.write_string(stable_json_source(items[index]))
      }
      output.write_char(']')
      output.to_string()
    }
    _ => value.stringify()
  }
}

///|
pub fn turn_request_hash(
  input : TurnInput,
  retry_source_turn_id : String,
) -> String {
  let canonical : Json = {
    "message": @content.encode(input.message),
    "metadata": input.metadata,
    "retry_source_turn_id": retry_source_turn_id,
    "timeout_ms": input.timeout_ms,
  }
  @crypto.bytes_to_hex_string(
    @crypto.sha256(@encoding.encode(UTF8, stable_json_source(canonical))),
  )
}

///|
pub fn validate_idempotency_key(
  key : String,
) -> Result[Unit, @errors.EngineError] {
  if key.length() < 1 || key.length() > 128 {
    return Err(
      @errors.invalid_argument(
        "Idempotency-Key must contain 1 to 128 ASCII characters", "headers.idempotency-key",
      ),
    )
  }
  for character in key {
    let code = character.to_int()
    let valid = (code >= 48 && code <= 57) ||
      (code >= 65 && code <= 90) ||
      (code >= 97 && code <= 122) ||
      [45, 46, 58, 95].contains(code)
    if !valid {
      return Err(
        @errors.invalid_argument(
          "Idempotency-Key contains an unsupported character", "headers.idempotency-key",
        ),
      )
    }
  }
  Ok(())
}

///|
pub fn event_cursor(
  source : String,
  path : String,
) -> Result[Int, @errors.EngineError] {
  parse_non_negative(source, path)
}

///|
pub fn turn_event_cursor(
  source : String,
  turn_id : String,
  path : String,
) -> Result[Int, @errors.EngineError] {
  let parts : Array[String] = []
  source.split(":").each(part => parts.push(part.to_owned()))
  match parts {
    [sequence] => event_cursor(sequence, path)
    [cursor_turn_id, sequence] => {
      if cursor_turn_id != turn_id {
        return Err(
          @errors.invalid_argument("event cursor belongs to another turn", path),
        )
      }
      event_cursor(sequence, path)
    }
    _ => Err(@errors.invalid_argument("invalid event cursor", path))
  }
}

///|
fn message_preview(message : @content.Message) -> String {
  match message.content {
    Some(@content.Text(value)) => value
    Some(@content.Parts(parts)) => {
      let output = StringBuilder::new()
      for part in parts {
        match part {
          @content.TextPart(value) => output.write_string(value)
          @content.ImageRef(_, _) => output.write_string(" [Image]")
          @content.FileRef(_, filename) =>
            output.write_string(" [File: " + filename + "]")
        }
      }
      output.to_string().trim().to_owned()
    }
    None => ""
  }
}

///|
pub fn turn_input(value : Json) -> Result[TurnInput, @errors.EngineError] {
  let object = match
    strict_object(value, ["content", "message", "options"], "body") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let (timeout_ms, metadata) = match object.get("options") {
    None => (300000, Json::object(Map([])))
    Some(raw) => {
      let options = match
        strict_object(raw, ["timeout_ms", "metadata"], "body.options") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let timeout_ms = match options.get("timeout_ms") {
        None => 300000
        Some(Number(value, ..)) if value.to_int().to_double() == value &&
          value >= 1000.0 &&
          value <= 300000.0 => value.to_int()
        _ =>
          return Err(
            @errors.invalid_argument(
              "timeout_ms must be an integer between 1000 and 300000", "body.options.timeout_ms",
            ),
          )
      }
      let metadata = match options.get("metadata") {
        None => Json::object(Map([]))
        Some(Object(value)) => {
          let encoded = Json::object(value)
          if encoded.stringify().length() > 32768 {
            return Err(
              @errors.invalid_argument(
                "metadata is too large", "body.options.metadata",
              ),
            )
          }
          encoded
        }
        Some(_) =>
          return Err(
            @errors.invalid_argument(
              "metadata must be an object", "body.options.metadata",
            ),
          )
      }
      (timeout_ms, metadata)
    }
  }
  match (object.get("content"), object.get("message")) {
    (Some(String(text)), None) if text.length() >= 1 &&
      has_at_most_utf8_bytes(text, 65536) =>
      Ok({
        preview: text,
        message: @content.text_message(@content.User, text),
        canonical: false,
        timeout_ms,
        metadata,
      })
    (None, Some(raw)) => {
      let message = match @content.decode(raw, "body.message") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      if message.role != @content.User {
        return Err(
          @errors.invalid_argument(
            "message role must be user", "body.message.role",
          ),
        )
      }
      let preview = message_preview(message)
      if preview.length() == 0 || !has_at_most_utf8_bytes(preview, 65536) {
        return Err(
          @errors.invalid_argument(
            "message must contain text or an attachment", "body.message",
          ),
        )
      }
      Ok({ preview, message, canonical: true, timeout_ms, metadata })
    }
    (Some(_), Some(_)) =>
      Err(
        @errors.invalid_argument("provide content or message, not both", "body"),
      )
    (Some(_), None) =>
      Err(
        @errors.invalid_argument(
          "content must contain 1 to 65536 bytes", "body.content",
        ),
      )
    _ => Err(@errors.invalid_argument("content or message is required", "body"))
  }
}

///|
pub fn attachment_json(value : @attachment.Attachment) -> Json {
  {
    "id": value.id,
    "filename": value.filename,
    "media_type": value.media_type,
    "byte_size": value.byte_size,
    "sha256": value.sha256,
    "kind": match value.kind {
      @attachment.Image => "image"
      @attachment.Text => "text"
    },
    "status": value.status,
    "created_at": Json::number(value.created_at.to_double()),
  }
}

///|
fn attachment_upload_input(
  value : Json,
) -> Result[(String, String, Bytes), @errors.EngineError] {
  let object = match
    strict_object(value, ["filename", "media_type", "data_base64"], "body") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let filename = match object.get("filename") {
    Some(String(v)) if v.length() > 0 => @attachment.safe_filename(v)
    _ =>
      return Err(
        @errors.invalid_argument("filename is required", "body.filename"),
      )
  }
  let media_type = match object.get("media_type") {
    Some(String(v)) if v.length() > 0 => v
    _ =>
      return Err(
        @errors.invalid_argument("media_type is required", "body.media_type"),
      )
  }
  let encoded = match object.get("data_base64") {
    Some(String(v)) if v.length() > 0 => v
    _ =>
      return Err(
        @errors.invalid_argument("data_base64 is required", "body.data_base64"),
      )
  }
  if encoded.length() > 14000000 {
    return Err(
      @errors.invalid_argument(
        "attachment body is too large", "body.data_base64",
      ),
    )
  }
  let data = @base64.decode(encoded) catch {
    _ =>
      return Err(
        @errors.invalid_argument("data_base64 is invalid", "body.data_base64"),
      )
  }
  Ok((filename, media_type, data))
}

///|
pub(all) struct PlatformResponse {
  status : Int
  content_type : String
  body : String
  location : String
} derive(Debug)

///|
pub(all) enum PlatformAction {
  Response(PlatformResponse)
  Turn(String, TurnInput)
  RetryTurn(String)
  ReplayEvents(String, Int)
  CancelTurn(String)
  UploadAttachment(String, String, Bytes, String)
} derive(Debug)

///|
fn response(status : Int, data : Json) -> PlatformAction {
  Response({
    status,
    content_type: "application/json; charset=utf-8",
    body: data.stringify(),
    location: "",
  })
}

///|
fn asset(content_type : String, body : String) -> PlatformAction {
  Response({ status: 200, content_type, body, location: "" })
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
fn chat_with_active(
  connection : @sqlite3.Connection,
  chat : @conversation.Chat,
) -> Result[Json, @errors.EngineError] {
  match @conversation.active_turn_id(connection, chat.id) {
    Ok(id) => Ok(chat_json(chat, id))
    Err(error) => Err(error)
  }
}

///|
fn path_segments(path : String) -> Result[Array[String], @errors.EngineError] {
  let result : Array[String] = []
  if !path.has_prefix("/") {
    return Err(@errors.invalid_argument("invalid request path", "path"))
  }
  path[1:].split("/").each(segment => result.push(segment.to_owned()))
  for index = 0; index < result.length(); index = index + 1 {
    result[index] = match percent_decode(result[index], "path") {
      Ok(value) => value
      Err(error) => return Err(error)
    }
  }
  Ok(result)
}

///|
pub fn dispatch_platform(
  agents : Array[@agent.Agent],
  connection : @sqlite3.Connection,
  verb : String,
  path : String,
  body : Json,
  query : Map[String, String],
  new_id : String,
  now : Int64,
) -> Result[PlatformAction?, @errors.EngineError] {
  if path == "/agent" {
    if verb != "GET" {
      return Err(@errors.method_not_allowed("GET"))
    }
    return Ok(
      Some(
        Response({
          status: 302,
          content_type: "text/plain; charset=utf-8",
          body: "Redirecting to /agent/",
          location: "/agent/",
        }),
      ),
    )
  }
  if path == "/agent/" || path == "/agent/app.js" || path == "/agent/style.css" {
    if verb != "GET" {
      return Err(@errors.method_not_allowed("GET"))
    }
    return Ok(
      Some(
        match path {
          "/agent/" => asset("text/html; charset=utf-8", agent_html)
          "/agent/app.js" => asset("text/javascript; charset=utf-8", agent_js)
          _ => asset("text/css; charset=utf-8", agent_css)
        },
      ),
    )
  }
  if path != "/v1" && !path.has_prefix("/v1/") && !path.has_prefix("/agent/") {
    return Ok(None)
  }
  if path.has_prefix("/agent/") {
    return Err(@errors.route_not_found(path))
  }
  let segments = match path_segments(path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match segments {
    ["v1", "attachments"] => {
      if verb != "POST" {
        return Err(@errors.method_not_allowed("POST"))
      }
      match pagination(query, []) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      let (filename, media_type, data) = match attachment_upload_input(body) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      Ok(Some(UploadAttachment(filename, media_type, data, "att_" + new_id)))
    }
    ["v1", "attachments", attachment_id] => {
      if verb != "GET" {
        return Err(@errors.method_not_allowed("GET"))
      }
      match pagination(query, []) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      let value = match @attachment.get(connection, attachment_id) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      Ok(Some(response(200, success(attachment_json(value)))))
    }
    ["v1", "health"] => {
      if verb != "GET" {
        return Err(@errors.method_not_allowed("GET"))
      }
      match pagination(query, []) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      Ok(
        Some(
          response(
            200,
            success({
              "ready": true,
              "version": "0.1.0",
              "agents": agents.length(),
            }),
          ),
        ),
      )
    }
    ["v1", "agents"] => {
      if verb != "GET" {
        return Err(@errors.method_not_allowed("GET"))
      }
      match pagination(query, []) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      let values : Array[Json] = []
      for agent in agents {
        values.push(agent_json(agent))
      }
      Ok(Some(response(200, success(Json::array(values)))))
    }
    ["v1", "agents", id] => {
      if verb != "GET" {
        return Err(@errors.method_not_allowed("GET"))
      }
      match pagination(query, []) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      let agent = match find_agent(agents, id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      Ok(Some(response(200, success(agent_json(agent)))))
    }
    ["v1", "chats"] if verb == "POST" => {
      match pagination(query, []) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      let (agent_id, title) = match create_chat_input(body) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      match find_agent(agents, agent_id) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      let chat = match
        @conversation.create_chat(connection, new_id, agent_id, title, now) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      Ok(Some(response(201, success(chat_json(chat, "")))))
    }
    ["v1", "chats"] if verb == "GET" => {
      let (limit, offset) = match
        pagination(query, ["agent_id", "limit", "offset"]) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let agent_id = query.get("agent_id").unwrap_or("")
      if agent_id.length() > 0 {
        match find_agent(agents, agent_id) {
          Err(error) => return Err(error)
          Ok(_) => ()
        }
      }
      let chats = match
        @conversation.list_chats_for_agent(connection, agent_id, limit, offset) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let total = match @conversation.count_chats(connection, agent_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let values : Array[Json] = []
      for chat in chats {
        values.push(
          match chat_with_active(connection, chat) {
            Ok(value) => value
            Err(error) => return Err(error)
          },
        )
      }
      Ok(
        Some(
          response(200, paginated(Json::array(values), limit, offset, total)),
        ),
      )
    }
    ["v1", "chats"] => Err(@errors.method_not_allowed("GET, POST"))
    ["v1", "chats", chat_id] => {
      match pagination(query, []) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      let chat = match @conversation.get_chat(connection, chat_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      match verb {
        "GET" => {
          let value = match chat_with_active(connection, chat) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          Ok(Some(response(200, success(value))))
        }
        "PATCH" => {
          let title = match rename_chat_input(body) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          match @conversation.rename_chat(connection, chat_id, title, now) {
            Err(error) => return Err(error)
            Ok(_) => ()
          }
          let renamed = match @conversation.get_chat(connection, chat_id) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          let value = match chat_with_active(connection, renamed) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          Ok(Some(response(200, success(value))))
        }
        "DELETE" => {
          match @conversation.delete_chat(connection, chat_id) {
            Err(error) => return Err(error)
            Ok(_) => ()
          }
          Ok(Some(response(200, success(chat_json(chat, "")))))
        }
        _ => Err(@errors.method_not_allowed("GET, PATCH, DELETE"))
      }
    }
    ["v1", "chats", chat_id, "messages"] => {
      if verb != "GET" {
        return Err(@errors.method_not_allowed("GET"))
      }
      let (limit, offset) = match
        pagination(query, ["limit", "offset", "include_internal"]) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      match query.get("include_internal") {
        Some("true") =>
          return Err(
            @errors.invalid_argument(
              "internal messages are not available", "query.include_internal",
            ),
          )
        Some("false") | None => ()
        Some(_) =>
          return Err(
            @errors.invalid_argument(
              "expected true or false", "query.include_internal",
            ),
          )
      }
      let messages = match
        @conversation.list_public_messages(connection, chat_id, limit, offset) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let total = match
        @conversation.count_public_messages(connection, chat_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let values : Array[Json] = []
      for message in messages {
        values.push(message_json(message))
      }
      Ok(
        Some(
          response(200, paginated(Json::array(values), limit, offset, total)),
        ),
      )
    }
    ["v1", "chats", chat_id, "turns"] => {
      if verb != "POST" {
        return Err(@errors.method_not_allowed("POST"))
      }
      match pagination(query, []) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      let content = match turn_input(body) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let chat = match @conversation.get_chat(connection, chat_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      match find_agent(agents, chat.agent_id) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      Ok(Some(Turn(chat_id, content)))
    }
    ["v1", "turns", turn_id] => {
      if verb != "GET" {
        return Err(@errors.method_not_allowed("GET"))
      }
      match pagination(query, []) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      let turn = match @conversation.get_turn(connection, turn_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      Ok(Some(response(200, success(turn_json(turn)))))
    }
    ["v1", "turns", turn_id, "cancel"] => {
      if verb != "POST" {
        return Err(@errors.method_not_allowed("POST"))
      }
      match pagination(query, []) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      match strict_object(body, [], "body") {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      match @conversation.get_turn(connection, turn_id) {
        Err(error) => return Err(error)
        Ok(_) => Ok(Some(CancelTurn(turn_id)))
      }
    }
    ["v1", "turns", turn_id, "retry"] => {
      if verb != "POST" {
        return Err(@errors.method_not_allowed("POST"))
      }
      match pagination(query, []) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      match strict_object(body, [], "body") {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      let turn = match @conversation.get_turn(connection, turn_id) {
        Err(error) => return Err(error)
        Ok(value) => value
      }
      if !["failed", "cancelled", "timed_out", "interrupted"].contains(
          turn.status,
        ) {
        return Err(@errors.turn_retry_conflict("turn status cannot be retried"))
      }
      Ok(Some(RetryTurn(turn_id)))
    }
    ["v1", "turns", turn_id, "events"] => {
      if verb != "GET" {
        return Err(@errors.method_not_allowed("GET"))
      }
      match @conversation.get_turn(connection, turn_id) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      for key in query.keys() {
        if key != "after" {
          return Err(
            @errors.invalid_argument("unknown query parameter", "query." + key),
          )
        }
      }
      let after = match query.get("after") {
        None => 0
        Some(source) =>
          match parse_non_negative(source, "query.after") {
            Ok(value) => value
            Err(error) => return Err(error)
          }
      }
      Ok(Some(ReplayEvents(turn_id, after)))
    }
    _ => Err(@errors.route_not_found(path))
  }
}

///|
pub fn sse_frame(id : Int, event : String, data : Json) -> String {
  "id: " +
  id.to_string() +
  "\nevent: " +
  event +
  "\ndata: " +
  data.stringify() +
  "\n\n"
}

///|
pub fn turn_sse_frame(
  turn_id : String,
  id : Int,
  event : String,
  data : Json,
) -> String {
  "id: " +
  turn_id +
  ":" +
  id.to_string() +
  "\nevent: " +
  event +
  "\ndata: " +
  data.stringify() +
  "\n\n"
}

///|
pub fn heartbeat() -> String {
  ": heartbeat\n\n"
}

///|
pub fn public_event(
  event : @llm.CompletionEvent,
  sequence : Int,
  chat_id : String,
  turn_id : String,
  message_id : String,
) -> (String, Json)? {
  let base : Map[String, Json] = {
    "sequence": sequence,
    "chat_id": chat_id,
    "turn_id": turn_id,
  }
  match event {
    @llm.Started => None
    @llm.ProviderRetrying(attempt, max_attempts, delay_ms, reason) => {
      base.set("attempt", Json::number(attempt.to_double()))
      base.set("max_attempts", Json::number(max_attempts.to_double()))
      base.set("delay_ms", Json::number(delay_ms.to_double()))
      base.set("reason", Json::string(reason))
      Some(("provider.retrying", Json::object(base)))
    }
    @llm.TextDelta(delta) => {
      base.set("message_id", Json::string(message_id))
      base.set("delta", Json::string(delta))
      Some(("message.delta", Json::object(base)))
    }
    @llm.Usage(usage) => {
      base.set("prompt_tokens", Json::number(usage.prompt_tokens.to_double()))
      base.set(
        "completion_tokens",
        Json::number(usage.completion_tokens.to_double()),
      )
      Some(("usage", Json::object(base)))
    }
    @llm.ToolStarted(id, name) => {
      base.set("tool_call_id", Json::string(id))
      base.set("name", Json::string(name))
      Some(("tool.started", Json::object(base)))
    }
    @llm.ToolCompleted(id, name, ok, summary) => {
      base.set("tool_call_id", Json::string(id))
      base.set("name", Json::string(name))
      base.set("ok", Json::boolean(ok))
      base.set(if ok { "summary" } else { "error" }, Json::string(summary))
      Some(("tool.completed", Json::object(base)))
    }
    @llm.HookStarted(kind) => {
      base.set("kind", Json::string(kind))
      Some(("hook.started", Json::object(base)))
    }
    @llm.HookCompleted(kind) => {
      base.set("kind", Json::string(kind))
      Some(("hook.completed", Json::object(base)))
    }
    @llm.Completed => None
    @llm.Failed(code) => {
      base.set("error", { "code": code, "message": "turn failed" })
      Some(("turn.failed", Json::object(base)))
    }
    @llm.Cancelled => Some(("turn.cancelled", Json::object(base)))
    @llm.TimedOut => Some(("turn.timed_out", Json::object(base)))
    @llm.Interrupted => Some(("turn.interrupted", Json::object(base)))
    @llm.CancellationPendingProcess(process) => {
      base.set("process", Json::string(process))
      Some(("turn.cancellation_pending_process", Json::object(base)))
    }
    @llm.ToolCallStarted(_, _, _)
    | @llm.ToolArgumentsDelta(_, _)
    | @llm.ToolCallCompleted(_) => None
  }
}

///|
pub let agent_html : String =
  #|<!doctype html>
  #|<html lang="en">
  #|<head>
  #|  <meta charset="utf-8">
  #|  <meta name="viewport" content="width=device-width,initial-scale=1">
  #|  <title>MoonYao Agent</title>
  #|  <link rel="stylesheet" href="/agent/style.css">
  #|</head>
  #|<body>
  #|  <header class="topbar"><div class="brand-mark">MY</div><div><strong>MoonYao Agent</strong><span id="health">Connecting</span></div></header>
  #|  <div class="workspace">
  #|    <aside class="sidebar">
  #|      <label for="agent-select">Agent</label><select id="agent-select"></select>
  #|      <div class="section-head"><span>Conversations</span><button id="new-chat" type="button">New</button></div>
  #|      <nav id="chat-list" aria-label="Conversations"></nav>
  #|    </aside>
  #|    <main class="conversation">
  #|      <div class="conversation-head"><div><h1 id="chat-title">No conversation</h1><p id="agent-description"></p></div><div class="actions"><button id="rename-chat" type="button" disabled>Rename</button><button id="delete-chat" class="danger" type="button" disabled>Delete</button></div></div>
  #|      <div id="messages" class="messages" aria-live="polite"><div class="empty">No conversation selected</div></div>
  #|      <div id="turn-controls" class="turn-controls" hidden><div><strong id="turn-status"></strong><span id="turn-note"></span></div><div class="turn-actions"><button id="cancel-turn" class="danger" type="button" hidden>Cancel</button><button id="retry-turn" type="button" hidden>Retry</button></div></div>
  #|      <div id="error" class="error" hidden></div>
  #|      <form id="composer"><div class="compose-main"><textarea id="message-input" rows="3" maxlength="65536" placeholder="Message" disabled></textarea><div class="attachment-row"><label class="file-picker" for="attachment-input">Attach</label><input id="attachment-input" type="file" multiple accept="image/png,image/jpeg,image/gif,image/webp,text/plain,text/markdown,application/json,text/csv" disabled><span id="attachment-summary"></span></div></div><button id="send" type="submit" disabled>Send</button></form>
  #|    </main>
  #|  </div>
  #|  <script src="/agent/app.js" defer></script>
  #|</body>
  #|</html>

///|
pub let agent_css : String =
  #|:root{color-scheme:light;--ink:#18211f;--muted:#65706d;--line:#d9dfdc;--paper:#fff;--soft:#f3f6f4;--accent:#167c5a;--accent-dark:#0f6045;--danger:#b63d36;--tool:#a65422;font-family:Inter,ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
  #|*{box-sizing:border-box}body{margin:0;color:var(--ink);background:var(--paper);font-size:14px}.topbar{height:58px;border-bottom:1px solid var(--line);display:flex;align-items:center;padding:0 20px;gap:11px;background:#fbfcfb}.brand-mark{width:32px;height:32px;display:grid;place-items:center;background:var(--ink);color:#fff;border-radius:6px;font-size:12px;font-weight:800}.topbar strong{display:block;font-size:15px}.topbar span{display:block;color:var(--muted);font-size:11px;margin-top:2px}.workspace{height:calc(100vh - 58px);display:grid;grid-template-columns:280px minmax(0,1fr)}.sidebar{border-right:1px solid var(--line);padding:18px 14px;overflow:auto;background:var(--soft)}label,.section-head{font-size:11px;font-weight:700;text-transform:uppercase;color:var(--muted);letter-spacing:0}select,textarea,button{font:inherit}select{width:100%;height:38px;border:1px solid #bfc8c4;background:#fff;border-radius:5px;padding:0 9px;margin:7px 0 20px}.section-head{display:flex;align-items:center;justify-content:space-between;margin-bottom:8px}button{border:1px solid #bfc8c4;background:#fff;color:var(--ink);border-radius:5px;padding:7px 10px;cursor:pointer}button:hover:not(:disabled){border-color:var(--accent);color:var(--accent-dark)}button:disabled{opacity:.45;cursor:not-allowed}.danger{color:var(--danger)}#chat-list{display:grid;gap:4px}.chat-item{width:100%;border-color:transparent;background:transparent;text-align:left;padding:9px}.chat-item.active{background:#fff;border-color:var(--line);box-shadow:0 1px 2px rgba(24,33,31,.05)}.chat-item span{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.chat-item small{display:block;color:var(--muted);margin-top:3px}.conversation{min-width:0;display:grid;grid-template-rows:auto minmax(0,1fr) auto auto auto}.conversation-head{min-height:76px;border-bottom:1px solid var(--line);padding:14px 20px;display:flex;align-items:center;justify-content:space-between;gap:16px}.conversation-head h1{font-size:17px;margin:0}.conversation-head p{font-size:12px;color:var(--muted);margin:4px 0 0}.actions,.turn-actions{display:flex;gap:7px}.messages{overflow:auto;padding:22px max(20px,8vw);display:flex;flex-direction:column;gap:12px;background:#fcfdfc}.empty{margin:auto;color:var(--muted)}.message{max-width:760px;border-left:3px solid var(--line);padding:7px 11px;white-space:pre-wrap;overflow-wrap:anywhere}.message.user{align-self:flex-end;border-left:0;border-right:3px solid var(--accent);background:#eef8f3}.message.assistant{align-self:flex-start}.message.tool{align-self:flex-start;border-color:var(--tool);color:#633218;background:#fff7f0;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px}.message.failed{opacity:.65}.message .meta{display:block;color:var(--muted);font-size:10px;margin-bottom:4px;text-transform:uppercase}.turn-controls{min-height:48px;margin:0 20px 10px;padding:8px 10px;border:1px solid var(--line);display:flex;align-items:center;justify-content:space-between;gap:12px;background:var(--soft)}.turn-controls[hidden]{display:none}.turn-controls strong{display:block;font-size:12px}.turn-controls span{display:block;color:var(--muted);font-size:11px;margin-top:2px}.error{margin:0 20px 10px;padding:9px 11px;border-left:3px solid var(--danger);background:#fff1f0;color:#7f2823}#composer{border-top:1px solid var(--line);padding:14px 20px;display:grid;grid-template-columns:minmax(0,1fr) auto;gap:10px;align-items:end}.compose-main{min-width:0}.attachment-row{display:flex;align-items:center;gap:8px;min-height:25px;padding-top:5px}.file-picker{border:1px solid #bfc8c4;border-radius:5px;padding:4px 8px;cursor:pointer;color:var(--ink);text-transform:none}.file-picker:hover{border-color:var(--accent);color:var(--accent-dark)}#attachment-input{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0,0,0,0)}#attachment-summary{color:var(--muted);font-size:11px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}textarea{width:100%;resize:none;border:1px solid #bfc8c4;border-radius:5px;padding:10px 11px;line-height:1.4}#send{background:var(--accent);border-color:var(--accent);color:#fff;min-width:76px;height:42px}#send:hover:not(:disabled){background:var(--accent-dark);color:#fff}@media(max-width:760px){.workspace{grid-template-columns:1fr;grid-template-rows:190px minmax(0,1fr)}.sidebar{border-right:0;border-bottom:1px solid var(--line);padding:10px 14px}.sidebar select{margin-bottom:8px}.conversation-head{padding:10px 14px}.messages{padding:14px}.conversation-head p{display:none}.turn-controls{margin:0 14px 8px;align-items:flex-start;flex-wrap:wrap}#composer{padding:10px 14px}.topbar{height:52px}.workspace{height:calc(100vh - 52px)}}

///|
pub let agent_js : String =
  #|"use strict";
  #|const terminalStatuses=new Set(["completed","failed","cancelled","timed_out","interrupted"]);const retryableStatuses=new Set(["failed","cancelled","timed_out","interrupted"]);
  #|const state={agents:[],chats:[],agentId:"",chatId:"",busy:false,activeTurnId:"",lastTurn:null,lastSequence:0,streamController:null,followToken:0,live:null};
  #|const el=id=>document.getElementById(id);
  #|async function responseError(response,fallback){let body={};try{body=await response.json()}catch(_){}const error=new Error(body.error?.message||fallback);error.requestId=response.headers.get("X-Request-Id");error.status=response.status;return error}
  #|async function api(path,options={}){const response=await fetch(path,{...options,headers:{"Content-Type":"application/json",...(options.headers||{})}});if(!response.ok)throw await responseError(response,"Request failed");return response.json()}
  #|function showError(error){const box=el("error");box.textContent=error.requestId?`${error.message} (${error.requestId})`:error.message;box.hidden=false}
  #|function clearError(){el("error").hidden=true;el("error").textContent=""}
  #|function statusLabel(status){return status?status.replaceAll("_"," ").replace(/^./,value=>value.toUpperCase()):""}
  #|function renderTurnControls(label=""){const turn=state.lastTurn;const active=Boolean(state.activeTurnId);const eligible=Boolean(turn&&retryableStatuses.has(turn.status));const controls=el("turn-controls");controls.hidden=!label&&!turn&&!active;el("turn-status").textContent=label||(active?"Running":statusLabel(turn?.status));el("turn-note").textContent=eligible?"Retry may repeat Process side effects":"";el("cancel-turn").hidden=!active;el("cancel-turn").disabled=!active||Boolean(turn?.cancel_requested_at);el("retry-turn").hidden=!eligible;el("retry-turn").disabled=state.busy||!eligible}
  #|function setBusy(value,label=""){state.busy=value;el("send").disabled=value||!state.chatId;el("message-input").disabled=value||!state.chatId;el("attachment-input").disabled=value||!state.chatId;el("new-chat").disabled=!state.agentId;el("rename-chat").disabled=value||!state.chatId;el("delete-chat").disabled=value||!state.chatId;renderTurnControls(label)}
  #|function setTurn(turn,label=""){state.lastTurn=turn||null;state.activeTurnId=turn?.status==="active"?turn.id:"";setBusy(Boolean(state.activeTurnId),label)}
  #|function node(tag,className,text){const value=document.createElement(tag);if(className)value.className=className;if(text!==undefined)value.textContent=text;return value}
  #|function renderAgents(){const select=el("agent-select");select.replaceChildren();for(const agent of state.agents){const option=node("option","",agent.name);option.value=agent.id;select.append(option)}select.value=state.agentId;const current=state.agents.find(item=>item.id===state.agentId);el("agent-description").textContent=current?.description||""}
  #|function renderChats(){const list=el("chat-list");list.replaceChildren();for(const chat of state.chats){const button=node("button",`chat-item${chat.id===state.chatId?" active":""}`);button.type="button";button.append(node("span","",chat.title||"Untitled"),node("small","",chat.active_turn_id?"Active":"Ready"));button.addEventListener("click",()=>openChat(chat.id).catch(showError));list.append(button)}}
  #|function messageText(content){if(typeof content==="string")return content;if(Array.isArray(content?.content))return content.content.map(part=>part.type==="text"?part.text:part.type==="image"?"[Image]":"[File: "+(part.filename||"attachment")+"]").join(" ");return JSON.stringify(content,null,2)}
  #|function renderMessage(message){const kind=message.kind==="tool_result"?"tool":message.role;const item=node("article",`message ${kind}${message.turn_status==="failed"?" failed":""}`);item.append(node("span","meta",kind));item.append(node("div","",messageText(message.content)));el("messages").append(item);return item}
  #|function ensureLive(){if(!state.live||!state.live.isConnected)state.live=renderMessage({kind:"text",role:"assistant",turn_status:"active",content:""}).lastChild;return state.live}
  #|async function loadChats(){const result=await api(`/v1/chats?agent_id=${encodeURIComponent(state.agentId)}&limit=100&offset=0`);state.chats=result.data;renderChats()}
  #|async function loadHistory(id){const history=await api(`/v1/chats/${encodeURIComponent(id)}/messages?limit=100&offset=0`);if(state.chatId!==id)return history.data;const messages=el("messages");messages.replaceChildren();for(const message of history.data)renderMessage(message);messages.scrollTop=messages.scrollHeight;state.live=null;return history.data}
  #|function stopStream(){state.followToken+=1;if(state.streamController)state.streamController.abort();state.streamController=null}
  #|function beginStream(turnId=""){stopStream();state.activeTurnId=turnId;state.lastSequence=0;state.live=null;return state.followToken}
  #|function streamController(token){const controller=new AbortController();if(token===state.followToken)state.streamController=controller;return controller}
  #|function pause(ms){return new Promise(resolve=>window.setTimeout(resolve,ms))}
  #|function processEvent(name,data){if(name==="message.delta"){ensureLive().textContent+=data.delta||""}else if(name==="tool.started"||name==="tool.completed"||name==="hook.started"||name==="hook.completed"){renderMessage({kind:"tool_result",role:"tool",turn_status:"active",content:{event:name,name:data.name,kind:data.kind,ok:data.ok,summary:data.summary,error:data.error}})}else if(name==="provider.retrying"){renderTurnControls(`Provider retry ${data.attempt||""}/${data.max_attempts||""}`)}else if(name==="turn.cancellation_pending_process"){renderTurnControls("Waiting for Process cancellation")}if(name.startsWith("turn.")&&name!=="turn.started"&&name!=="turn.cancellation_pending_process"){const status=name.slice(5);if(terminalStatuses.has(status)){setTurn(data.turn||{id:data.turn_id||state.activeTurnId,status,error:data.error});return true}}return false}
  #|function consumeBlock(block){if(!block||block.startsWith(":"))return false;let name="message",id="",lines=[];for(const line of block.split("\n")){if(line.startsWith("event:"))name=line.slice(6).trim();else if(line.startsWith("id:"))id=line.slice(3).trim();else if(line.startsWith("data:"))lines.push(line.slice(5).trimStart())}if(!lines.length)return false;const data=JSON.parse(lines.join("\n"));const separator=id.lastIndexOf(":");const turnId=data.turn_id||data.turn?.id||(separator>0?id.slice(0,separator):"");const sequence=Number(data.sequence||(separator>0?id.slice(separator+1):0));if(turnId&&!state.activeTurnId){state.activeTurnId=turnId;setBusy(true,"Running")}if(Number.isSafeInteger(sequence)&&sequence>0){if(sequence<=state.lastSequence)return false;state.lastSequence=sequence}return processEvent(name,data)}
  #|async function consumeSse(response,token){if(!response.body)throw new Error("Streaming response is unavailable");const reader=response.body.getReader();const decoder=new TextDecoder();let buffer="",terminal=false;while(token===state.followToken){const {done,value}=await reader.read();if(done)break;buffer+=decoder.decode(value,{stream:true}).replaceAll("\r\n","\n").replaceAll("\r","\n");let boundary;while((boundary=buffer.indexOf("\n\n"))>=0){const block=buffer.slice(0,boundary);buffer=buffer.slice(boundary+2);if(consumeBlock(block)){terminal=true;break}}if(terminal)break}return terminal}
  #|async function refreshTurn(chatId,turnId,token){if(token!==state.followToken)return;await loadChats();if(state.chatId!==chatId||token!==state.followToken)return;const history=await loadHistory(chatId);let turn=null;if(turnId){try{turn=(await api(`/v1/turns/${encodeURIComponent(turnId)}`)).data}catch(_){}}if(!turn){const lastId=[...history].reverse().find(message=>message.turn_id)?.turn_id;if(lastId)turn=(await api(`/v1/turns/${encodeURIComponent(lastId)}`)).data}if(state.chatId!==chatId||token!==state.followToken)return;setTurn(turn);if(turn?.error?.message)showError(new Error(turn.error.message))}
  #|async function followLoop(chatId,turnId,token){let delay=250;while(token===state.followToken){try{renderTurnControls(delay>250?"Reconnecting":"Running");const controller=streamController(token);const response=await fetch(`/v1/turns/${encodeURIComponent(turnId)}/events?after=${state.lastSequence}`,{headers:{"Accept":"text/event-stream"},signal:controller.signal});if(!response.ok)throw await responseError(response,"Could not resume turn");if(await consumeSse(response,token)){await refreshTurn(chatId,turnId,token);return}const current=(await api(`/v1/turns/${encodeURIComponent(turnId)}`)).data;if(current.status!=="active"){setTurn(current);await refreshTurn(chatId,turnId,token);return}}catch(error){if(error.name==="AbortError"||token!==state.followToken)return;if(error.status&&error.status<500)throw error}renderTurnControls("Reconnecting");await pause(delay);delay=Math.min(delay*2,4000)}}
  #|function followTurn(chatId,turnId){const token=beginStream(turnId);setBusy(true,"Running");followLoop(chatId,turnId,token).catch(error=>{if(token===state.followToken){setBusy(false);showError(error)}})}
  #|async function openChat(id){stopStream();clearError();state.chatId=id;state.lastTurn=null;state.activeTurnId="";state.lastSequence=0;state.live=null;renderChats();setBusy(false);const chat=state.chats.find(item=>item.id===id);el("chat-title").textContent=chat?.title||"Conversation";const history=await loadHistory(id);if(state.chatId!==id)return;if(chat?.active_turn_id){const turn=(await api(`/v1/turns/${encodeURIComponent(chat.active_turn_id)}`)).data;if(state.chatId!==id)return;setTurn(turn);followTurn(id,turn.id);return}const lastId=[...history].reverse().find(message=>message.turn_id)?.turn_id;if(lastId){const turn=(await api(`/v1/turns/${encodeURIComponent(lastId)}`)).data;if(state.chatId===id)setTurn(turn)}}
  #|async function createChat(){clearError();const result=await api("/v1/chats",{method:"POST",body:JSON.stringify({agent_id:state.agentId,title:""})});await loadChats();await openChat(result.data.id)}
  #|async function renameChat(){const chat=state.chats.find(item=>item.id===state.chatId);const title=window.prompt("Conversation title",chat?.title||"");if(!title)return;await api(`/v1/chats/${encodeURIComponent(state.chatId)}`,{method:"PATCH",body:JSON.stringify({title})});await loadChats();el("chat-title").textContent=title}
  #|async function deleteChat(){if(!window.confirm("Delete this conversation?"))return;stopStream();await api(`/v1/chats/${encodeURIComponent(state.chatId)}`,{method:"DELETE"});state.chatId="";state.lastTurn=null;state.activeTurnId="";el("chat-title").textContent="No conversation";el("messages").replaceChildren(node("div","empty","No conversation selected"));await loadChats();setBusy(false)}
  #|function idempotencyKey(){const random=globalThis.crypto?.randomUUID?.()||Math.random().toString(36).slice(2);return `cui-${Date.now()}-${random}`.slice(0,128)}
  #|async function submitTurn(path,body,display){const chatId=state.chatId;const token=beginStream();state.lastTurn=null;const key=idempotencyKey();clearError();setBusy(true,"Starting");if(display!==undefined){renderMessage({kind:"text",role:"user",turn_status:"active",content:display});state.live=renderMessage({kind:"text",role:"assistant",turn_status:"active",content:""}).lastChild}let delay=250;while(token===state.followToken){try{const controller=streamController(token);const response=await fetch(path,{method:"POST",headers:{"Content-Type":"application/json","Accept":"text/event-stream","Idempotency-Key":key},body:JSON.stringify(body),signal:controller.signal});if(!response.ok)throw await responseError(response,"Turn failed");if(await consumeSse(response,token)){await refreshTurn(chatId,state.lastTurn?.id||state.activeTurnId,token);return}if(state.activeTurnId){await followLoop(chatId,state.activeTurnId,token);return}}catch(error){if(error.name==="AbortError"||token!==state.followToken)return;if(state.activeTurnId){await followLoop(chatId,state.activeTurnId,token);return}if(error.requestId)throw error}renderTurnControls("Reconnecting");await pause(delay);delay=Math.min(delay*2,4000)}}
  #|function fileBase64(file){return new Promise((resolve,reject)=>{const reader=new FileReader();reader.onload=()=>resolve(String(reader.result).split(",",2)[1]||"");reader.onerror=()=>reject(new Error("Could not read "+file.name));reader.readAsDataURL(file)})}
  #|async function upload(file){const result=await api("/v1/attachments",{method:"POST",body:JSON.stringify({filename:file.name,media_type:file.type||"application/octet-stream",data_base64:await fileBase64(file)})});return result.data}
  #|async function send(event){event.preventDefault();const input=el("message-input");const picker=el("attachment-input");const content=input.value.trim();const files=Array.from(picker.files||[]);if((!content&&!files.length)||state.busy)return;if(files.length>8){showError(new Error("A turn accepts at most 8 attachments"));return}setBusy(true,"Uploading");try{let body,display;if(!files.length){body={content};display=content}else{const uploaded=[];for(const file of files)uploaded.push(await upload(file));const parts=[];if(content)parts.push({type:"text",text:content});for(const item of uploaded)parts.push(item.kind==="image"?{type:"image",attachment_id:item.id,detail:"auto"}:{type:"file",attachment_id:item.id,filename:item.filename});const message={role:"user",content:parts};body={message};display=message}input.value="";picker.value="";el("attachment-summary").textContent="";await submitTurn(`/v1/chats/${encodeURIComponent(state.chatId)}/turns`,body,display)}catch(error){if(state.chatId)await loadHistory(state.chatId).catch(()=>{});setBusy(false);showError(error)}}
  #|async function cancelTurn(){if(!state.activeTurnId)return;clearError();const turn=(await api(`/v1/turns/${encodeURIComponent(state.activeTurnId)}/cancel`,{method:"POST",body:"{}"})).data;setTurn(turn,turn.status==="active"?"Cancelling":"");if(turn.status!=="active")await refreshTurn(turn.chat_id,turn.id,state.followToken)}
  #|async function retryTurn(){const source=state.lastTurn;if(!source||!retryableStatuses.has(source.status)||state.busy)return;try{await submitTurn(`/v1/turns/${encodeURIComponent(source.id)}/retry`,{},undefined)}catch(error){setBusy(false);showError(error)}}
  #|async function init(){try{const health=await api("/v1/health");el("health").textContent=health.data.ready?"Ready":"Unavailable";const agents=await api("/v1/agents");state.agents=agents.data;state.agentId=state.agents[0]?.id||"";renderAgents();await loadChats();if(state.chats[0])await openChat(state.chats[0].id);else setBusy(false)}catch(error){showError(error)}}
  #|el("agent-select").addEventListener("change",async event=>{stopStream();state.agentId=event.target.value;state.chatId="";state.lastTurn=null;renderAgents();await loadChats();if(state.chats[0])await openChat(state.chats[0].id);else setBusy(false)});el("new-chat").addEventListener("click",()=>createChat().catch(showError));el("rename-chat").addEventListener("click",()=>renameChat().catch(showError));el("delete-chat").addEventListener("click",()=>deleteChat().catch(showError));el("cancel-turn").addEventListener("click",()=>cancelTurn().catch(showError));el("retry-turn").addEventListener("click",()=>retryTurn().catch(showError));el("attachment-input").addEventListener("change",event=>{const files=Array.from(event.target.files||[]);el("attachment-summary").textContent=files.map(file=>file.name).join(", ")});el("composer").addEventListener("submit",send);el("message-input").addEventListener("keydown",event=>{if(event.key==="Enter"&&!event.shiftKey&&!event.isComposing){event.preventDefault();el("composer").requestSubmit()}});init();
