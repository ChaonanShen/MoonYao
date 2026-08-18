///|
pub(all) enum ColumnType {
  Id
  Int
  Float
  Bool
  String
  Text
} derive(Eq, Debug)

///|
pub(all) struct Column {
  name : String
  column_type : ColumnType
  primary : Bool
  unique : Bool
  nullable : Bool
  default_value : Json?
} derive(Debug)

///|
pub(all) struct Model {
  name : String
  table : String
  columns : Array[Column]
} derive(Debug)

///|
pub fn is_identifier(value : String) -> Bool {
  if value.length() == 0 {
    return false
  }
  for index = 0; index < value.length(); index = index + 1 {
    let character = value.code_unit_at(index).unsafe_to_char()
    let letter = character.is_ascii_alphabetic()
    let digit = character >= '0' && character <= '9'
    let underscore = character == '_'
    if !(letter || underscore || (index > 0 && digit)) {
      return false
    }
  }
  true
}

///|
fn ensure_known_keys(
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
fn optional_bool(
  object : Map[String, Json],
  key : String,
  path : String,
) -> Result[Bool, @errors.EngineError] {
  match object.get(key) {
    None => Ok(false)
    Some(True) => Ok(true)
    Some(False) => Ok(false)
    Some(_) => Err(@errors.invalid_dsl("expected a boolean", path + "." + key))
  }
}

///|
fn parse_type(
  value : String,
  path : String,
) -> Result[ColumnType, @errors.EngineError] {
  match value {
    "id" => Ok(Id)
    "int" => Ok(Int)
    "float" => Ok(Float)
    "bool" => Ok(Bool)
    "string" => Ok(String)
    "text" => Ok(Text)
    _ => Err(@errors.invalid_dsl("unknown column type '\{value}'", path))
  }
}

///|
fn is_scalar(value : Json) -> Bool {
  match value {
    Null | True | False | Number(_, ..) | String(_) => true
    Array(_) | Object(_) => false
  }
}

///|
fn parse_column(
  value : Json,
  path : String,
) -> Result[Column, @errors.EngineError] {
  guard value is Object(object) else {
    return Err(@errors.invalid_dsl("expected an object", path))
  }
  match
    ensure_known_keys(
      object,
      ["name", "type", "primary", "unique", "nullable", "default"],
      path,
    ) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let name = match required_string(object, "name", path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !is_identifier(name) {
    return Err(@errors.invalid_dsl("column name is invalid", path + ".name"))
  }
  let type_name = match required_string(object, "type", path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let column_type = match parse_type(type_name, path + ".type") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let primary = match optional_bool(object, "primary", path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let unique = match optional_bool(object, "unique", path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let nullable = match optional_bool(object, "nullable", path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if nullable && (primary || column_type == Id) {
    return Err(
      @errors.invalid_dsl(
        "primary and id columns cannot be nullable",
        path + ".nullable",
      ),
    )
  }
  let default_value = object.get("default")
  match default_value {
    Some(value) if !is_scalar(value) =>
      return Err(
        @errors.invalid_dsl("default must be a JSON scalar", path + ".default"),
      )
    _ => ()
  }
  Ok({ name, column_type, primary, unique, nullable, default_value })
}

///|
pub fn parse_model(
  value : Json,
  path : String,
) -> Result[Model, @errors.EngineError] {
  guard value is Object(object) else {
    return Err(@errors.invalid_dsl("expected an object", path))
  }
  match ensure_known_keys(object, ["name", "table", "columns"], path) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let name = match required_string(object, "name", path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let table = match required_string(object, "table", path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !is_identifier(name) || !is_identifier(table) {
    return Err(@errors.invalid_dsl("model name or table is invalid", path))
  }
  let columns_json = match object.get("columns") {
    Some(Array(value)) => value
    Some(_) =>
      return Err(@errors.invalid_dsl("expected an array", path + ".columns"))
    None =>
      return Err(@errors.invalid_dsl("missing required key", path + ".columns"))
  }
  if columns_json.is_empty() {
    return Err(
      @errors.invalid_dsl("at least one column is required", path + ".columns"),
    )
  }
  let columns : Array[Column] = []
  for index = 0; index < columns_json.length(); index = index + 1 {
    let column = match
      parse_column(
        columns_json[index],
        path + ".columns[" + index.to_string() + "]",
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if columns.any(existing => existing.name == column.name) {
      return Err(
        @errors.invalid_dsl(
          "duplicate column name",
          path + ".columns[" + index.to_string() + "].name",
        ),
      )
    }
    columns.push(column)
  }
  Ok({ name, table, columns })
}
