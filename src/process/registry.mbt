///|
pub(all) struct Registry {
  models : Array[@model.Model]
}

///|
pub fn Registry::new(models : Array[@model.Model]) -> Registry {
  { models, }
}

///|
pub fn Registry::names(self : Registry) -> Array[String] {
  let names : Array[String] = []
  for model in self.models {
    let prefix = "models." + model.name + "."
    for operation in ["Find", "List", "Create", "Update", "Delete"] {
      names.push(prefix + operation)
    }
  }
  names
}

///|
fn find_process_model(
  registry : Registry,
  process : String,
) -> (@model.Model, String)? {
  for model in registry.models {
    let prefix = "models." + model.name + "."
    if process.has_prefix(prefix) {
      let operation = process[prefix.length():].to_owned()
      if ["Find", "List", "Create", "Update", "Delete"].contains(operation) {
        return Some((model, operation))
      }
    }
  }
  None
}

///|
fn primary_column(model : @model.Model) -> @model.Column? {
  for column in model.columns {
    if column.column_type == @model.Id || column.primary {
      return Some(column)
    }
  }
  None
}

///|
fn column_named(model : @model.Model, name : String) -> @model.Column? {
  for column in model.columns {
    if column.name == name {
      return Some(column)
    }
  }
  None
}

///|
fn ensure_keys(
  object : Map[String, Json],
  allowed : Array[String],
  path : String,
) -> Result[Unit, @errors.EngineError] {
  for key in object.keys() {
    if !allowed.contains(key) {
      return Err(
        @errors.invalid_argument("unknown field '\{key}'", path + "." + key),
      )
    }
  }
  Ok(())
}

///|
fn input_object(input : Json) -> Result[Map[String, Json], @errors.EngineError] {
  match input {
    Object(object) => Ok(object)
    _ => Err(@errors.invalid_argument("expected an object", "$"))
  }
}

///|
fn object_field(
  object : Map[String, Json],
  key : String,
  path : String,
) -> Result[Map[String, Json], @errors.EngineError] {
  match object.get(key) {
    Some(Object(value)) => Ok(value)
    Some(_) => Err(@errors.invalid_argument("expected an object", path))
    None => Err(@errors.invalid_argument("missing required field", path))
  }
}

///|
fn integer_field(
  object : Map[String, Json],
  key : String,
  path : String,
) -> Result[Int, @errors.EngineError] {
  match object.get(key) {
    Some(Number(value, ..)) => {
      let integer = value.to_int()
      if !value.is_inf() && !value.is_nan() && integer.to_double() == value {
        Ok(integer)
      } else {
        Err(@errors.invalid_argument("expected an integer", path))
      }
    }
    Some(_) => Err(@errors.invalid_argument("expected an integer", path))
    None => Err(@errors.invalid_argument("missing required field", path))
  }
}

///|
fn bind_value(
  statement : @sqlite3.Statement,
  index : Int,
  column : @model.Column,
  value : Json,
  path : String,
) -> Result[Unit, @errors.EngineError] {
  try {
    match (column.column_type, value) {
      (@model.Id | @model.Int, Number(number, ..)) => {
        let integer = number.to_int()
        if number.is_inf() || number.is_nan() || integer.to_double() != number {
          return Err(@errors.invalid_argument("value has the wrong type", path))
        }
        statement.bind(index~, integer)
      }
      (@model.Float, Number(number, ..)) if !number.is_inf() && !number.is_nan() =>
        statement.bind(index~, number)
      (@model.Bool, True) => statement.bind(index~, 1)
      (@model.Bool, False) => statement.bind(index~, 0)
      (@model.String | @model.Text, String(text)) =>
        statement.bind(index~, text)
      _ =>
        return Err(@errors.invalid_argument("value has the wrong type", path))
    }
    Ok(())
  } catch {
    (_ : @sqlite3.SqliteError) =>
      Err(@errors.database_error("could not bind value", path))
  }
}

