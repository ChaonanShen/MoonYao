///|
fn fake_attachment(
  id : String,
) -> Result[ResolvedAttachment, @errors.EngineError] {
  match id {
    "att_image" =>
      Ok({ id, filename: "pixel.png", media_type: "image/png", data: b"png" })
    "att_text" =>
      Ok({ id, filename: "notes.txt", media_type: "text/plain", data: b"hello" })
    _ => Err(@errors.invalid_argument("attachment not found", "attachment"))
  }
}

///|
test "canonical projector expands image and text only at provider boundary" {
  let parts : Array[@content.ContentPart] = [
    @content.TextPart("inspect"),
    @content.ImageRef("att_image", @content.Low),
    @content.FileRef("att_text", "notes.txt"),
  ]
  let message : @content.Message = {
    role: @content.User,
    content: Some(@content.Parts(parts)),
    name: None,
    tool_call_id: None,
    reasoning_content: None,
    tool_calls: [],
    refusal: None,
  }
  let canonical = @content.encode(message).stringify()
  match project_messages([message], fake_attachment) {
    Ok(values) => {
      let wire = values[0].stringify()
      assert_true(wire.contains("data:image/png;base64,cG5n"))
      assert_true(wire.contains("<file name=\\\"notes.txt\\\">"))
      assert_false(canonical.contains("base64"))
    }
    Err(error) => fail(error.message)
  }
}

///|
test "canonical projector preserves assistant and tool fields" {
  let assistant : @content.Message = {
    role: @content.Assistant,
    content: Some(@content.Text("")),
    name: None,
    tool_call_id: None,
    reasoning_content: Some("reason"),
    tool_calls: [{ id: "call", name: "todo", arguments_json: "{}" }],
    refusal: None,
  }
  let tool : @content.Message = {
    role: @content.Tool,
    content: Some(@content.Text("{\"ok\":true}")),
    name: Some("todo"),
    tool_call_id: Some("call"),
    reasoning_content: None,
    tool_calls: [],
    refusal: None,
  }
  match project_messages([assistant, tool], fake_attachment) {
    Ok(values) => {
      assert_true(values[0].stringify().contains("tool_calls"))
      assert_true(values[1].stringify().contains("tool_call_id"))
    }
    Err(error) => fail(error.message)
  }
}

///|
test "canonical projector rejects resolver mismatch and unsupported file types" {
  let message : @content.Message = {
    role: @content.User,
    content: Some(@content.Parts([@content.FileRef("att_pdf", "a.pdf")])),
    name: None,
    tool_call_id: None,
    reasoning_content: None,
    tool_calls: [],
    refusal: None,
  }
  match
    project_messages([message], id => {
      Ok({ id, filename: "a.pdf", media_type: "application/pdf", data: b"pdf" })
    }) {
    Err(error) => assert_eq(error.code, @errors.InvalidArgument)
    Ok(_) => fail("expected unsupported attachment")
  }
}
