///|
test "tool schema validates nested arguments and rejects unknown properties" {
  let schema : Json = {
    "type": "object",
    "properties": {
      "data": {
        "type": "object",
        "properties": {
          "title": { "type": "string", "minLength": 1, "maxLength": 20 },
          "priority": { "type": "integer", "minimum": 1, "maximum": 3 },
        },
        "required": ["title"],
        "additionalProperties": false,
      },
    },
    "required": ["data"],
    "additionalProperties": false,
  }
  match validate_schema(schema, "tools[0].input_schema") {
    Ok(_) => ()
    Err(error) => fail(error.message)
  }
  match
    validate_arguments({ "data": { "title": "ship", "priority": 2 } }, schema) {
    Ok(_) => ()
    Err(error) => fail(error.message)
  }
  match
    validate_arguments({ "data": { "title": "ship", "extra": true } }, schema) {
    Err(error) => assert_eq(error.path, "$args.data.extra")
    Ok(_) => fail("expected unknown-property error")
  }
}

///|
test "tool schema meta-validation rejects unsupported and inconsistent keywords" {
  match validate_schema({ "type": "string", "pattern": ".*" }, "schema") {
    Err(error) => assert_eq(error.path, "schema.pattern")
    Ok(_) => fail("expected unsupported keyword")
  }
  match
    validate_schema(
      {
        "type": "object",
        "properties": { "name": { "type": "string" } },
        "required": ["missing"],
      },
      "schema",
    ) {
    Err(error) => assert_true(error.path.contains("required"))
    Ok(_) => fail("expected undeclared required property")
  }
  match
    validate_schema(
      { "type": "array", "items": { "type": "boolean" }, "maxItems": 101 },
      "schema",
    ) {
    Err(error) => assert_eq(error.code, @errors.InvalidDsl)
    Ok(_) => fail("expected array bound error")
  }
}

///|
test "tool parser rejects duplicate names and accepts the documented shape" {
  let source : Json = [
    {
      "name": "create_todo",
      "description": "Create a Todo.",
      "process": "models.todo.Create",
      "input_schema": {
        "type": "object",
        "properties": {
          "data": {
            "type": "object",
            "properties": {},
            "additionalProperties": false,
          },
        },
        "required": ["data"],
        "additionalProperties": false,
      },
    },
  ]
  match parse_tools(source, "agents/todo/tools.json") {
    Ok(tools) => assert_eq(tools[0].process, "models.todo.Create")
    Err(error) => fail(error.message)
  }
  guard source is Array(values) else { fail("expected array") }
  match parse_tools(Json::array(values + values), "agents/todo/tools.json") {
    Err(error) => assert_true(error.message.contains("duplicate"))
    Ok(_) => fail("expected duplicate tool")
  }
}
