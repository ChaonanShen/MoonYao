///|
pub(all) struct Application {
  name : String
  database : String
  models : Array[@model.Model]
} derive(Debug)

///|
fn parse_app(
  value : Json,
  path : String,
) -> Result[(String, String), @errors.EngineError] {
  guard value is Object(object) else {
    return Err(@errors.invalid_dsl("expected an object", path))
  }
  for key in object.keys() {
    if key != "name" && key != "database" {
      return Err(@errors.invalid_dsl("unknown key '\{key}'", path + "." + key))
    }
  }
  let name = match object.get("name") {
    Some(String(value)) if value.length() > 0 => value
    Some(_) =>
      return Err(
        @errors.invalid_dsl("expected a non-empty string", path + ".name"),
      )
    None =>
      return Err(@errors.invalid_dsl("missing required key", path + ".name"))
  }
  let database = match object.get("database") {
    Some(String(value)) if value.length() > 0 => value
    Some(_) =>
      return Err(
        @errors.invalid_dsl("expected a non-empty string", path + ".database"),
      )
    None =>
      return Err(
        @errors.invalid_dsl("missing required key", path + ".database"),
      )
  }
  Ok((name, database))
}

///|
fn read_json(path : String) -> Result[Json, @errors.EngineError] {
  let source = @fs.read_file_to_string(path) catch {
    (_ : @fs.IOError) =>
      return Err(@errors.invalid_dsl("could not read file", path))
  }
  Ok(@json.parse(source)) catch {
    (_ : @json.ParseError) => Err(@errors.invalid_dsl("invalid JSON", path))
  }
}

///|
pub fn load(root : String) -> Result[Application, @errors.EngineError] {
  let app_path = root + "/app.json"
  let app_json = match read_json(app_path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let (name, database) = match parse_app(app_json, "app.json") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let model_directory = root + "/models"
  let entries = @fs.read_dir(model_directory) catch {
    (_ : @fs.IOError) =>
      return Err(
        @errors.invalid_dsl("could not read models directory", "models"),
      )
  }
  entries.sort()
  let models : Array[@model.Model] = []
  for entry in entries {
    if entry.has_suffix(".json") {
      let relative_path = "models/" + entry
      let json = match read_json(model_directory + "/" + entry) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let model = match @model.parse_model(json, relative_path) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if models.any(existing => existing.name == model.name) {
        return Err(
          @errors.invalid_dsl("duplicate model name", relative_path + ".name"),
        )
      }
      if models.any(existing => existing.table == model.table) {
        return Err(
          @errors.invalid_dsl("duplicate model table", relative_path + ".table"),
        )
      }
      models.push(model)
    }
  }
  Ok({ name, database, models })
}
