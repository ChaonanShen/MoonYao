///|
pub(all) struct NextToolResult {
  tool_call_id : String
  name : String
  arguments : Json
  result : Json?
  error : Json?
} derive(Eq, Debug)

///|
pub(all) struct NextDecision {
  data : Json?
  context : TurnContextSnapshot
  snapshot : Json
} derive(Eq, Debug)

///|
fn next_error(message : String, path : String) -> @errors.EngineError {
  @errors.invalid_argument(message, "next." + path)
}

///|
fn strict_next_object(
  value : Json,
  allowed : Array[String],
  path : String,
) -> Result[Map[String, Json], @errors.EngineError] {
  guard value is Object(object) else {
    return Err(next_error("expected an object", path))
  }
  for key in object.keys() {
    if !allowed.contains(key) {
      return Err(next_error("unknown field", path + "." + key))
    }
  }
  Ok(object)
}

///|
fn merge_next_metadata(
  context : TurnContextSnapshot,
  update : Json,
) -> Result[TurnContextSnapshot, @errors.EngineError] {
  guard context.metadata is Object(base) else {
    return Err(next_error("context metadata must be an object", "metadata"))
  }
  guard update is Object(values) else {
    return Err(next_error("metadata must be an object", "metadata"))
  }
  let merged : Map[String, Json] = Map([])
  for entry in base {
    let (key, value) = entry
    merged.set(key, value)
  }
  for entry in values {
    let (key, value) = entry
    merged.set(key, value)
  }
  let metadata = Json::object(merged)
  if metadata.stringify().length() > 32768 {
    return Err(next_error("metadata is too large", "metadata"))
  }
  Ok({ ..context, metadata, })
}

///|
fn next_tool_json(tool : NextToolResult) -> Json {
  {
    "tool_call_id": tool.tool_call_id,
    "name": tool.name,
    "arguments": tool.arguments,
    "result": match tool.result {
      Some(value) => value
      None => Json::null()
    },
    "error": match tool.error {
      Some(value) => value
      None => Json::null()
    },
  }
}

///|
pub fn next_input_json(
  context : TurnContextSnapshot,
  messages : Array[@content.Message],
  content : String,
  usage : @llm.Usage,
  tools : Array[NextToolResult],
) -> Json {
  {
    "version": 1,
    "context": context_json(context),
    "messages": canonical_message_json(messages),
    "completion": {
      "message": @content.encode(
        @content.text_message(@content.Assistant, content),
      ),
      "finish_reason": "stop",
      "usage": {
        "prompt_tokens": usage.prompt_tokens,
        "completion_tokens": usage.completion_tokens,
      },
    },
    "tools": Json::array(tools.map(next_tool_json)),
  }
}

///|
pub fn apply_next_decision(
  output : Json,
  context : TurnContextSnapshot,
) -> Result[NextDecision, @errors.EngineError] {
  if output is Null {
    return Ok({ data: None, context, snapshot: Json::null() })
  }
  let object = match
    strict_next_object(output, ["action", "data", "metadata"], "decision") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let action = match object.get("action") {
    Some(String(value)) => value
    _ => return Err(next_error("action is required", "action"))
  }
  if action == "return" {
    for key in object.keys() {
      if key != "action" {
        return Err(next_error("return does not accept extra fields", key))
      }
    }
    return Ok({ data: None, context, snapshot: output })
  }
  if action != "data" {
    return Err(next_error("unknown action", "action"))
  }
  let data = match object.get("data") {
    Some(value) => value
    None => return Err(next_error("data action requires data", "data"))
  }
  if data.stringify().length() > 262144 {
    return Err(next_error("custom data is too large", "data"))
  }
  let updated_context = match object.get("metadata") {
    None => context
    Some(value) =>
      match merge_next_metadata(context, value) {
        Ok(updated) => updated
        Err(error) => return Err(error)
      }
  }
  Ok({ data: Some(data), context: updated_context, snapshot: output })
}
