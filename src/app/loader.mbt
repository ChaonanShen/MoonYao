///|
pub(all) struct Application {
  name : String
  database : String
  models : Array[@model.Model]
  flows : Array[@flow.Flow]
  globals : Map[String, Json]
  apis : Array[@http.Api]
  listen : String
  connectors : Array[@llm.Connector]
  agents : Array[@agent.Agent]
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
  let connector_directory = root + "/connectors"
  let connectors : Array[@llm.Connector] = []
  if @fs.path_exists(connector_directory) {
    let connector_entries = @fs.read_dir(connector_directory) catch {
      (_ : @fs.IOError) =>
        return Err(
          @errors.invalid_dsl(
            "could not read connectors directory", "connectors",
          ),
        )
    }
    connector_entries.sort()
    for entry in connector_entries {
      if entry.has_suffix(".json") {
        let relative_path = "connectors/" + entry
        let json = match read_json(connector_directory + "/" + entry) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        let parsed = match @llm.parse_connector(json, relative_path) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        if connectors.any(existing => existing.id == parsed.id) {
          return Err(
            @errors.invalid_dsl("duplicate connector id", relative_path + ".id"),
          )
        }
        connectors.push(parsed)
      }
    }
  }
  let agents : Array[@agent.Agent] = []
  let agent_directory = root + "/agents"
  if @fs.path_exists(agent_directory) {
    let agent_entries = @fs.read_dir(agent_directory) catch {
      (_ : @fs.IOError) =>
        return Err(
          @errors.invalid_dsl("could not read agents directory", "agents"),
        )
    }
    agent_entries.sort()
    for entry in agent_entries {
      let agent_path = agent_directory + "/" + entry + "/agent.json"
      let prompt_path = agent_directory + "/" + entry + "/prompts.json"
      let tools_path = agent_directory + "/" + entry + "/tools.json"
      if @fs.path_exists(agent_path) {
        let agent_json = match read_json(agent_path) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        let parsed = match
          @agent.parse_agent(
            agent_json,
            entry,
            "agents/" + entry + "/agent.json",
          ) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        if agents.any(existing => existing.id == parsed.id) {
          return Err(
            @errors.invalid_dsl(
              "duplicate agent id",
              "agents/" + entry + "/agent.json.id",
            ),
          )
        }
        if !@fs.path_exists(prompt_path) {
          return Err(
            @errors.invalid_dsl(
              "missing prompts.json",
              "agents/" + entry + "/prompts.json",
            ),
          )
        }
        let prompt_json = match read_json(prompt_path) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        let prompts = match
          @agent.parse_prompts(prompt_json, "agents/" + entry + "/prompts.json") {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        let definitions = if @fs.path_exists(tools_path) {
          let tool_json = match read_json(tools_path) {
            Ok(v) => v
            Err(e) => return Err(e)
          }
          match
            @agent.parse_tools(tool_json, "agents/" + entry + "/tools.json") {
            Ok(v) => v
            Err(e) => return Err(e)
          }
        } else {
          []
        }
        for tool in definitions {
          if !process_names.contains(tool.process) ||
            tool.process.has_prefix("agent.") ||
            tool.process.has_prefix("conversation.") {
            return Err(
              @errors.invalid_dsl(
                "unknown or internal tool process",
                "agents/" + entry + "/tools.json",
              ),
            )
          }
        }
        if !parsed.tool_names.is_empty() && definitions.is_empty() {
          return Err(
            @errors.invalid_dsl(
              "agent tool allowlist requires tools.json",
              "agents/" + entry + "/tools.json",
            ),
          )
        }
        let tools : Array[@agent.Tool] = []
        for name in parsed.tool_names {
          let mut selected : @agent.Tool? = None
          for tool in definitions {
            if tool.name == name {
              selected = Some(tool)
            }
          }
          let tool = match selected {
            Some(value) => value
            None =>
              return Err(
                @errors.invalid_dsl(
                  "unknown tool",
                  "agents/" + entry + "/agent.json.tools",
                ),
              )
          }
          tools.push(tool)
        }
        for
          hook in [
            ("hooks.create", parsed.create_process),
            ("hooks.next", parsed.next_process),
            ("before_process", parsed.before_process),
            ("after_process", parsed.after_process),
          ] {
          let (kind, process) = hook
          if process.length() > 0 && !process_names.contains(process) {
            return Err(
              @errors.invalid_dsl(
                "unknown hook process",
                "agents/" + entry + "/agent.json." + kind,
              ),
            )
          }
        }
        agents.push({
          id: parsed.id,
          name: parsed.name,
          description: parsed.description,
          connector: parsed.connector,
          options: parsed.options,
          prompts,
          tools,
          tool_names: parsed.tool_names,
          create_process: parsed.create_process,
          next_process: parsed.next_process,
          before_process: parsed.before_process,
          after_process: parsed.after_process,
        })
      }
    }
  }
  for agent in agents {
    if !connectors.any(connector => connector.id == agent.connector) {
      return Err(
        @errors.invalid_dsl(
          "unknown agent connector",
          "agents/" + agent.id + "/agent.json.connector",
        ),
      )
    }
  }
  Ok({
    name,
    database,
    models,
    flows,
    globals,
    apis,
    listen,
    connectors,
    agents,
  })
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
