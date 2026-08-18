///|
fn sqlite_type(column_type : ColumnType) -> String {
  match column_type {
    Id | Int | Bool => "INTEGER"
    Float => "REAL"
    String | Text => "TEXT"
  }
}

///|
fn default_sql(
  value : Json,
  path : String,
) -> Result[String, @errors.EngineError] {
  match value {
    True => Ok("1")
    False => Ok("0")
    Number(number, ..) => Ok(number.to_string())
    _ =>
      Err(
        @errors.invalid_dsl(
          "this SQLite adapter does not support this default value", path,
        ),
      )
  }
}

///|
fn column_sql(column : Column) -> Result[String, @errors.EngineError] {
  if column.nullable {
    return Err(
      @errors.invalid_dsl(
        "nullable SQLite columns are not supported yet",
        column.name,
      ),
    )
  }
  let mut sql = column.name +
    " " +
    sqlite_type(column.column_type) +
    " NOT NULL"
  if column.column_type == Id || column.primary {
    sql = sql + " PRIMARY KEY"
  }
  if column.unique {
    sql = sql + " UNIQUE"
  }
  match column.default_value {
    Some(value) =>
      match default_sql(value, column.name + ".default") {
        Ok(default_value) => sql = sql + " DEFAULT " + default_value
        Err(error) => return Err(error)
      }
    None => ()
  }
  Ok(sql)
}

///|
pub fn create_table_sql(model : Model) -> Result[String, @errors.EngineError] {
  let definitions : Array[String] = []
  for column in model.columns {
    match column_sql(column) {
      Ok(value) => definitions.push(value)
      Err(error) => return Err(error)
    }
  }
  Ok(
    "CREATE TABLE IF NOT EXISTS " +
    model.table +
    " (" +
    definitions.join(", ") +
    ")",
  )
}

///|
pub fn migrate(
  connection : @sqlite3.Connection,
  model : Model,
) -> Result[Unit, @errors.EngineError] {
  let sql = match create_table_sql(model) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  try {
    let statement = connection.prepare(sql)
    statement.step_once()
    statement.finalize()
    Ok(())
  } catch {
    (_ : @sqlite3.SqliteError) =>
      Err(@errors.invalid_dsl("could not create model schema", model.name))
  }
}
