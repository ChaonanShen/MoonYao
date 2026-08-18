///|
pub(all) struct Application {
  name : String
  database : String
  models : Array[@model.Model]
  flows : Array[@flow.Flow]
  globals : Map[String, Json]
  apis : Array[@http.Api]
  listen : String
} derive(Debug)

///|
fn parse_app(
  value : Json,
  path : String,
) -> Result[(String, String, Map[String, Json], String), @errors.EngineError] {
  guard value is Object(object) else {
    return Err(@errors.invalid_dsl("expected an object", path))
  }
  for key in object.keys() {
    if key != "name" && key != "database" && key != "globals" && key != "listen" {
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
  let globals : Map[String, Json] = match object.get("globals") {
    None => Map([])
    Some(Object(value)) => value
    Some(_) =>
      return Err(@errors.invalid_dsl("expected an object", path + ".globals"))
  }
  for key in globals.keys() {
    if !@model.is_identifier(key) {
      return Err(
        @errors.invalid_dsl("global name is invalid", path + ".globals." + key),
      )
    }
  }
  let listen = match object.get("listen") {
    None => "127.0.0.1:8080"
    Some(String(value)) if @http.valid_listen_address(value) => value
    Some(_) =>
      return Err(
        @errors.invalid_dsl(
          "listen must be an IP literal and port",
          path + ".listen",
        ),
      )
  }
  Ok((name, database, globals, listen))
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
  let (name, database, globals, listen) = match
    parse_app(app_json, "app.json") {
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
  let flow_directory = root + "/flows"
  let flows : Array[@flow.Flow] = []
  let flow_paths : Map[String, String] = Map([])
  if @fs.path_exists(flow_directory) {
    let entries = @fs.read_dir(flow_directory) catch {
      (_ : @fs.IOError) =>
        return Err(
          @errors.invalid_dsl("could not read flows directory", "flows"),
        )
    }
    entries.sort()
    for entry in entries {
      if entry.has_suffix(".json") {
        let relative_path = "flows/" + entry
        let json = match read_json(flow_directory + "/" + entry) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let flow = match @flow.parse(json, relative_path) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        if flows.any(existing => existing.id == flow.id) {
          return Err(
            @errors.invalid_dsl("duplicate flow id", relative_path + ".id"),
          )
        }
        flows.push(flow)
        flow_paths.set(flow.id, relative_path)
      }
    }
  }
  let process_names : Array[String] = []
  for model in models {
    for operation in ["Find", "List", "Create", "Update", "Delete"] {
      process_names.push("models." + model.name + "." + operation)
    }
  }
  for flow in flows {
    process_names.push("flows." + flow.id)
  }
  process_names.sort()
  for flow in flows {
    match
      @flow.validate(
        flow,
        flow_paths.get(flow.id).unwrap(),
        process_names,
        globals,
      ) {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
  }
  for flow in flows {
    if flow_reaches(flows, flow.id, flow.id, []) {
      return Err(@errors.invalid_dsl("flow call cycle", "flows." + flow.id))
    }
  }
  let api_directory = root + "/apis"
  let apis : Array[@http.Api] = []
  if @fs.path_exists(api_directory) {
    let entries = @fs.read_dir(api_directory) catch {
      (_ : @fs.IOError) =>
        return Err(@errors.invalid_dsl("could not read APIs directory", "apis"))
    }
    entries.sort()
    for entry in entries {
      if entry.has_suffix(".json") {
        let relative_path = "apis/" + entry
        let json = match read_json(api_directory + "/" + entry) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        let api = match @http.parse_api(json, relative_path) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        if apis.any(existing => existing.id == api.id) {
          return Err(
            @errors.invalid_dsl("duplicate API id", relative_path + ".id"),
          )
        }
        for route in api.routes {
          if !process_names.contains(route.process) {
            return Err(
              @errors.invalid_dsl("unknown process", relative_path + ".routes"),
            )
          }
        }
        match @http.validate_route_set(apis, api, relative_path) {
          Err(error) => return Err(error)
          Ok(_) => ()
        }
        apis.push(api)
      }
    }
  }
  Ok({ name, database, models, flows, globals, apis, listen })
}

///|
fn flow_reaches(
  flows : Array[@flow.Flow],
  current : String,
  target : String,
  seen : Array[String],
) -> Bool {
  if seen.contains(current) {
    return false
  }
  let mut found : @flow.Flow? = None
  for item in flows {
    if item.id == current {
      found = Some(item)
    }
  }
  let flow = match found {
    Some(value) => value
    None => return false
  }
  let next_seen = seen.copy()
  next_seen.push(current)
  for node in flow.nodes {
    if node.process.has_prefix("flows.") {
      let next = node.process["flows.".length():].to_owned()
      if next == target || flow_reaches(flows, next, target, next_seen) {
        return true
      }
    }
  }
  false
}
