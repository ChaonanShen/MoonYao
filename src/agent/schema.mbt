///|
pub(all) struct Tool {
  name : String
  description : String
  process : String
  input_schema : Json
} derive(Eq, Debug)

///|
fn schema_type(
  object : Map[String, Json],
  path : String,
) -> Result[String, @errors.EngineError] {
  match object.get("type") {
    Some(String(value)) if [
        "object", "array", "string", "number", "integer", "boolean",
      ].contains(value) => Ok(value)
    Some(_) =>
      Err(@errors.invalid_dsl("unsupported schema type", path + ".type"))
    None => Err(@errors.invalid_dsl("missing required key", path + ".type"))
  }
}

///|
fn schema_integer(
  value : Json,
  path : String,
) -> Result[Int, @errors.EngineError] {
  match value {
    Number(number, ..) if number.to_int().to_double() == number =>
      Ok(number.to_int())
    _ => Err(@errors.invalid_dsl("expected an integer", path))
  }
}

///|
fn schema_number(
  value : Json,
  path : String,
) -> Result[Double, @errors.EngineError] {
  match value {
    Number(number, ..) if !number.is_inf() && !number.is_nan() => Ok(number)
    _ => Err(@errors.invalid_dsl("expected a finite number", path))
  }
}

///|
fn value_has_type(value : Json, kind : String) -> Bool {
  match (kind, value) {
    ("object", Object(_))
    | ("array", Array(_))
    | ("string", String(_))
    | ("number", Number(_))
    | ("boolean", True)
    | ("boolean", False) => true
    ("integer", Number(number, ..)) => number.to_int().to_double() == number
    _ => false
  }
}

