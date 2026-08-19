///|
test "canonical text message round trips" {
  let original = text_message(User, "hello")
  match decode(encode(original), "message") {
    Ok(value) => assert_eq(value, original)
    Err(error) => fail(error.message)
  }
}

///|
test "canonical multimodal parts round trip" {
  let parts : Array[ContentPart] = [
    TextPart("look"),
    ImageRef("att_image", Auto),
    FileRef("att_file", "notes.txt"),
  ]
  let original : Message = {
    role: User,
    content: Some(Parts(parts)),
    name: None,
    tool_call_id: None,
    reasoning_content: None,
    tool_calls: [],
    refusal: None,
  }
  match decode(encode(original), "message") {
    Ok(value) => assert_eq(value, original)
    Err(error) => fail(error.message)
  }
}

///|
test "canonical decoder rejects unknown fields and invalid role fields" {
  match decode({ "role": "user", "content": "x", "extra": true }, "message") {
    Err(error) => assert_eq(error.code, @errors.InvalidArgument)
    Ok(_) => fail("expected unknown field error")
  }
  match
    decode(
      { "role": "user", "content": "x", "reasoning_content": "hidden" },
      "message",
    ) {
    Err(error) => assert_eq(error.code, @errors.InvalidArgument)
    Ok(_) => fail("expected assistant field error")
  }
}

///|
test "legacy text adapter preserves roles" {
  match from_legacy("assistant", "done") {
    Ok(value) => assert_eq(value, text_message(Assistant, "done"))
    Err(error) => fail(error.message)
  }
}
