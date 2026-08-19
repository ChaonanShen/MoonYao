///|
fn known(
  object : Map[String, Json],
  allowed : Array[String],
  path : String,
) -> Result[Unit, @errors.EngineError] {
  for key in object.keys() {
    if !allowed.contains(key) {
      return Err(@errors.invalid_argument("unknown field", path + "." + key))
    }
  }
  Ok(())
}

///|
fn required_string(
  object : Map[String, Json],
  key : String,
  path : String,
) -> Result[String, @errors.EngineError] {
  match object.get(key) {
    Some(String(value)) if value.length() > 0 => Ok(value)
    Some(_) =>
      Err(
        @errors.invalid_argument(
          "expected a non-empty string",
          path + "." + key,
        ),
      )
    None =>
      Err(@errors.invalid_argument("missing required field", path + "." + key))
  }
}

///|
fn role_json(role : Role) -> Json {
  match role {
    Developer => "developer"
    System => "system"
    User => "user"
    Assistant => "assistant"
    Tool => "tool"
  }
}

///|
fn parse_role(value : Json, path : String) -> Result[Role, @errors.EngineError] {
  match value {
    String("developer") => Ok(Developer)
    String("system") => Ok(System)
    String("user") => Ok(User)
    String("assistant") => Ok(Assistant)
    String("tool") => Ok(Tool)
    _ => Err(@errors.invalid_argument("invalid message role", path))
  }
}

///|
fn detail_json(detail : ImageDetail) -> Json {
  match detail {
    Auto => "auto"
    Low => "low"
    High => "high"
  }
}

///|
fn parse_detail(
  value : Json,
  path : String,
) -> Result[ImageDetail, @errors.EngineError] {
  match value {
    String("auto") => Ok(Auto)
    String("low") => Ok(Low)
    String("high") => Ok(High)
    _ => Err(@errors.invalid_argument("invalid image detail", path))
  }
}

///|
fn part_json(part : ContentPart) -> Json {
  match part {
    TextPart(text) => { "type": "text", "text": text }
    ImageRef(id, detail) =>
      { "type": "image", "attachment_id": id, "detail": detail_json(detail) }
    FileRef(id, filename) =>
      { "type": "file", "attachment_id": id, "filename": filename }
  }
}

///|
fn parse_part(
  value : Json,
  path : String,
) -> Result[ContentPart, @errors.EngineError] {
  guard value is Object(object) else {
    return Err(@errors.invalid_argument("expected an object", path))
  }
  let kind = match required_string(object, "type", path) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  match kind {
    "text" => {
      match known(object, ["type", "text"], path) {
        Err(e) => return Err(e)
        Ok(_) => ()
      }
      match required_string(object, "text", path) {
        Ok(v) => Ok(TextPart(v))
        Err(e) => Err(e)
      }
    }
    "image" => {
      match known(object, ["type", "attachment_id", "detail"], path) {
        Err(e) => return Err(e)
        Ok(_) => ()
      }
      let id = match required_string(object, "attachment_id", path) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let detail = match object.get("detail") {
        None => Auto
        Some(v) =>
          match parse_detail(v, path + ".detail") {
            Ok(d) => d
            Err(e) => return Err(e)
          }
      }
      Ok(ImageRef(id, detail))
    }
    "file" => {
      match known(object, ["type", "attachment_id", "filename"], path) {
        Err(e) => return Err(e)
        Ok(_) => ()
      }
      let id = match required_string(object, "attachment_id", path) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let filename = match object.get("filename") {
        None => "attachment"
        Some(String(v)) if v.length() > 0 => v
        Some(_) =>
          return Err(
            @errors.invalid_argument("expected a filename", path + ".filename"),
          )
      }
      Ok(FileRef(id, filename))
    }
    _ =>
      Err(@errors.invalid_argument("unsupported content part", path + ".type"))
  }
}

///|
fn content_json(content : MessageContent?) -> Json {
  match content {
    None => Json::null()
    Some(Text(value)) => Json::string(value)
    Some(Parts(values)) => Json::array(values.map(part_json))
  }
}

///|
fn parse_content(
  value : Json,
  path : String,
) -> Result[MessageContent?, @errors.EngineError] {
  match value {
    Null => Ok(None)
    String(text) => Ok(Some(Text(text)))
    Array(values) => {
      if values.is_empty() || values.length() > 16 {
        return Err(
          @errors.invalid_argument(
            "content parts must contain 1 to 16 items", path,
          ),
        )
      }
      let parts : Array[ContentPart] = []
      for index = 0; index < values.length(); index = index + 1 {
        match parse_part(values[index], path + "[" + index.to_string() + "]") {
          Ok(v) => parts.push(v)
          Err(e) => return Err(e)
        }
      }
      Ok(Some(Parts(parts)))
    }
    _ =>
      Err(@errors.invalid_argument("content must be a string or array", path))
  }
}

///|
fn tool_call_json(call : ToolCall) -> Json {
  {
    "id": call.id,
    "type": "function",
    "function": { "name": call.name, "arguments": call.arguments_json },
  }
}

