///|
pub(all) enum Role {
  System
  User
  Assistant
  Tool
} derive(Eq, Debug)

///|
pub(all) struct ChatMessage {
  role : Role
  content : String
} derive(Eq, Debug)

///|
pub(all) struct ChatRequest {
  model : String
  messages : Array[ChatMessage]
  temperature : Double
  max_tokens : Int
  stream : Bool
  tools : Array[ToolDefinition]
} derive(Debug)

///|
pub(all) struct ToolDefinition {
  name : String
  description : String
  input_schema : Json
} derive(Eq, Debug)

///|
pub(all) struct ToolCall {
  id : String
  name : String
  arguments_json : String
} derive(Eq, Debug)

///|
pub(all) struct Usage {
  prompt_tokens : Int
  completion_tokens : Int
} derive(Eq, Debug)

///|
pub(all) enum CompletionEvent {
  Started
  TextDelta(String)
  Usage(Usage)
  Completed
  Failed(String)
  ToolCallStarted(Int, String, String)
  ToolArgumentsDelta(Int, String)
  ToolCallCompleted(ToolCall)
  ToolStarted(String, String)
  ToolCompleted(String, String, Bool, String)
  HookStarted(String)
  HookCompleted(String)
} derive(Eq, Debug)

///|
pub(all) struct Connector {
  id : String
  connector_type : String
  base_url : String
  api_key_env : String
  model : String
  timeout_ms : Int
} derive(Eq, Debug)

///|
fn known_keys(
  object : Map[String, Json],
  allowed : Array[String],
  path : String,
) -> Result[Unit, @errors.EngineError] {
  for key in object.keys() {
    if !allowed.contains(key) {
      return Err(@errors.invalid_dsl("unknown key '\{key}'", path + "." + key))
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
      Err(@errors.invalid_dsl("expected a non-empty string", path + "." + key))
    None => Err(@errors.invalid_dsl("missing required key", path + "." + key))
  }
}

///|
fn resolve_env_reference(
  value : String,
  path : String,
) -> Result[String, @errors.EngineError] {
  if value.has_prefix("${") && value.has_suffix("}") {
    let expression = value[2:value.length() - 1].to_owned()
    let parts : Array[String] = []
    expression.split(":-").each(part => parts.push(part.to_owned()))
    if parts.length() > 2 {
      return Err(
        @errors.invalid_dsl("invalid environment variable reference", path),
      )
    }
    let name = parts[0]
    if !env_name(name) {
      return Err(
        @errors.invalid_dsl("invalid environment variable reference", path),
      )
    }
    match @env.get_env_var(name) {
      Some(resolved) if resolved.length() > 0 => Ok(resolved)
      _ if parts.length() == 2 && parts[1].length() > 0 => Ok(parts[1])
      _ => Err(@errors.invalid_dsl("environment variable is not set", path))
    }
  } else {
    Ok(value)
  }
}

///|
fn env_name(value : String) -> Bool {
  if value.length() == 0 {
    return false
  }
  for index = 0; index < value.length(); index = index + 1 {
    let character = value.code_unit_at(index).unsafe_to_char()
    let upper = character >= 'A' && character <= 'Z'
    let digit = character >= '0' && character <= '9'
    if !(upper || character == '_' || (index > 0 && digit)) {
      return false
    }
  }
  true
}

///|
fn valid_model(value : String) -> Bool {
  if value.length() == 0 || value.length() > 128 {
    return false
  }
  for character in value {
    let digit = character >= '0' && character <= '9'
    if !(character.is_ascii_alphabetic() ||
      digit ||
      character == '-' ||
      character == '_' ||
      character == '.' ||
      character == ':') {
      return false
    }
  }
  true
}

///|
fn valid_base_url(value : String) -> Bool {
  let secure = value.has_prefix("https://")
  let loopback = value.has_prefix("http://127.0.0.1:") ||
    value.has_prefix("http://localhost:")
  if !(secure || loopback) ||
    value.contains("?") ||
    value.contains("#") ||
    value.contains("@") {
    return false
  }
  let rest = if secure { value[8:].to_owned() } else { value[7:].to_owned() }
  rest.length() > 0 && !rest.has_prefix("/")
}

///|
pub fn parse_connector(
  value : Json,
  path : String,
) -> Result[Connector, @errors.EngineError] {
  guard value is Object(object) else {
    return Err(@errors.invalid_dsl("expected an object", path))
  }
  match
    known_keys(
      object,
      ["id", "type", "base_url", "api_key_env", "model", "timeout_ms"],
      path,
    ) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let id = match required_string(object, "id", path) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if id != "default" {
    return Err(
      @errors.invalid_dsl("connector id must be 'default'", path + ".id"),
    )
  }
  let connector_type = match required_string(object, "type", path) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if connector_type != "openai_chat" {
    return Err(
      @errors.invalid_dsl(
        "connector type must be 'openai_chat'",
        path + ".type",
      ),
    )
  }
  let mut base_url = match required_string(object, "base_url", path) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  base_url = match resolve_env_reference(base_url, path + ".base_url") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if !valid_base_url(base_url) {
    return Err(
      @errors.invalid_dsl("invalid connector base URL", path + ".base_url"),
    )
  }
  while base_url.has_suffix("/") {
    base_url = base_url[:base_url.length() - 1].to_owned()
  }
  let api_key_env = match required_string(object, "api_key_env", path) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let api_key_env = match
    resolve_env_reference(api_key_env, path + ".api_key_env") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if !env_name(api_key_env) {
    return Err(
      @errors.invalid_dsl(
        "invalid environment variable name",
        path + ".api_key_env",
      ),
    )
  }
  let model = match required_string(object, "model", path) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let model = match resolve_env_reference(model, path + ".model") {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if !valid_model(model) {
    return Err(@errors.invalid_dsl("invalid model name", path + ".model"))
  }
  let timeout_ms = match object.get("timeout_ms") {
    Some(Number(value, ..)) if value.to_int().to_double() == value =>
      value.to_int()
    Some(_) =>
      return Err(
        @errors.invalid_dsl("expected an integer", path + ".timeout_ms"),
      )
    None =>
      return Err(
        @errors.invalid_dsl("missing required key", path + ".timeout_ms"),
      )
  }
  if timeout_ms < 1000 || timeout_ms > 300000 {
    return Err(
      @errors.invalid_dsl(
        "timeout must be between 1000 and 300000",
        path + ".timeout_ms",
      ),
    )
  }
  Ok({ id, connector_type, base_url, api_key_env, model, timeout_ms })
}