///|
fn row_json(statement : @sqlite3.Statement, model : @model.Model) -> Json {
  let row : Map[String, Json] = Map([])
  for index = 0; index < model.columns.length(); index = index + 1 {
    let column = model.columns[index]
    let value : Json = match column.column_type {
      @model.Id | @model.Int => {
        let number : Int = statement.column(index~)
        Json::number(number.to_double())
      }
      @model.Float => {
        let number : Double = statement.column(index~)
        Json::number(number)
      }
      @model.Bool => {
        let number : Int = statement.column(index~)
        Json::boolean(number != 0)
      }
      @model.String | @model.Text => {
        let text : String = statement.column(index~)
        Json::string(text)
      }
    }
    row.set(column.name, value)
  }
  Json::object(row)
}

///|
fn select_columns(model : @model.Model) -> String {
  model.columns.map(column => column.name).join(", ")
}

///|
fn find_record(
  connection : @sqlite3.Connection,
  model : @model.Model,
  id : Json,
  path : String,
) -> Result[Json, @errors.EngineError] {
  let id_column = match primary_column(model) {
    Some(value) => value
    None =>
      return Err(@errors.invalid_dsl("model has no id column", model.name))
  }
  let statement = connection.prepare(
    "SELECT " +
    select_columns(model) +
    " FROM " +
    model.table +
    " WHERE " +
    id_column.name +
    " = ?",
  ) catch {
    (_ : @sqlite3.SqliteError) =>
      return Err(@errors.database_error("could not prepare query", path))
  }
  let bound = bind_value(statement, 1, id_column, id, path)
  match bound {
    Err(error) => {
      statement.finalize() catch {
        _ => ()
      }
      return Err(error)
    }
    Ok(_) => ()
  }
  try {
    if statement.step() {
      let result = row_json(statement, model)
      statement.finalize()
      Ok(result)
    } else {
      statement.finalize()
      Err(@errors.record_not_found(path))
    }
  } catch {
    (_ : @sqlite3.SqliteError) => {
      statement.finalize() catch {
        _ => ()
      }
      Err(@errors.database_error("could not query record", path))
    }
  }
}

///|
fn run_find(
  connection : @sqlite3.Connection,
  model : @model.Model,
  input : Json,
) -> Result[Json, @errors.EngineError] {
  let object = match input_object(input) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match ensure_keys(object, ["id"], "$") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let id = match object.get("id") {
    Some(value) => value
    None =>
      return Err(@errors.invalid_argument("missing required field", "$.id"))
  }
  find_record(connection, model, id, "$.id")
}

///|
fn run_list(
  connection : @sqlite3.Connection,
  model : @model.Model,
  input : Json,
) -> Result[Json, @errors.EngineError] {
  let object = match input_object(input) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match ensure_keys(object, ["where", "limit", "offset"], "$") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let where_map : Map[String, Json] = match object.get("where") {
    None => Map([])
    Some(Object(value)) => value
    Some(_) =>
      return Err(@errors.invalid_argument("expected an object", "$.where"))
  }
  let where_columns : Array[@model.Column] = []
  let clauses : Array[String] = []
  for key in where_map.keys() {
    let column = match column_named(model, key) {
      Some(value) => value
      None =>
        return Err(
          @errors.invalid_argument("unknown field '\{key}'", "$.where." + key),
        )
    }
    where_columns.push(column)
    clauses.push(key + " = ?")
  }
  let limit = match object.get("limit") {
    None => 20
    Some(_) =>
      match integer_field(object, "limit", "$.limit") {
        Ok(value) => value
        Err(error) => return Err(error)
      }
  }
  let offset = match object.get("offset") {
    None => 0
    Some(_) =>
      match integer_field(object, "offset", "$.offset") {
        Ok(value) => value
        Err(error) => return Err(error)
      }
  }
  if limit < 0 || offset < 0 {
    return Err(@errors.invalid_argument("pagination cannot be negative", "$"))
  }
  let mut sql = "SELECT " + select_columns(model) + " FROM " + model.table
  if !clauses.is_empty() {
    sql = sql + " WHERE " + clauses.join(" AND ")
  }
  match primary_column(model) {
    Some(column) => sql = sql + " ORDER BY " + column.name
    None => ()
  }
  sql = sql + " LIMIT ? OFFSET ?"
  let statement = connection.prepare(sql) catch {
    (_ : @sqlite3.SqliteError) =>
      return Err(@errors.database_error("could not prepare list", "$"))
  }
  let mut index = 1
  for column in where_columns {
    let value = where_map.get(column.name).unwrap()
    match
      bind_value(statement, index, column, value, "$.where." + column.name) {
      Err(error) => {
        statement.finalize() catch {
          _ => ()
        }
        return Err(error)
      }
      Ok(_) => index = index + 1
    }
  }
  try {
    statement.bind(index~, limit)
    statement.bind(index=index + 1, offset)
    let rows : Array[Json] = []
    while statement.step() {
      rows.push(row_json(statement, model))
    }
    statement.finalize()
    Ok(Json::array(rows))
  } catch {
    (_ : @sqlite3.SqliteError) => {
      statement.finalize() catch {
        _ => ()
      }
      Err(@errors.database_error("could not list records", "$"))
    }
  }
}