///|
fn parse_tool_call(
  value : Json,
  path : String,
) -> Result[ToolCall, @errors.EngineError] {
  guard value is Object(object) else {
    return Err(@errors.invalid_argument("expected an object", path))
  }
  match known(object, ["id", "type", "function"], path) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let id = match required_string(object, "id", path) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  match object.get("type") {
    Some(String("function")) => ()
    _ =>
      return Err(
        @errors.invalid_argument(
          "tool call type must be function",
          path + ".type",
        ),
      )
  }
  let function = match object.get("function") {
    Some(Object(v)) => v
    _ =>
      return Err(
        @errors.invalid_argument("missing function", path + ".function"),
      )
  }
  match known(function, ["name", "arguments"], path + ".function") {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let name = match required_string(function, "name", path + ".function") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let args = match function.get("arguments") {
    Some(String(v)) => v
    _ =>
      return Err(
        @errors.invalid_argument(
          "arguments must be a string",
          path + ".function.arguments",
        ),
      )
  }
  Ok({ id, name, arguments_json: args })
}

///|
/// Encode a canonical message without provider-specific expansion.
pub fn encode(message : Message) -> Json {
  let object : Map[String, Json] = {
    "role": role_json(message.role),
    "content": content_json(message.content),
  }
  match message.name {
    Some(v) => object.set("name", Json::string(v))
    None => ()
  }
  match message.tool_call_id {
    Some(v) => object.set("tool_call_id", Json::string(v))
    None => ()
  }
  match message.reasoning_content {
    Some(v) => object.set("reasoning_content", Json::string(v))
    None => ()
  }
  if !message.tool_calls.is_empty() {
    object.set(
      "tool_calls",
      Json::array(message.tool_calls.map(tool_call_json)),
    )
  }
  match message.refusal {
    Some(v) => object.set("refusal", Json::string(v))
    None => ()
  }
  Json::object(object)
}

///|
/// Decode and strictly validate a canonical message.
pub fn decode(
  value : Json,
  path : String,
) -> Result[Message, @errors.EngineError] {
  guard value is Object(object) else {
    return Err(@errors.invalid_argument("message must be an object", path))
  }
  match
    known(
      object,
      [
        "role", "content", "name", "tool_call_id", "reasoning_content", "tool_calls",
        "refusal",
      ],
      path,
    ) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  let role = match object.get("role") {
    Some(v) =>
      match parse_role(v, path + ".role") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
    None =>
      return Err(
        @errors.invalid_argument("missing message role", path + ".role"),
      )
  }
  let content = match object.get("content") {
    Some(v) =>
      match parse_content(v, path + ".content") {
        Ok(v) => v
        Err(e) => return Err(e)
      }
    None => None
  }
  let name = match object.get("name") {
    None => None
    Some(String(v)) => Some(v)
    Some(_) =>
      return Err(
        @errors.invalid_argument("name must be a string", path + ".name"),
      )
  }
  let tool_call_id = match object.get("tool_call_id") {
    None => None
    Some(String(v)) => Some(v)
    Some(_) =>
      return Err(
        @errors.invalid_argument(
          "tool_call_id must be a string",
          path + ".tool_call_id",
        ),
      )
  }
  let reasoning_content = match object.get("reasoning_content") {
    None => None
    Some(String(v)) => Some(v)
    Some(_) =>
      return Err(
        @errors.invalid_argument(
          "reasoning_content must be a string",
          path + ".reasoning_content",
        ),
      )
  }
  let refusal = match object.get("refusal") {
    None => None
    Some(String(v)) => Some(v)
    Some(_) =>
      return Err(
        @errors.invalid_argument("refusal must be a string", path + ".refusal"),
      )
  }
  let tool_calls : Array[ToolCall] = []
  match object.get("tool_calls") {
    None => ()
    Some(Array(values)) => {
      if values.length() > 32 {
        return Err(
          @errors.invalid_argument("too many tool calls", path + ".tool_calls"),
        )
      }
      for index = 0; index < values.length(); index = index + 1 {
        match
          parse_tool_call(
            values[index],
            path + ".tool_calls[" + index.to_string() + "]",
          ) {
          Ok(v) => tool_calls.push(v)
          Err(e) => return Err(e)
        }
      }
    }
    Some(_) =>
      return Err(
        @errors.invalid_argument(
          "tool_calls must be an array",
          path + ".tool_calls",
        ),
      )
  }
  if role == Tool && tool_call_id is None {
    return Err(
      @errors.invalid_argument("tool messages require tool_call_id", path),
    )
  }
  if role != Assistant &&
    (
      !tool_calls.is_empty() ||
      reasoning_content is Some(_) ||
      refusal is Some(_)
    ) {
    return Err(
      @errors.invalid_argument("assistant fields require assistant role", path),
    )
  }
  Ok({
    role,
    content,
    name,
    tool_call_id,
    reasoning_content,
    tool_calls,
    refusal,
  })
}

///|
/// Convert an old text-only role/content pair into canonical form.
pub fn from_legacy(
  role : String,
  content : String,
) -> Result[Message, @errors.EngineError] {
  let parsed = parse_role(Json::string(role), "message.role")
  match parsed {
    Ok(role) => Ok(text_message(role, content))
    Err(e) => Err(e)
  }
}
