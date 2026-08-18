///|
fn route(verb : String, path : String) -> Route {
  { verb, path, process: "models.todo.Find", input: {} }
}

///|
test "router matches parameters and reports missing routes" {
  let routes = [route("GET", "/todos/:id")]
  match match_route(routes, "GET", "/todos/42") {
    Ok(found) => assert_eq(found.params.get("id"), Some("42"))
    Err(error) => abort(error.message)
  }
  match match_route(routes, "DELETE", "/todos/42") {
    Err(error) => {
      assert_eq(error.code, @errors.MethodNotAllowed)
      assert_eq(error.path, "GET")
    }
    Ok(_) => abort("expected method error")
  }
  match match_route(routes, "GET", "/missing") {
    Err(error) => assert_eq(error.code, @errors.RouteNotFound)
    Ok(_) => abort("expected missing route")
  }
}

///|
test "router prefers static paths and rejects equivalent patterns" {
  let routes = [route("GET", "/todos/:id"), route("GET", "/todos/new")]
  match match_route(routes, "GET", "/todos/new") {
    Ok(found) => assert_eq(found.route.path, "/todos/new")
    Err(error) => abort(error.message)
  }
  let first : Api = {
    id: "first",
    name: "First",
    routes: [route("GET", "/todos/:id")],
  }
  let second : Api = {
    id: "second",
    name: "Second",
    routes: [route("GET", "/todos/:name")],
  }
  match validate_route_set([first], second, "apis/second.json") {
    Err(error) => assert_eq(error.code, @errors.InvalidDsl)
    Ok(_) => abort("expected equivalent route error")
  }
}

///|
test "HTTP helpers validate listen and query encoding" {
  assert_true(valid_listen_address("127.0.0.1:8080"))
  assert_false(valid_listen_address("localhost:8080"))
  assert_false(valid_listen_address("127.0.0.1:70000"))
  match parse_query("name=Moon%20Yao&done=false") {
    Ok(query) => {
      assert_eq(query.get("name"), Some("Moon Yao"))
      assert_eq(query.get("done"), Some("false"))
    }
    Err(error) => abort(error.message)
  }
  match parse_query("id=1&id=2") {
    Err(error) => assert_eq(error.code, @errors.InvalidArgument)
    Ok(_) => abort("expected duplicate query error")
  }
}

///|
test "router rejects invalid route declarations" {
  match validate_route(route("PUT", "/todos"), "apis/todo.json.routes[0]") {
    Err(error) => assert_eq(error.code, @errors.InvalidDsl)
    Ok(_) => abort("expected invalid method")
  }
  match
    validate_route(route("GET", "/todos/:id/:id"), "apis/todo.json.routes[0]") {
    Err(error) => assert_eq(error.code, @errors.InvalidDsl)
    Ok(_) => abort("expected duplicate parameter")
  }
  for path in ["/v1/chats", "/agent/app.js"] {
    match validate_route(route("GET", path), "apis/todo.json.routes[0]") {
      Err(error) => assert_eq(error.code, @errors.InvalidDsl)
      Ok(_) => abort("expected reserved namespace error")
    }
  }
}