///|
fn run_create(
  connection : @sqlite3.Connection,
  model : @model.Model,
  input : Json,
) -> Result[Json, @errors.EngineError] {
  let object = match input_object(input) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match ensure_keys(object, ["data"], "$") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let data = match object_field(object, "data", "$.data") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let columns : Array[@model.Column] = []
  for key in data.keys() {
    match column_named(model, key) {
      Some(column) => columns.push(column)
      None =>
        return Err(
          @errors.invalid_argument("unknown field '\{key}'", "$.data." + key),
        )
    }
  }
  for column in model.columns {
    if column.column_type != @model.Id &&
      column.default_value is None &&
      !data.contains(column.name) {
      return Err(
        @errors.invalid_argument(
          "missing required field",
          "$.data." + column.name,
        ),
      )
    }
  }
  let mut sql = "INSERT INTO " + model.table
  if columns.is_empty() {
    sql = sql + " DEFAULT VALUES"
  } else {
    sql = sql +
      " (" +
      columns.map(column => column.name).join(", ") +
      ") VALUES (" +
      columns.map(_ => "?").join(", ") +
      ")"
  }
  let statement = connection.prepare(sql) catch {
    (_ : @sqlite3.SqliteError) =>
      return Err(@errors.database_error("could not prepare create", "$.data"))
  }
  for index = 0; index < columns.length(); index = index + 1 {
    let column = columns[index]
    match
      bind_value(
        statement,
        index + 1,
        column,
        data.get(column.name).unwrap(),
        "$.data." + column.name,
      ) {
      Err(error) => {
        statement.finalize() catch {
          _ => ()
        }
        return Err(error)
      }
      Ok(_) => ()
    }
  }
  try {
    statement.step_once()
    statement.finalize()
  } catch {
    (_ : @sqlite3.SqliteError) => {
      statement.finalize() catch {
        _ => ()
      }
      return Err(@errors.database_error("could not create record", "$.data"))
    }
  }
  let id_column = match primary_column(model) {
    Some(value) => value
    None =>
      return Err(@errors.invalid_dsl("model has no id column", model.name))
  }
  let id = match data.get(id_column.name) {
    Some(value) => value
    None => {
      let last_id = connection.prepare("SELECT last_insert_rowid()") catch {
        (_ : @sqlite3.SqliteError) =>
          return Err(
            @errors.database_error("could not read created id", "$.data"),
          )
      }
      try {
        ignore(last_id.step())
        let value : Int = last_id.column(index=0)
        last_id.finalize()
        Json::number(value.to_double())
      } catch {
        (_ : @sqlite3.SqliteError) => {
          last_id.finalize() catch {
            _ => ()
          }
          return Err(
            @errors.database_error("could not read created id", "$.data"),
          )
        }
      }
    }
  }
  find_record(connection, model, id, "$.data." + id_column.name)
}

