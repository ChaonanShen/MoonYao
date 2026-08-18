///|
pub(all) enum Root {
  Input
  Results
  Globals
} derive(Eq, Debug)

///|
pub(all) struct Binding {
  root : Root
  segments : Array[String]
} derive(Eq, Debug)

///|
pub(all) struct Context {
  input : Json
  results : Map[String, Json]
  globals : Map[String, Json]
}

///|
fn root_value(context : Context, root : Root) -> Json {
  match root {
    Input => context.input
    Results => Json::object(context.results)
    Globals => Json::object(context.globals)
  }
}

///|
pub fn parse(
  value : String,
  path : String,
) -> Result[Binding?, @errors.EngineError] {
  if !value.has_prefix("$") {
    return Ok(None)
  }
  let pieces : Array[String] = []
  value[1:].split(".").each(part => pieces.push(part.to_owned()))
  if pieces.is_empty() {
    return Err(@errors.invalid_dsl("invalid binding", path))
  }
  let root = match pieces[0] {
    "in" => Input
    "res" => Results
    "global" => Globals
    _ => return Err(@errors.invalid_dsl("unknown binding root", path))
  }
  let segments : Array[String] = []
  for index = 1; index < pieces.length(); index = index + 1 {
    let segment = pieces[index]
    if !@model.is_identifier(segment) {
      return Err(@errors.invalid_dsl("invalid binding path", path))
    }
    segments.push(segment)
  }
  Ok(Some({ root, segments }))
}

///|
pub fn references_result(value : Json, name : String) -> Bool {
  match value {
    String(text) =>
      match parse(text, "$") {
        Ok(Some(binding)) =>
          binding.root == Results &&
          binding.segments.length() > 0 &&
          binding.segments[0] == name
        _ => false
      }
    Array(values) => values.any(item => references_result(item, name))
    Object(object) =>
      object
      .keys()
      .any(key => references_result(object.get(key).unwrap(), name))
    _ => false
  }
}

///|
pub fn resolve(
  value : Json,
  context : Context,
  path : String,
) -> Result[Json, @errors.EngineError] {
  match value {
    String(text) => {
      let binding = match parse(text, path) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      match binding {
        None => Ok(value)
        Some(binding) => {
          let mut current = root_value(context, binding.root)
          for segment in binding.segments {
            match current {
              Object(object) =>
                match object.get(segment) {
                  Some(next) => current = next
                  None =>
                    return Err(
                      @errors.invalid_argument(
                        "binding path was not found", path,
                      ),
                    )
                }
              _ =>
                return Err(
                  @errors.invalid_argument(
                    "binding path crosses a non-object value", path,
                  ),
                )
            }
          }
          Ok(current)
        }
      }
    }
    Array(values) => {
      let resolved : Array[Json] = []
      for index = 0; index < values.length(); index = index + 1 {
        match
          resolve(values[index], context, path + "[" + index.to_string() + "]") {
          Ok(value) => resolved.push(value)
          Err(error) => return Err(error)
        }
      }
      Ok(Json::array(resolved))
    }
    Object(object) => {
      let resolved : Map[String, Json] = Map([])
      for key in object.keys() {
        match resolve(object.get(key).unwrap(), context, path + "." + key) {
          Ok(value) => resolved.set(key, value)
          Err(error) => return Err(error)
        }
      }
      Ok(Json::object(resolved))
    }
    _ => Ok(value)
  }
}

///|
pub fn references_global(value : Json, name : String) -> Bool {
  match value {
    String(text) =>
      match parse(text, "$") {
        Ok(Some(binding)) =>
          binding.root == Globals &&
          binding.segments.length() > 0 &&
          binding.segments[0] == name
        _ => false
      }
    Array(values) => values.any(item => references_global(item, name))
    Object(object) =>
      object
      .keys()
      .any(key => references_global(object.get(key).unwrap(), name))
    _ => false
  }
}

///|
pub fn validate_references(
  value : Json,
  result_names : Array[String],
  globals : Map[String, Json],
  path : String,
) -> Result[Unit, @errors.EngineError] {
  match value {
    String(text) =>
      match parse(text, path) {
        Err(error) => Err(error)
        Ok(None) => Ok(())
        Ok(Some(binding)) =>
          if binding.root == Results &&
            !binding.segments.is_empty() &&
            !result_names.contains(binding.segments[0]) {
            Err(
              @errors.invalid_dsl("unknown or forward result reference", path),
            )
          } else if binding.root == Globals &&
            !binding.segments.is_empty() &&
            !globals.contains(binding.segments[0]) {
            Err(@errors.invalid_dsl("unknown global reference", path))
          } else {
            Ok(())
          }
      }
    Array(values) => {
      for index = 0; index < values.length(); index = index + 1 {
        match
          validate_references(
            values[index],
            result_names,
            globals,
            path + "[" + index.to_string() + "]",
          ) {
          Err(error) => return Err(error)
          Ok(_) => ()
        }
      }
      Ok(())
    }
    Object(object) => {
      for key in object.keys() {
        match
          validate_references(
            object.get(key).unwrap(),
            result_names,
            globals,
            path + "." + key,
          ) {
          Err(error) => return Err(error)
          Ok(_) => ()
        }
      }
      Ok(())
    }
    _ => Ok(())
  }
}
