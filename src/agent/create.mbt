///|
pub(all) struct CreateDecision {
  messages : Array[@content.Message]
  connector_id : String
  temperature : Double
  max_tokens : Int
  context : TurnContextSnapshot
  snapshot : Json
} derive(Eq, Debug)

///|
fn create_error(message : String, path : String) -> @errors.EngineError {
  @errors.invalid_argument(message, "create." + path)
}

///|
fn strict_create_object(
  value : Json,
  allowed : Array[String],
  path : String,
) -> Result[Map[String, Json], @errors.EngineError] {
  guard value is Object(object) else {
    return Err(create_error("expected an object", path))
  }
  for key in object.keys() {
    if !allowed.contains(key) {
      return Err(create_error("unknown field", path + "." + key))
    }
  }
  Ok(object)
}

///|
fn message_attachments(message : @content.Message) -> Array[String] {
  let ids : Array[String] = []
  match message.content {
    Some(@content.Parts(parts)) =>
      for part in parts {
        match part {
          @content.ImageRef(id, _) | @content.FileRef(id, _) =>
            if !ids.contains(id) {
              ids.push(id)
            }
          _ => ()
        }
      }
    _ => ()
  }
  ids
}

///|
fn allowed_attachments(messages : Array[@content.Message]) -> Array[String] {
  let ids : Array[String] = []
  for message in messages {
    for id in message_attachments(message) {
      if !ids.contains(id) {
        ids.push(id)
      }
    }
  }
  ids
}

///|
fn validate_create_messages(
  value : Json,
  allowed_ids : Array[String],
) -> Result[Array[@content.Message], @errors.EngineError] {
  guard value is Array(items) else {
    return Err(create_error("messages must be an array", "messages"))
  }
  if items.length() < 1 || items.length() > 100 {
    return Err(
      create_error(
        "messages must contain between 1 and 100 entries", "messages",
      ),
    )
  }
  let messages : Array[@content.Message] = []
  let mut bytes = 0
  for index = 0; index < items.length(); index = index + 1 {
    let message = match
      @content.decode(
        items[index],
        "create.messages[" + index.to_string() + "]",
      ) {
      Ok(parsed) => parsed
      Err(error) => return Err(error)
    }
    bytes = bytes + @content.encode(message).stringify().length()
    if bytes > 262144 {
      return Err(create_error("messages are too large", "messages"))
    }
    for id in message_attachments(message) {
      if !allowed_ids.contains(id) {
        return Err(
          create_error(
            "hook introduced an unknown attachment reference", "messages",
          ),
        )
      }
    }
    messages.push(message)
  }
  Ok(messages)
}

///|
fn merge_metadata(
  base : Json,
  update : Json,
) -> Result[Json, @errors.EngineError] {
  guard base is Object(base_object) else {
    return Err(
      create_error("context metadata must be an object", "context.metadata"),
    )
  }
  guard update is Object(update_object) else {
    return Err(
      create_error("context metadata must be an object", "context.metadata"),
    )
  }
  let merged : Map[String, Json] = Map([])
  for entry in base_object {
    let (key, value) = entry
    merged.set(key, value)
  }
  for entry in update_object {
    let (key, value) = entry
    merged.set(key, value)
  }
  let value = Json::object(merged)
  if value.stringify().length() > 32768 {
    return Err(
      create_error("context metadata is too large", "context.metadata"),
    )
  }
  Ok(value)
}

///|
fn optional_context_string(
  object : Map[String, Json],
  key : String,
  fallback : String,
) -> Result[String, @errors.EngineError] {
  match object.get(key) {
    None => Ok(fallback)
    Some(String(value)) if value.length() <= 128 => Ok(value)
    Some(_) =>
      Err(
        create_error(
          key + " must be a string of at most 128 bytes",
          "context." + key,
        ),
      )
  }
}

///|
fn apply_create_context(
  current : TurnContextSnapshot,
  value : Json,
) -> Result[TurnContextSnapshot, @errors.EngineError] {
  let object = match
    strict_create_object(
      value,
      ["locale", "theme", "route", "metadata"],
      "context",
    ) {
    Ok(parsed) => parsed
    Err(error) => return Err(error)
  }
  let locale = match optional_context_string(object, "locale", current.locale) {
    Ok(parsed) => parsed
    Err(error) => return Err(error)
  }
  let theme = match optional_context_string(object, "theme", current.theme) {
    Ok(parsed) => parsed
    Err(error) => return Err(error)
  }
  let route = match optional_context_string(object, "route", current.route) {
    Ok(parsed) => parsed
    Err(error) => return Err(error)
  }
  let metadata = match object.get("metadata") {
    None => current.metadata
    Some(update) =>
      match merge_metadata(current.metadata, update) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
  }
  Ok({ ..current, locale, theme, route, metadata })
}

///|
pub fn canonical_message_json(messages : Array[@content.Message]) -> Json {
  Json::array(messages.map(@content.encode))
}

