///|
pub(all) struct Request {
  verb : String
  path : String
  body : Json
  query : Map[String, String]
  headers : Map[String, String]
} derive(Debug)

///|
pub fn status_for(error : @errors.EngineError) -> Int {
  match error.code {
    @errors.InvalidArgument => 400
    @errors.MethodNotAllowed => 405
    @errors.RecordNotFound
    | @errors.RouteNotFound
    | @errors.FlowNotFound
    | @errors.ProcessNotFound => 404
    _ => 500
  }
}

///|
fn param_values(values : Map[String, String]) -> Map[String, Json] {
  let result : Map[String, Json] = Map([])
  for key in values.keys() {
    let value = values.get(key).unwrap()
    let integer = @string.parse_int(value) catch { _ => -1 }
    if integer >= 0 && integer.to_string() == value {
      result.set(key, Json::number(integer.to_double()))
    } else {
      result.set(key, Json::string(value))
    }
  }
  result
}

///|
pub fn invoke(
  routes : Array[Route],
  registry : @process.Registry,
  connection : @sqlite3.Connection,
  request : Request,
) -> Result[Json, @errors.EngineError] {
  let matched = match match_route(routes, request.verb, request.path) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let context : @binding.Context = {
    input: {
      "params": Json::object(param_values(matched.params)),
      "body": request.body,
      "query": Json::object(string_values(request.query)),
      "headers": Json::object(string_values(request.headers)),
      "method": request.verb,
      "path": request.path,
    },
    results: Map([]),
    globals: Map([]),
  }
  let input = match @binding.resolve(matched.route.input, context, "request") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  registry.run(connection, matched.route.process, input)
}

///|
fn string_values(values : Map[String, String]) -> Map[String, Json] {
  let result : Map[String, Json] = Map([])
  for key in values.keys() {
    result.set(key, Json::string(values.get(key).unwrap()))
  }
  result
}

///|
fn hex(value : Int) -> Int {
  if value >= 48 && value <= 57 {
    value - 48
  } else if value >= 65 && value <= 70 {
    value - 55
  } else if value >= 97 && value <= 102 {
    value - 87
  } else {
    -1
  }
}

///|
pub fn percent_decode(
  source : String,
  path : String,
) -> Result[String, @errors.EngineError] {
  let output = StringBuilder::new()
  let mut i = 0
  while i < source.length() {
    let code = source.view().unsafe_get(i).to_int()
    if code == 37 {
      if i + 2 >= source.length() {
        return Err(@errors.invalid_argument("invalid percent encoding", path))
      }
      let high = hex(source.view().unsafe_get(i + 1).to_int())
      let low = hex(source.view().unsafe_get(i + 2).to_int())
      if high < 0 || low < 0 {
        return Err(@errors.invalid_argument("invalid percent encoding", path))
      }
      output.write_char((high * 16 + low).unsafe_to_char())
      i = i + 3
    } else {
      output.write_char(code.unsafe_to_char())
      i = i + 1
    }
  }
  Ok(output.to_string())
}

///|
pub fn parse_query(
  source : String,
) -> Result[Map[String, String], @errors.EngineError] {
  let result : Map[String, String] = Map([])
  if source == "" {
    return Ok(result)
  }
  let items : Array[String] = []
  source.split("&").each(item => items.push(item.to_owned()))
  if items.length() > 100 {
    return Err(@errors.invalid_argument("too many query parameters", "query"))
  }
  for item in items {
    let pair : Array[String] = []
    item.split("=").each(part => pair.push(part.to_owned()))
    if pair.length() != 2 || pair[0] == "" {
      return Err(@errors.invalid_argument("invalid query parameter", "query"))
    }
    let key = match percent_decode(pair[0], "query") {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let value = match percent_decode(pair[1], "query") {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if result.contains(key) {
      return Err(
        @errors.invalid_argument("duplicate query parameter", "query." + key),
      )
    }
    result.set(key, value)
  }
  Ok(result)
}
