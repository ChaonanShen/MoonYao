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
    "prompt_tokens": turn.prompt_tokens,
    "completion_tokens": turn.completion_tokens,
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
pub fn turn_input(value : Json) -> Result[String, @errors.EngineError] {
  let object = match strict_object(value, ["content"], "body") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  match object.get("content") {
    Some(String(value)) if value.length() >= 1 &&
      has_at_most_utf8_bytes(value, 65536) => Ok(value)
    _ =>
      Err(
        @errors.invalid_argument(
          "content must contain 1 to 65536 bytes", "body.content",
        ),
      )
  }
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
  Turn(String, String)
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
      let active = match @conversation.active_turn_id(connection, chat_id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if active.length() > 0 {
        return Err(@errors.turn_conflict())
      }
      Ok(Some(Turn(chat_id, content)))
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
    @llm.TextDelta(delta) => {
      base.set("message_id", Json::string(message_id))
      base.set("delta", Json::string(delta))
      Some(("message.delta", Json::object(base)))
    }
    @llm.Usage(_) => None
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
  #|      <div id="error" class="error" hidden></div>
  #|      <form id="composer"><textarea id="message-input" rows="3" maxlength="65536" placeholder="Message" disabled></textarea><button id="send" type="submit" disabled>Send</button></form>
  #|    </main>
  #|  </div>
  #|  <script src="/agent/app.js" defer></script>
  #|</body>
  #|</html>

///|
pub let agent_css : String =
  #|:root{color-scheme:light;--ink:#18211f;--muted:#65706d;--line:#d9dfdc;--paper:#fff;--soft:#f3f6f4;--accent:#167c5a;--accent-dark:#0f6045;--danger:#b63d36;--tool:#a65422;font-family:Inter,ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
  #|*{box-sizing:border-box}body{margin:0;color:var(--ink);background:var(--paper);font-size:14px}.topbar{height:58px;border-bottom:1px solid var(--line);display:flex;align-items:center;padding:0 20px;gap:11px;background:#fbfcfb}.brand-mark{width:32px;height:32px;display:grid;place-items:center;background:var(--ink);color:#fff;border-radius:6px;font-size:12px;font-weight:800}.topbar strong{display:block;font-size:15px}.topbar span{display:block;color:var(--muted);font-size:11px;margin-top:2px}.workspace{height:calc(100vh - 58px);display:grid;grid-template-columns:280px minmax(0,1fr)}.sidebar{border-right:1px solid var(--line);padding:18px 14px;overflow:auto;background:var(--soft)}label,.section-head{font-size:11px;font-weight:700;text-transform:uppercase;color:var(--muted);letter-spacing:0}select,textarea,button{font:inherit}select{width:100%;height:38px;border:1px solid #bfc8c4;background:#fff;border-radius:5px;padding:0 9px;margin:7px 0 20px}.section-head{display:flex;align-items:center;justify-content:space-between;margin-bottom:8px}button{border:1px solid #bfc8c4;background:#fff;color:var(--ink);border-radius:5px;padding:7px 10px;cursor:pointer}button:hover:not(:disabled){border-color:var(--accent);color:var(--accent-dark)}button:disabled{opacity:.45;cursor:not-allowed}.danger{color:var(--danger)}#chat-list{display:grid;gap:4px}.chat-item{width:100%;border-color:transparent;background:transparent;text-align:left;padding:9px}.chat-item.active{background:#fff;border-color:var(--line);box-shadow:0 1px 2px rgba(24,33,31,.05)}.chat-item span{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.chat-item small{display:block;color:var(--muted);margin-top:3px}.conversation{min-width:0;display:grid;grid-template-rows:auto minmax(0,1fr) auto auto}.conversation-head{min-height:76px;border-bottom:1px solid var(--line);padding:14px 20px;display:flex;align-items:center;justify-content:space-between;gap:16px}.conversation-head h1{font-size:17px;margin:0}.conversation-head p{font-size:12px;color:var(--muted);margin:4px 0 0}.actions{display:flex;gap:7px}.messages{overflow:auto;padding:22px max(20px,8vw);display:flex;flex-direction:column;gap:12px;background:#fcfdfc}.empty{margin:auto;color:var(--muted)}.message{max-width:760px;border-left:3px solid var(--line);padding:7px 11px;white-space:pre-wrap;overflow-wrap:anywhere}.message.user{align-self:flex-end;border-left:0;border-right:3px solid var(--accent);background:#eef8f3}.message.assistant{align-self:flex-start}.message.tool{align-self:flex-start;border-color:var(--tool);color:#633218;background:#fff7f0;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px}.message.failed{opacity:.65}.message .meta{display:block;color:var(--muted);font-size:10px;margin-bottom:4px;text-transform:uppercase}.error{margin:0 20px 10px;padding:9px 11px;border-left:3px solid var(--danger);background:#fff1f0;color:#7f2823}#composer{border-top:1px solid var(--line);padding:14px 20px;display:grid;grid-template-columns:minmax(0,1fr) auto;gap:10px;align-items:end}textarea{width:100%;resize:none;border:1px solid #bfc8c4;border-radius:5px;padding:10px 11px;line-height:1.4}#send{background:var(--accent);border-color:var(--accent);color:#fff;min-width:76px;height:42px}#send:hover:not(:disabled){background:var(--accent-dark);color:#fff}@media(max-width:760px){.workspace{grid-template-columns:1fr;grid-template-rows:190px minmax(0,1fr)}.sidebar{border-right:0;border-bottom:1px solid var(--line);padding:10px 14px}.sidebar select{margin-bottom:8px}.conversation-head{padding:10px 14px}.messages{padding:14px}.conversation-head p{display:none}#composer{padding:10px 14px}.topbar{height:52px}.workspace{height:calc(100vh - 52px)}}

///|
pub let agent_js : String =
  #|"use strict";
  #|const state={agents:[],chats:[],agentId:"",chatId:"",busy:false};
  #|const el=id=>document.getElementById(id);
  #|async function api(path,options={}){const response=await fetch(path,{...options,headers:{"Content-Type":"application/json",...(options.headers||{})}});const body=await response.json();if(!response.ok){const error=new Error(body.error?.message||"Request failed");error.requestId=response.headers.get("X-Request-Id");throw error}return body}
  #|function showError(error){const box=el("error");box.textContent=error.requestId?`${error.message} (${error.requestId})`:error.message;box.hidden=false}
  #|function clearError(){el("error").hidden=true;el("error").textContent=""}
  #|function setBusy(value){state.busy=value;el("send").disabled=value||!state.chatId;el("message-input").disabled=value||!state.chatId;el("new-chat").disabled=value;el("rename-chat").disabled=value||!state.chatId;el("delete-chat").disabled=value||!state.chatId}
  #|function node(tag,className,text){const value=document.createElement(tag);if(className)value.className=className;if(text!==undefined)value.textContent=text;return value}
  #|function renderAgents(){const select=el("agent-select");select.replaceChildren();for(const agent of state.agents){const option=node("option","",agent.name);option.value=agent.id;select.append(option)}select.value=state.agentId;const current=state.agents.find(item=>item.id===state.agentId);el("agent-description").textContent=current?.description||""}
  #|function renderChats(){const list=el("chat-list");list.replaceChildren();for(const chat of state.chats){const button=node("button",`chat-item${chat.id===state.chatId?" active":""}`);button.type="button";button.append(node("span","",chat.title||"Untitled"),node("small","",chat.active_turn_id?"Active":"Ready"));button.addEventListener("click",()=>openChat(chat.id));list.append(button)}}
  #|function renderMessage(message){const kind=message.kind==="tool_result"?"tool":message.role;const item=node("article",`message ${kind}${message.turn_status==="failed"?" failed":""}`);item.append(node("span","meta",kind));const content=typeof message.content==="string"?message.content:JSON.stringify(message.content,null,2);item.append(node("div","",content));el("messages").append(item);return item}
  #|async function loadChats(){const result=await api(`/v1/chats?agent_id=${encodeURIComponent(state.agentId)}&limit=100&offset=0`);state.chats=result.data;renderChats()}
  #|async function openChat(id){clearError();state.chatId=id;renderChats();const chat=state.chats.find(item=>item.id===id);el("chat-title").textContent=chat?.title||"Conversation";const history=await api(`/v1/chats/${encodeURIComponent(id)}/messages?limit=100&offset=0`);const messages=el("messages");messages.replaceChildren();for(const message of history.data)renderMessage(message);setBusy(Boolean(chat?.active_turn_id));messages.scrollTop=messages.scrollHeight}
  #|async function createChat(){clearError();const result=await api("/v1/chats",{method:"POST",body:JSON.stringify({agent_id:state.agentId,title:""})});await loadChats();await openChat(result.data.id)}
  #|async function renameChat(){const chat=state.chats.find(item=>item.id===state.chatId);const title=window.prompt("Conversation title",chat?.title||"");if(!title)return;await api(`/v1/chats/${encodeURIComponent(state.chatId)}`,{method:"PATCH",body:JSON.stringify({title})});await loadChats();el("chat-title").textContent=title}
  #|async function deleteChat(){if(!window.confirm("Delete this conversation?"))return;await api(`/v1/chats/${encodeURIComponent(state.chatId)}`,{method:"DELETE"});state.chatId="";el("chat-title").textContent="No conversation";el("messages").replaceChildren(node("div","empty","No conversation selected"));await loadChats();setBusy(false)}
  #|function processEvent(name,data,live){if(name==="message.delta"){live.textContent+=data.delta||""}else if(name==="tool.started"||name==="tool.completed"||name==="hook.started"||name==="hook.completed"){renderMessage({kind:"tool_result",role:"tool",turn_status:"active",content:{event:name,name:data.name,kind:data.kind,ok:data.ok,summary:data.summary,error:data.error}})}else if(name==="turn.failed"){throw new Error(data.error?.message||"Turn failed")}}
  #|async function streamTurn(content){const response=await fetch(`/v1/chats/${encodeURIComponent(state.chatId)}/turns`,{method:"POST",headers:{"Content-Type":"application/json","Accept":"text/event-stream"},body:JSON.stringify({content})});if(!response.ok){const body=await response.json();const error=new Error(body.error?.message||"Turn failed");error.requestId=response.headers.get("X-Request-Id");throw error}renderMessage({kind:"text",role:"user",turn_status:"active",content});const live=renderMessage({kind:"text",role:"assistant",turn_status:"active",content:""}).lastChild;const reader=response.body.getReader();const decoder=new TextDecoder();let buffer="";while(true){const {done,value}=await reader.read();if(done)break;buffer+=decoder.decode(value,{stream:true}).replaceAll("\r\n","\n");let boundary;while((boundary=buffer.indexOf("\n\n"))>=0){const block=buffer.slice(0,boundary);buffer=buffer.slice(boundary+2);if(block.startsWith(":"))continue;let name="message";let data="";for(const line of block.split("\n")){if(line.startsWith("event:"))name=line.slice(6).trim();if(line.startsWith("data:"))data+=line.slice(5).trim()}if(data)processEvent(name,JSON.parse(data),live)}}}
  #|async function send(event){event.preventDefault();const input=el("message-input");const content=input.value.trim();if(!content||state.busy)return;clearError();setBusy(true);input.value="";try{await streamTurn(content);await loadChats();await openChat(state.chatId)}catch(error){await openChat(state.chatId).catch(()=>{});showError(error)}finally{setBusy(false)}}
  #|async function init(){try{const health=await api("/v1/health");el("health").textContent=health.data.ready?"Ready":"Unavailable";const agents=await api("/v1/agents");state.agents=agents.data;state.agentId=state.agents[0]?.id||"";renderAgents();await loadChats();if(state.chats[0])await openChat(state.chats[0].id)}catch(error){showError(error)}}
  #|el("agent-select").addEventListener("change",async event=>{state.agentId=event.target.value;state.chatId="";renderAgents();await loadChats();if(state.chats[0])await openChat(state.chats[0].id)});el("new-chat").addEventListener("click",()=>createChat().catch(showError));el("rename-chat").addEventListener("click",()=>renameChat().catch(showError));el("delete-chat").addEventListener("click",()=>deleteChat().catch(showError));el("composer").addEventListener("submit",send);init();
