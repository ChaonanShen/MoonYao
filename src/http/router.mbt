///|
pub(all) struct Route {
  verb : String
  path : String
  process : String
  input : Json
} derive(Debug)

///|
pub(all) struct Match {
  route : Route
  params : Map[String, String]
} derive(Debug)

///|
pub(all) struct Api {
  id : String
  name : String
  routes : Array[Route]
} derive(Debug)

///|
fn require_string(
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
pub fn valid_listen_address(value : String) -> Bool {
  let parts : Array[String] = []
  value.split(":").each(part => parts.push(part.to_owned()))
  if parts.length() != 2 {
    return false
  }
  let port = @string.parse_int(parts[1]) catch { _ => 0 }
  if port < 1 || port > 65535 {
    return false
  }
  let octets : Array[String] = []
  parts[0].split(".").each(part => octets.push(part.to_owned()))
  if octets.length() != 4 {
    return false
  }
  for octet in octets {
    let number = @string.parse_int(octet) catch { _ => -1 }
    if number < 0 || number > 255 || number.to_string() != octet {
      return false
    }
  }
  true
}

///|
fn known(
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
pub fn parse_api(
  value : Json,
  path : String,
) -> Result[Api, @errors.EngineError] {
  guard value is Object(object) else {
    return Err(@errors.invalid_dsl("expected an object", path))
  }
  match known(object, ["id", "name", "routes"], path) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let id = match require_string(object, "id", path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !@model.is_identifier(id) {
    return Err(@errors.invalid_dsl("API id is invalid", path + ".id"))
  }
  let name = match require_string(object, "name", path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let values = match object.get("routes") {
    Some(Array(value)) if !value.is_empty() => value
    Some(_) =>
      return Err(
        @errors.invalid_dsl("expected a non-empty array", path + ".routes"),
      )
    None =>
      return Err(@errors.invalid_dsl("missing required key", path + ".routes"))
  }
  let routes : Array[Route] = []
  for index = 0; index < values.length(); index = index + 1 {
    let route_path = path + ".routes[" + index.to_string() + "]"
    guard values[index] is Object(route) else {
      return Err(@errors.invalid_dsl("expected an object", route_path))
    }
    match known(route, ["method", "path", "process", "input"], route_path) {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
    let verb = match require_string(route, "method", route_path) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let route_path_value = match require_string(route, "path", route_path) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let process = match require_string(route, "process", route_path) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let input = match route.get("input") {
      Some(value) => value
      None =>
        return Err(
          @errors.invalid_dsl("missing required key", route_path + ".input"),
        )
    }
    let item = { verb, path: route_path_value, process, input }
    match validate_route(item, route_path) {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
    if routes.any(existing => {
        existing.verb == item.verb && equivalent(existing.path, item.path)
      }) {
      return Err(@errors.invalid_dsl("duplicate route", route_path))
    }
    routes.push(item)
  }
  Ok({ id, name, routes })
}

///|
fn equivalent(left : String, right : String) -> Bool {
  let a = split_path(left, "path").unwrap()
  let b = split_path(right, "path").unwrap()
  if a.length() != b.length() {
    return false
  }
  for i = 0; i < a.length(); i = i + 1 {
    if a[i].has_prefix(":") != b[i].has_prefix(":") ||
      (!a[i].has_prefix(":") && a[i] != b[i]) {
      return false
    }
  }
  true
}

///|
pub fn validate_route_set(
  existing : Array[Api],
  current : Api,
  path : String,
) -> Result[Unit, @errors.EngineError] {
  let routes : Array[Route] = []
  for api in existing {
    for route in api.routes {
      routes.push(route)
    }
  }
  for route in current.routes {
    if routes.any(old => {
        old.verb == route.verb && equivalent(old.path, route.path)
      }) {
      return Err(
        @errors.invalid_dsl("duplicate equivalent route", path + ".routes"),
      )
    }
    routes.push(route)
  }
  Ok(())
}

///|
fn split_path(
  path : String,
  diagnostic : String,
) -> Result[Array[String], @errors.EngineError] {
  if !path.has_prefix("/") ||
    path == "/" ||
    path.contains("?") ||
    path.contains("#") {
    return Err(@errors.invalid_dsl("invalid route path", diagnostic))
  }
  let values : Array[String] = []
  path[1:].split("/").each(part => values.push(part.to_owned()))
  for value in values {
    if value.length() == 0 ||
      value == "." ||
      value == ".." ||
      value.contains("*") {
      return Err(@errors.invalid_dsl("invalid route path", diagnostic))
    }
  }
  Ok(values)
}

///|
pub fn validate_route(
  route : Route,
  diagnostic : String,
) -> Result[Unit, @errors.EngineError] {
  if route.path == "/v1" ||
    route.path.has_prefix("/v1/") ||
    route.path == "/agent" ||
    route.path.has_prefix("/agent/") {
    return Err(
      @errors.invalid_dsl(
        "route uses a reserved system namespace",
        diagnostic + ".path",
      ),
    )
  }
  if !["GET", "POST", "PATCH", "DELETE"].contains(route.verb) {
    return Err(
      @errors.invalid_dsl("unsupported HTTP method", diagnostic + ".method"),
    )
  }
  let values = match split_path(route.path, diagnostic + ".path") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let parameters : Array[String] = []
  for value in values {
    if value.has_prefix(":") {
      let name = value[1:].to_owned()
      if !@model.is_identifier(name) || parameters.contains(name) {
        return Err(
          @errors.invalid_dsl("invalid route parameter", diagnostic + ".path"),
        )
      }
      parameters.push(name)
    }
  }
  Ok(())
}

///|
pub fn match_route(
  routes : Array[Route],
  verb : String,
  path : String,
) -> Result[Match, @errors.EngineError] {
  let request = match split_path(path, "path") {
    Ok(value) => value
    Err(_) =>
      return Err(@errors.invalid_argument("invalid request path", "path"))
  }
  let allowed : Array[String] = []
  let mut best : Match? = None
  let mut best_static = -1
  for route in routes {
    let pattern = match split_path(route.path, "path") {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if pattern.length() != request.length() {
      continue
    }
    let params : Map[String, String] = Map([])
    let mut matches = true
    for index = 0; index < pattern.length(); index = index + 1 {
      if pattern[index].has_prefix(":") {
        let decoded = match percent_decode(request[index], "params") {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        params.set(pattern[index][1:].to_owned(), decoded)
      } else if pattern[index] != request[index] {
        matches = false
      }
    }
    if matches {
      if route.verb == verb {
        let mut static_count = 0
        for segment in pattern {
          if !segment.has_prefix(":") {
            static_count = static_count + 1
          }
        }
        if static_count > best_static {
          best = Some({ route, params })
          best_static = static_count
        }
      } else if !allowed.contains(route.verb) {
        allowed.push(route.verb)
      }
    }
  }
  match best {
    Some(value) => Ok(value)
    None if !allowed.is_empty() => {
      allowed.sort()
      Err(@errors.method_not_allowed(allowed.join(", ")))
    }
    None => Err(@errors.route_not_found(path))
  }
}