///|
fn run_update(
  connection : @sqlite3.Connection,
  model : @model.Model,
  input : Json,
) -> Result[Json, @errors.EngineError] {
  let object = match input_object(input) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match ensure_keys(object, ["id", "data"], "$") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let id = match object.get("id") {
    Some(value) => value
    None =>
      return Err(@errors.invalid_argument("missing required field", "$.id"))
  }
  let data = match object_field(object, "data", "$.data") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if data.is_empty() {
    return Err(
      @errors.invalid_argument("update data cannot be empty", "$.data"),
    )
  }
  let id_column = match primary_column(model) {
    Some(value) => value
    None =>
      return Err(@errors.invalid_dsl("model has no id column", model.name))
  }
  let columns : Array[@model.Column] = []
  for key in data.keys() {
    let column = match column_named(model, key) {
      Some(value) => value
      None =>
        return Err(
          @errors.invalid_argument("unknown field '\{key}'", "$.data." + key),
        )
    }
    if column.name == id_column.name {
      return Err(
        @errors.invalid_argument("id cannot be updated", "$.data." + key),
      )
    }
    columns.push(column)
  }
  let assignments = columns.map(column => column.name + " = ?").join(", ")
  let statement = connection.prepare(
    "UPDATE " +
    model.table +
    " SET " +
    assignments +
    " WHERE " +
    id_column.name +
    " = ?",
  ) catch {
    (_ : @sqlite3.SqliteError) =>
      return Err(@errors.database_error("could not prepare update", "$.data"))
  }
  for index = 0; index < columns.length(); index = index + 1 {
    let column = columns[index]
    match
      bind_value(
        statement,
        index + 1,
        column,
        data.get(column.name).unwrap(),
        "$.data." + column.name,
      ) {
      Err(error) => {
        statement.finalize() catch {
          _ => ()
        }
        return Err(error)
      }
      Ok(_) => ()
    }
  }
  match bind_value(statement, columns.length() + 1, id_column, id, "$.id") {
    Err(error) => {
      statement.finalize() catch {
        _ => ()
      }
      return Err(error)
    }
    Ok(_) => ()
  }
  try {
    statement.step_once()
    statement.finalize()
  } catch {
    (_ : @sqlite3.SqliteError) => {
      statement.finalize() catch {
        _ => ()
      }
      return Err(@errors.database_error("could not update record", "$.data"))
    }
  }
  find_record(connection, model, id, "$.id")
}

///|
fn run_delete(
  connection : @sqlite3.Connection,
  model : @model.Model,
  input : Json,
) -> Result[Json, @errors.EngineError] {
  let object = match input_object(input) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match ensure_keys(object, ["id"], "$") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let id = match object.get("id") {
    Some(value) => value
    None =>
      return Err(@errors.invalid_argument("missing required field", "$.id"))
  }
  let existing = match find_record(connection, model, id, "$.id") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let id_column = primary_column(model).unwrap()
  let statement = connection.prepare(
    "DELETE FROM " + model.table + " WHERE " + id_column.name + " = ?",
  ) catch {
    (_ : @sqlite3.SqliteError) =>
      return Err(@errors.database_error("could not prepare delete", "$.id"))
  }
  match bind_value(statement, 1, id_column, id, "$.id") {
    Err(error) => {
      statement.finalize() catch {
        _ => ()
      }
      return Err(error)
    }
    Ok(_) => ()
  }
  try {
    statement.step_once()
    statement.finalize()
    Ok(existing)
  } catch {
    (_ : @sqlite3.SqliteError) => {
      statement.finalize() catch {
        _ => ()
      }
      Err(@errors.database_error("could not delete record", "$.id"))
    }
  }
}

///|
pub fn Registry::run(
  self : Registry,
  connection : @sqlite3.Connection,
  process : String,
  input : Json,
) -> Result[Json, @errors.EngineError] {
  let (model, operation) = match find_process_model(self, process) {
    Some(value) => value
    None => return Err(@errors.process_not_found(process))
  }
  match operation {
    "Find" => run_find(connection, model, input)
    "List" => run_list(connection, model, input)
    "Create" => run_create(connection, model, input)
    "Update" => run_update(connection, model, input)
    "Delete" => run_delete(connection, model, input)
    _ => Err(@errors.process_not_found(process))
  }
}
