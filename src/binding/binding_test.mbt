///|
test "binding resolves roots recursively without string interpolation" {
  let results : Map[String, Json] = Map([])
  results.set("todo", { "id": 7, "title": "written" })
  let globals : Map[String, Json] = Map([])
  globals.set("default_done", false)
  let context : Context = {
    input: { "body": { "title": "P3" } },
    results,
    globals,
  }
  let value = match
    resolve(
      {
        "title": "$in.body.title",
        "done": "$global.default_done",
        "items": ["$res.todo", "plain"],
      },
      context,
      "$",
    ) {
    Ok(value) => value
    Err(error) => abort(error.message)
  }
  assert_eq(value, {
    "title": "P3",
    "done": false,
    "items": [{ "id": 7, "title": "written" }, "plain"],
  })
}

///|
test "binding rejects malformed and missing paths" {
  match parse("$res..todo", "$.input") {
    Err(error) => assert_eq(error.code, @errors.InvalidDsl)
    Ok(_) => abort("expected invalid binding")
  }
  let context : Context = { input: {}, results: Map([]), globals: Map([]) }
  match resolve("$in.missing", context, "$.input") {
    Err(error) => assert_eq(error.code, @errors.InvalidArgument)
    Ok(_) => abort("expected missing binding")
  }
}