///|
fn validate_schema_inner(
  value : Json,
  path : String,
  depth : Int,
) -> Result[Int, @errors.EngineError] {
  if depth > 16 {
    return Err(@errors.invalid_dsl("schema nesting is too deep", path))
  }
  guard value is Object(object) else {
    return Err(@errors.invalid_dsl("schema must be an object", path))
  }
  let kind = match schema_type(object, path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let common = ["type", "description", "enum"]
  let allowed = match kind {
    "object" => common + ["properties", "required", "additionalProperties"]
    "array" => common + ["items", "minItems", "maxItems"]
    "string" => common + ["minLength", "maxLength"]
    "number" | "integer" => common + ["minimum", "maximum"]
    _ => common
  }
  for key in object.keys() {
    if !allowed.contains(key) {
      return Err(
        @errors.invalid_dsl("unsupported schema keyword", path + "." + key),
      )
    }
  }
  match object.get("description") {
    None | Some(String(_)) => ()
    Some(_) =>
      return Err(
        @errors.invalid_dsl("expected a string", path + ".description"),
      )
  }
  match object.get("enum") {
    None => ()
    Some(Array(values)) if !values.is_empty() =>
      for index = 0; index < values.length(); index = index + 1 {
        if !value_has_type(values[index], kind) {
          return Err(
            @errors.invalid_dsl(
              "enum value has the wrong type",
              path + ".enum[" + index.to_string() + "]",
            ),
          )
        }
      }
    Some(_) =>
      return Err(
        @errors.invalid_dsl("enum must be a non-empty array", path + ".enum"),
      )
  }
  if kind == "object" {
    let properties = match object.get("properties") {
      Some(Object(value)) => value
      Some(_) =>
        return Err(
          @errors.invalid_dsl("expected an object", path + ".properties"),
        )
      None => Map([])
    }
    match object.get("additionalProperties") {
      None | Some(False) => ()
      Some(_) =>
        return Err(
          @errors.invalid_dsl(
            "additionalProperties must be false",
            path + ".additionalProperties",
          ),
        )
    }
    let required : Array[String] = []
    match object.get("required") {
      None => ()
      Some(Array(values)) =>
        for index = 0; index < values.length(); index = index + 1 {
          match values[index] {
            String(name) if properties.contains(name) &&
              !required.contains(name) => required.push(name)
            String(name) if required.contains(name) =>
              return Err(
                @errors.invalid_dsl(
                  "duplicate required property",
                  path + ".required[" + index.to_string() + "]",
                ),
              )
            String(_) =>
              return Err(
                @errors.invalid_dsl(
                  "required property is not declared",
                  path + ".required[" + index.to_string() + "]",
                ),
              )
            _ =>
              return Err(
                @errors.invalid_dsl(
                  "expected a property name",
                  path + ".required[" + index.to_string() + "]",
                ),
              )
          }
        }
      Some(_) =>
        return Err(@errors.invalid_dsl("expected an array", path + ".required"))
    }
    let mut count = properties.length()
    for name in properties.keys() {
      match
        validate_schema_inner(
          properties.get(name).unwrap(),
          path + ".properties." + name,
          depth + 1,
        ) {
        Ok(value) => count = count + value
        Err(error) => return Err(error)
      }
    }
    if count > 200 {
      return Err(@errors.invalid_dsl("schema has too many properties", path))
    }
    return Ok(count)
  }
  if kind == "array" {
    let items = match object.get("items") {
      Some(value) => value
      None =>
        return Err(@errors.invalid_dsl("missing required key", path + ".items"))
    }
    let min = match object.get("minItems") {
      None => 0
      Some(value) =>
        match schema_integer(value, path + ".minItems") {
          Ok(v) => v
          Err(e) => return Err(e)
        }
    }
    let max = match object.get("maxItems") {
      None => 100
      Some(value) =>
        match schema_integer(value, path + ".maxItems") {
          Ok(v) => v
          Err(e) => return Err(e)
        }
    }
    if min < 0 || max < min || max > 100 {
      return Err(@errors.invalid_dsl("invalid array length range", path))
    }
    return validate_schema_inner(items, path + ".items", depth + 1)
  }
  if kind == "string" {
    let min = match object.get("minLength") {
      None => 0
      Some(value) =>
        match schema_integer(value, path + ".minLength") {
          Ok(v) => v
          Err(e) => return Err(e)
        }
    }
    let max = match object.get("maxLength") {
      None => 65536
      Some(value) =>
        match schema_integer(value, path + ".maxLength") {
          Ok(v) => v
          Err(e) => return Err(e)
        }
    }
    if min < 0 || max < min || max > 65536 {
      return Err(@errors.invalid_dsl("invalid string length range", path))
    }
  }
  if kind == "number" || kind == "integer" {
    let minimum = match object.get("minimum") {
      None => None
      Some(value) =>
        match schema_number(value, path + ".minimum") {
          Ok(v) => Some(v)
          Err(e) => return Err(e)
        }
    }
    let maximum = match object.get("maximum") {
      None => None
      Some(value) =>
        match schema_number(value, path + ".maximum") {
          Ok(v) => Some(v)
          Err(e) => return Err(e)
        }
    }
    match (minimum, maximum) {
      (Some(min), Some(max)) if min > max =>
        return Err(@errors.invalid_dsl("minimum exceeds maximum", path))
      _ => ()
    }
  }
  Ok(0)
}

///|
pub fn validate_schema(
  value : Json,
  path : String,
) -> Result[Unit, @errors.EngineError] {
  if value.stringify().length() > 131072 {
    return Err(@errors.invalid_dsl("schema is too large", path))
  }
  match validate_schema_inner(value, path, 1) {
    Ok(_) => Ok(())
    Err(error) => Err(error)
  }
}

///|
fn argument_error(message : String, path : String) -> @errors.EngineError {
  @errors.invalid_argument(message, path)
}

///|
fn validate_value(
  value : Json,
  schema : Json,
  path : String,
) -> Result[Unit, @errors.EngineError] {
  guard schema is Object(object) else {
    return Err(argument_error("invalid tool schema", path))
  }
  guard object.get("type") is Some(String(kind)) else {
    return Err(argument_error("invalid tool schema", path))
  }
  if !value_has_type(value, kind) {
    return Err(argument_error("value has the wrong type", path))
  }
  match object.get("enum") {
    Some(Array(values)) if !values.contains(value) =>
      return Err(argument_error("value is not in enum", path))
    _ => ()
  }
  match (kind, value) {
    ("object", Object(values)) => {
      let properties = match object.get("properties") {
        Some(Object(v)) => v
        _ => Map([])
      }
      for key in values.keys() {
        if !properties.contains(key) {
          return Err(argument_error("unknown property", path + "." + key))
        }
      }
      match object.get("required") {
        Some(Array(required)) =>
          for item in required {
            guard item is String(name) else { continue }
            if !values.contains(name) {
              return Err(
                argument_error("missing required property", path + "." + name),
              )
            }
          }
        _ => ()
      }
      for key in values.keys() {
        match
          validate_value(
            values.get(key).unwrap(),
            properties.get(key).unwrap(),
            path + "." + key,
          ) {
          Err(error) => return Err(error)
          Ok(_) => ()
        }
      }
    }
    ("array", Array(values)) => {
      let min = match object.get("minItems") {
        Some(Number(v, ..)) => v.to_int()
        _ => 0
      }
      let max = match object.get("maxItems") {
        Some(Number(v, ..)) => v.to_int()
        _ => 100
      }
      if values.length() < min || values.length() > max {
        return Err(
          argument_error("array length is outside the allowed range", path),
        )
      }
      let items = object.get("items").unwrap()
      for index = 0; index < values.length(); index = index + 1 {
        match
          validate_value(
            values[index],
            items,
            path + "[" + index.to_string() + "]",
          ) {
          Err(error) => return Err(error)
          Ok(_) => ()
        }
      }
    }
    ("string", String(text)) => {
      let min = match object.get("minLength") {
        Some(Number(v, ..)) => v.to_int()
        _ => 0
      }
      let max = match object.get("maxLength") {
        Some(Number(v, ..)) => v.to_int()
        _ => 65536
      }
      if text.length() < min || text.length() > max {
        return Err(
          argument_error("string length is outside the allowed range", path),
        )
      }
    }
    ("number" | "integer", Number(number, ..)) => {
      match object.get("minimum") {
        Some(Number(v, ..)) if number < v =>
          return Err(argument_error("number is below minimum", path))
        _ => ()
      }
      match object.get("maximum") {
        Some(Number(v, ..)) if number > v =>
          return Err(argument_error("number exceeds maximum", path))
        _ => ()
      }
    }
    _ => ()
  }
  Ok(())
}

///|
pub fn validate_arguments(
  value : Json,
  schema : Json,
) -> Result[Unit, @errors.EngineError] {
  validate_value(value, schema, "$args")
}

///|
pub fn parse_tools(
  value : Json,
  path : String,
) -> Result[Array[Tool], @errors.EngineError] {
  guard value is Array(items) else {
    return Err(@errors.invalid_dsl("expected an array", path))
  }
  let tools : Array[Tool] = []
  for index = 0; index < items.length(); index = index + 1 {
    let item_path = path + "[" + index.to_string() + "]"
    guard items[index] is Object(object) else {
      return Err(@errors.invalid_dsl("expected an object", item_path))
    }
    match
      known_keys(
        object,
        ["name", "description", "process", "input_schema"],
        item_path,
      ) {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
    let name = match required_string(object, "name", item_path) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if !@model.is_identifier(name) || tools.any(tool => tool.name == name) {
      return Err(
        @errors.invalid_dsl(
          "invalid or duplicate tool name",
          item_path + ".name",
        ),
      )
    }
    let description = match required_string(object, "description", item_path) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if description.length() > 1024 {
      return Err(
        @errors.invalid_dsl(
          "tool description is too large",
          item_path + ".description",
        ),
      )
    }
    let process = match required_string(object, "process", item_path) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let schema = match object.get("input_schema") {
      Some(v) => v
      None =>
        return Err(
          @errors.invalid_dsl(
            "missing required key",
            item_path + ".input_schema",
          ),
        )
    }
    match validate_schema(schema, item_path + ".input_schema") {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
    tools.push({ name, description, process, input_schema: schema })
  }
  Ok(tools)
}
