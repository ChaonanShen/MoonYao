///|
fn parsed_flow(value : Json) -> Flow {
  match parse(value, "flows/create.json") {
    Ok(value) => value
    Err(error) => abort(error.message)
  }
}

///|
test "flow validates result ordering and executes nodes in sequence" {
  let flow = parsed_flow({
    "id": "create",
    "name": "Create",
    "nodes": [
      { "name": "first", "process": "test.first", "input": "$in" },
      {
        "name": "second",
        "process": "test.second",
        "input": { "id": "$res.first.id" },
      },
    ],
    "output": "$res.second",
  })
  match
    validate(
      flow,
      "flows/create.json",
      ["test.first", "test.second", "flows.create"],
      Map([]),
    ) {
    Err(error) => abort(error.message)
    Ok(_) => ()
  }
  let calls : Array[String] = []
  let result = match
    execute(flow, { "title": "P3" }, Map([]), fn(name, input) {
      calls.push(name)
      match name {
        "test.first" => Ok({ "id": 4, "title": input })
        "test.second" => Ok({ "completed": input })
        _ => Err(@errors.process_not_found(name))
      }
    }) {
    Ok(value) => value
    Err(error) => abort(error.message)
  }
  assert_eq(calls, ["test.first", "test.second"])
  assert_eq(result, { "completed": { "id": 4 } })
}

///|
test "flow rejects forward and unknown result references" {
  let flow = parsed_flow({
    "id": "bad",
    "name": "Bad",
    "nodes": [
      { "name": "first", "process": "test.one", "input": "$res.second" },
      { "name": "second", "process": "test.two", "input": {} },
    ],
    "output": "$res.first",
  })
  match
    validate(
      flow,
      "flows/bad.json",
      ["test.one", "test.two", "flows.bad"],
      Map([]),
    ) {
    Err(error) => assert_eq(error.code, @errors.InvalidDsl)
    Ok(_) => abort("expected forward reference")
  }
}

///|
test "flow rejects unknown globals during static validation" {
  let flow = parsed_flow({
    "id": "global_test",
    "name": "Global test",
    "nodes": [
      { "name": "first", "process": "test.one", "input": "$global.missing" },
    ],
    "output": "$res.first",
  })
  match validate(flow, "flows/global_test.json", ["test.one"], Map([])) {
    Err(error) => assert_eq(error.code, @errors.InvalidDsl)
    Ok(_) => abort("expected unknown global")
  }
}

///|
test "flow stops after the first failing node" {
  let flow = parsed_flow({
    "id": "stop",
    "name": "Stop",
    "nodes": [
      { "name": "one", "process": "test.fail", "input": {} },
      { "name": "two", "process": "test.never", "input": {} },
    ],
    "output": "$res.two",
  })
  let invoked : Array[String] = []
  match
    execute(flow, {}, Map([]), fn(name, _) {
      invoked.push(name)
      Err(@errors.invalid_argument("failed", "$"))
    }) {
    Err(error) => {
      assert_eq(invoked, ["test.fail"])
      assert_true(error.path.has_prefix("flows.stop.nodes.one"))
    }
    Ok(_) => abort("expected failure")
  }
}