///|
pub fn create_input_json(
  context : TurnContextSnapshot,
  messages : Array[@content.Message],
  connector_id : String,
  temperature : Double,
  max_tokens : Int,
) -> Json {
  {
    "version": 1,
    "context": context_json(context),
    "messages": canonical_message_json(messages),
    "options": {
      "connector": connector_id,
      "temperature": temperature,
      "max_tokens": max_tokens,
      "metadata": context.metadata,
    },
  }
}

///|
pub fn apply_create_decision(
  output : Json,
  input_messages : Array[@content.Message],
  connector_id : String,
  temperature : Double,
  max_tokens : Int,
  context : TurnContextSnapshot,
) -> Result[CreateDecision, @errors.EngineError] {
  if output is Null {
    return Ok({
      messages: input_messages,
      connector_id,
      temperature,
      max_tokens,
      context,
      snapshot: Json::null(),
    })
  }
  let object = match
    strict_create_object(
      output,
      ["messages", "connector", "generation", "context"],
      "decision",
    ) {
    Ok(parsed) => parsed
    Err(error) => return Err(error)
  }
  let messages = match object.get("messages") {
    None => input_messages
    Some(value) =>
      match
        validate_create_messages(value, allowed_attachments(input_messages)) {
        Ok(parsed) => parsed
        Err(error) => return Err(error)
      }
  }
  let selected_connector = match object.get("connector") {
    None => connector_id
    Some(String(value)) if value == connector_id => value
    Some(String(_)) =>
      return Err(
        create_error("connector is not configured for this agent", "connector"),
      )
    Some(_) =>
      return Err(create_error("connector must be a string", "connector"))
  }
  let mut selected_temperature = temperature
  let mut selected_max_tokens = max_tokens
  match object.get("generation") {
    None => ()
    Some(value) => {
      let generation = match
        strict_create_object(value, ["temperature", "max_tokens"], "generation") {
        Ok(parsed) => parsed
        Err(error) => return Err(error)
      }
      match generation.get("temperature") {
        None => ()
        Some(Number(value, ..)) if value >= 0.0 && value <= 2.0 =>
          selected_temperature = value
        Some(_) =>
          return Err(
            create_error(
              "temperature must be between 0 and 2", "generation.temperature",
            ),
          )
      }
      match generation.get("max_tokens") {
        None => ()
        Some(Number(value, ..)) if value.to_int().to_double() == value &&
          value >= 1.0 &&
          value <= 32768.0 => selected_max_tokens = value.to_int()
        Some(_) =>
          return Err(
            create_error(
              "max_tokens must be between 1 and 32768", "generation.max_tokens",
            ),
          )
      }
    }
  }
  let selected_context = match object.get("context") {
    None => context
    Some(value) =>
      match apply_create_context(context, value) {
        Ok(parsed) => parsed
        Err(error) => return Err(error)
      }
  }
  Ok({
    messages,
    connector_id: selected_connector,
    temperature: selected_temperature,
    max_tokens: selected_max_tokens,
    context: selected_context,
    snapshot: output,
  })
}

///|
fn canonical_role(role : @llm.Role) -> @content.Role {
  match role {
    @llm.System => @content.System
    @llm.User => @content.User
    @llm.Assistant => @content.Assistant
    @llm.Tool => @content.Tool
  }
}

///|
fn provider_role(role : @content.Role) -> @llm.Role {
  match role {
    @content.Developer | @content.System => @llm.System
    @content.User => @llm.User
    @content.Assistant => @llm.Assistant
    @content.Tool => @llm.Tool
  }
}

///|
pub fn chat_from_canonical(message : @content.Message) -> @llm.ChatMessage {
  let content = match message.content {
    Some(@content.Text(value)) if message.tool_calls.is_empty() &&
      message.tool_call_id is None => value
    _ => @content.encode(message).stringify()
  }
  { role: provider_role(message.role), content }
}

///|
fn canonical_tool_message(content : String) -> @content.Message? {
  let parsed = @json.parse(content) catch { _ => return None }
  guard parsed is Object(object) else { return None }
  guard object.get("tool_call_id") is Some(String(call_id)) else { return None }
  let name = match object.get("name") {
    Some(String(value)) => Some(value)
    _ => None
  }
  let result = match object.get("content") {
    Some(String(value)) => value
    Some(value) => value.stringify()
    None => ""
  }
  Some({
    role: @content.Tool,
    content: Some(@content.Text(result)),
    name,
    tool_call_id: Some(call_id),
    reasoning_content: None,
    tool_calls: [],
    refusal: None,
  })
}

///|
pub fn canonical_from_chat(message : @llm.ChatMessage) -> @content.Message {
  let parsed = @json.parse(message.content) catch { _ => Json::null() }
  match @content.decode(parsed, "message") {
    Ok(value) => return value
    Err(_) => ()
  }
  if message.role == @llm.Tool {
    match canonical_tool_message(message.content) {
      Some(value) => return value
      None => ()
    }
  }
  @content.text_message(canonical_role(message.role), message.content)
}
