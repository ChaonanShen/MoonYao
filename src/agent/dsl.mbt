///|
pub(all) struct Options {
  temperature : Double
  max_tokens : Int
} derive(Eq, Debug)

///|
pub(all) struct Agent {
  id : String
  name : String
  description : String
  connector : String
  options : Options
  prompts : Array[@llm.ChatMessage]
  tools : Array[Tool]
  tool_names : Array[String]
  create_process : String
  next_process : String
  before_process : String
  after_process : String
} derive(Debug)

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
pub fn parse_agent(
  value : Json,
  directory_id : String,
  path : String,
) -> Result[Agent, @errors.EngineError] {
  guard value is Object(object) else {
    return Err(@errors.invalid_dsl("expected an object", path))
  }
  match
    known_keys(
      object,
      [
        "id", "name", "description", "connector", "options", "tools", "before_process",
        "after_process", "hooks",
      ],
      path,
    ) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let id = match required_string(object, "id", path) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if !@model.is_identifier(id) || id != directory_id {
    return Err(
      @errors.invalid_dsl("agent id must match its directory", path + ".id"),
    )
  }
  let name = match required_string(object, "name", path) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let connector = match required_string(object, "connector", path) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if connector != "default" {
    return Err(
      @errors.invalid_dsl(
        "agent connector must be 'default'",
        path + ".connector",
      ),
    )
  }
  let description = match object.get("description") {
    None => ""
    Some(String(value)) => value
    Some(_) =>
      return Err(
        @errors.invalid_dsl("expected a string", path + ".description"),
      )
  }
  let mut temperature = 0.2
  let mut max_tokens = 1024
  match object.get("options") {
    None => ()
    Some(Object(options)) => {
      match
        known_keys(options, ["temperature", "max_tokens"], path + ".options") {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      match options.get("temperature") {
        Some(Number(value, ..)) if value >= 0.0 && value <= 2.0 =>
          temperature = value
        Some(_) =>
          return Err(
            @errors.invalid_dsl(
              "temperature must be between 0 and 2",
              path + ".options.temperature",
            ),
          )
        None => ()
      }
      match options.get("max_tokens") {
        Some(Number(value, ..)) if value.to_int().to_double() == value &&
          value >= 1.0 &&
          value <= 32768.0 => max_tokens = value.to_int()
        Some(_) =>
          return Err(
            @errors.invalid_dsl(
              "max_tokens must be between 1 and 32768",
              path + ".options.max_tokens",
            ),
          )
        None => ()
      }
    }
    Some(_) =>
      return Err(@errors.invalid_dsl("expected an object", path + ".options"))
  }
  let tool_names : Array[String] = []
  match object.get("tools") {
    None => ()
    Some(Array(values)) =>
      for index = 0; index < values.length(); index = index + 1 {
        match values[index] {
          String(value) if @model.is_identifier(value) &&
            !tool_names.contains(value) => tool_names.push(value)
          _ =>
            return Err(
              @errors.invalid_dsl(
                "invalid or duplicate tool name",
                path + ".tools[" + index.to_string() + "]",
              ),
            )
        }
      }
    Some(_) =>
      return Err(@errors.invalid_dsl("expected an array", path + ".tools"))
  }
  let before_process = match object.get("before_process") {
    None => ""
    Some(String(value)) if value.length() > 0 => value
    Some(_) =>
      return Err(
        @errors.invalid_dsl(
          "expected a non-empty string",
          path + ".before_process",
        ),
      )
  }
  let (create_process, next_process) = match object.get("hooks") {
    None => ("", "")
    Some(Object(hooks)) => {
      match known_keys(hooks, ["create", "next"], path + ".hooks") {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      let create = match hooks.get("create") {
        Some(String(value)) if value.length() > 0 => value
        Some(_) =>
          return Err(
            @errors.invalid_dsl(
              "expected a non-empty string",
              path + ".hooks.create",
            ),
          )
        None => ""
      }
      let next = match hooks.get("next") {
        Some(String(value)) if value.length() > 0 => value
        Some(_) =>
          return Err(
            @errors.invalid_dsl(
              "expected a non-empty string",
              path + ".hooks.next",
            ),
          )
        None => ""
      }
      (create, next)
    }
    Some(_) =>
      return Err(@errors.invalid_dsl("expected an object", path + ".hooks"))
  }
  if create_process.length() > 0 && before_process.length() > 0 {
    return Err(
      @errors.invalid_dsl(
        "hooks.create cannot be combined with before_process",
        path + ".hooks.create",
      ),
    )
  }
  let after_process = match object.get("after_process") {
    None => ""
    Some(String(value)) if value.length() > 0 => value
    Some(_) =>
      return Err(
        @errors.invalid_dsl(
          "expected a non-empty string",
          path + ".after_process",
        ),
      )
  }
  if next_process.length() > 0 && after_process.length() > 0 {
    return Err(
      @errors.invalid_dsl(
        "hooks.next cannot be combined with after_process",
        path + ".hooks.next",
      ),
    )
  }
  Ok({
    id,
    name,
    description,
    connector,
    options: { temperature, max_tokens },
    prompts: [],
    tools: [],
    tool_names,
    create_process,
    next_process,
    before_process,
    after_process,
  })
}

///|
pub fn parse_prompts(
  value : Json,
  path : String,
) -> Result[Array[@llm.ChatMessage], @errors.EngineError] {
  guard value is Array(items) else {
    return Err(@errors.invalid_dsl("expected an array", path))
  }
  if items.length() < 1 || items.length() > 8 {
    return Err(
      @errors.invalid_dsl("prompts must contain between 1 and 8 entries", path),
    )
  }
  let prompts : Array[@llm.ChatMessage] = []
  let mut total = 0
  for index = 0; index < items.length(); index = index + 1 {
    let item_path = path + "[" + index.to_string() + "]"
    guard items[index] is Object(object) else {
      return Err(@errors.invalid_dsl("expected an object", item_path))
    }
    match known_keys(object, ["role", "content"], item_path) {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
    let role = match required_string(object, "role", item_path) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if role != "system" {
      return Err(
        @errors.invalid_dsl("prompt role must be 'system'", item_path + ".role"),
      )
    }
    let content = match required_string(object, "content", item_path) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if content.length() > 32768 {
      return Err(
        @errors.invalid_dsl("prompt is too large", item_path + ".content"),
      )
    }
    total = total + content.length()
    if total > 65536 {
      return Err(@errors.invalid_dsl("total prompt content is too large", path))
    }
    prompts.push({ role: @llm.System, content })
  }
  Ok(prompts)
}
