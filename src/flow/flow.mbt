///|
pub(all) struct Node {
  name : String
  process : String
  input : Json
} derive(Debug)

///|
pub(all) struct Flow {
  id : String
  name : String
  nodes : Array[Node]
  output : Json
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
fn check_bindings(
  value : Json,
  path : String,
) -> Result[Unit, @errors.EngineError] {
  match value {
    String(text) =>
      match @binding.parse(text, path) {
        Ok(_) => Ok(())
        Err(error) => Err(error)
      }
    Array(values) => {
      for index = 0; index < values.length(); index = index + 1 {
        match
          check_bindings(values[index], path + "[" + index.to_string() + "]") {
          Err(error) => return Err(error)
          Ok(_) => ()
        }
      }
      Ok(())
    }
    Object(object) => {
      for key in object.keys() {
        match check_bindings(object.get(key).unwrap(), path + "." + key) {
          Err(error) => return Err(error)
          Ok(_) => ()
        }
      }
      Ok(())
    }
    _ => Ok(())
  }
}

///|
pub fn parse(value : Json, path : String) -> Result[Flow, @errors.EngineError] {
  guard value is Object(object) else {
    return Err(@errors.invalid_dsl("expected an object", path))
  }
  match known_keys(object, ["id", "name", "nodes", "output"], path) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let id = match required_string(object, "id", path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !@model.is_identifier(id) {
    return Err(@errors.invalid_dsl("flow id is invalid", path + ".id"))
  }
  let name = match required_string(object, "name", path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let nodes_json = match object.get("nodes") {
    Some(Array(value)) if !value.is_empty() => value
    Some(Array(_)) =>
      return Err(
        @errors.invalid_dsl("at least one node is required", path + ".nodes"),
      )
    Some(_) =>
      return Err(@errors.invalid_dsl("expected an array", path + ".nodes"))
    None =>
      return Err(@errors.invalid_dsl("missing required key", path + ".nodes"))
  }
  let output = match object.get("output") {
    Some(value) => value
    None =>
      return Err(@errors.invalid_dsl("missing required key", path + ".output"))
  }
  let nodes : Array[Node] = []
  for index = 0; index < nodes_json.length(); index = index + 1 {
    let node_path = path + ".nodes[" + index.to_string() + "]"
    guard nodes_json[index] is Object(node) else {
      return Err(@errors.invalid_dsl("expected an object", node_path))
    }
    match known_keys(node, ["name", "process", "input"], node_path) {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
    let node_name = match required_string(node, "name", node_path) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if !@model.is_identifier(node_name) {
      return Err(
        @errors.invalid_dsl("node name is invalid", node_path + ".name"),
      )
    }
    if nodes.any(existing => existing.name == node_name) {
      return Err(
        @errors.invalid_dsl("duplicate node name", node_path + ".name"),
      )
    }
    let process = match required_string(node, "process", node_path) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let input = match node.get("input") {
      Some(value) => value
      None =>
        return Err(
          @errors.invalid_dsl("missing required key", node_path + ".input"),
        )
    }
    match check_bindings(input, node_path + ".input") {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
    nodes.push({ name: node_name, process, input })
  }
  match check_bindings(output, path + ".output") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  Ok({ id, name, nodes, output })
}

///|
pub fn validate(
  flow : Flow,
  path : String,
  process_names : Array[String],
  globals : Map[String, Json],
) -> Result[Unit, @errors.EngineError] {
  let result_names : Array[String] = []
  for index = 0; index < flow.nodes.length(); index = index + 1 {
    let node = flow.nodes[index]
    let node_path = path + ".nodes[" + index.to_string() + "]"
    if !process_names.contains(node.process) {
      return Err(@errors.invalid_dsl("unknown process", node_path + ".process"))
    }
    match
      @binding.validate_references(
        node.input,
        result_names,
        globals,
        node_path + ".input",
      ) {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
    result_names.push(node.name)
  }
  match
    @binding.validate_references(
      flow.output,
      result_names,
      globals,
      path + ".output",
    ) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  Ok(())
}

///|
pub fn execute(
  flow : Flow,
  input : Json,
  globals : Map[String, Json],
  invoke : (String, Json) -> Result[Json, @errors.EngineError],
) -> Result[Json, @errors.EngineError] {
  let results : Map[String, Json] = Map([])
  for node in flow.nodes {
    let node_path = "flows." + flow.id + ".nodes." + node.name
    let context : @binding.Context = { input, results, globals }
    let node_input = match
      @binding.resolve(node.input, context, node_path + ".input") {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    match invoke(node.process, node_input) {
      Ok(value) => results.set(node.name, value)
      Err(error) =>
        return Err({
          code: error.code,
          message: error.message,
          path: node_path + "." + error.path,
        })
    }
  }
  @binding.resolve(
    flow.output,
    { input, results, globals },
    "flows." + flow.id + ".output",
  )
}
