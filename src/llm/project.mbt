///|
pub(all) struct ResolvedAttachment {
  id : String
  filename : String
  media_type : String
  data : Bytes
} derive(Eq, Debug)

///|
pub let max_projected_attachment_bytes : Int = 24 * 1024 * 1024

///|
fn canonical_role(role : @content.Role) -> String {
  match role {
    @content.Developer => "developer"
    @content.System => "system"
    @content.User => "user"
    @content.Assistant => "assistant"
    @content.Tool => "tool"
  }
}

///|
fn image_detail(detail : @content.ImageDetail) -> String {
  match detail {
    @content.Auto => "auto"
    @content.Low => "low"
    @content.High => "high"
  }
}

///|
fn supported_image(media_type : String) -> Bool {
  ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(media_type)
}

///|
fn supported_text(media_type : String) -> Bool {
  ["text/plain", "text/markdown", "text/csv", "application/json"].contains(
    media_type,
  )
}

///|
fn resolve_checked(
  id : String,
  resolve : (String) -> Result[ResolvedAttachment, @errors.EngineError],
  consumed : Ref[Int],
) -> Result[ResolvedAttachment, @errors.EngineError] {
  let attachment = match resolve(id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if attachment.id != id {
    return Err(
      @errors.invalid_argument(
        "attachment resolver returned a different id", "message.content",
      ),
    )
  }
  consumed.val = consumed.val + attachment.data.length()
  if consumed.val > max_projected_attachment_bytes {
    return Err(
      @errors.invalid_argument(
        "projected attachments exceed the turn budget", "message.content",
      ),
    )
  }
  Ok(attachment)
}

///|
fn project_part(
  part : @content.ContentPart,
  resolve : (String) -> Result[ResolvedAttachment, @errors.EngineError],
  consumed : Ref[Int],
) -> Result[Json, @errors.EngineError] {
  match part {
    @content.TextPart(text) => Ok({ "type": "text", "text": text })
    @content.ImageRef(id, detail) => {
      let attachment = match resolve_checked(id, resolve, consumed) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if !supported_image(attachment.media_type) {
        return Err(
          @errors.invalid_argument(
            "image attachment has an unsupported media type", "message.content",
          ),
        )
      }
      let url = "data:" +
        attachment.media_type +
        ";base64," +
        @base64.encode(attachment.data)
      Ok({
        "type": "image_url",
        "image_url": { "url": url, "detail": image_detail(detail) },
      })
    }
    @content.FileRef(id, requested_filename) => {
      let attachment = match resolve_checked(id, resolve, consumed) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if !supported_text(attachment.media_type) {
        return Err(
          @errors.invalid_argument(
            "file attachment is not supported text", "message.content",
          ),
        )
      }
      let text = @encoding.decoder(@encoding.UTF8).decode(attachment.data) catch {
        _ =>
          return Err(
            @errors.invalid_argument(
              "text attachment is not valid UTF-8", "message.content",
            ),
          )
      }
      if text.length() > 262144 {
        return Err(
          @errors.invalid_argument(
            "expanded text attachment is too large", "message.content",
          ),
        )
      }
      let filename = if requested_filename.length() > 0 {
        requested_filename
      } else {
        attachment.filename
      }
      Ok({
        "type": "text",
        "text": "<file name=\"" + filename + "\">\n" + text + "\n</file>",
      })
    }
  }
}

///|
fn canonical_tool_call(call : @content.ToolCall) -> Json {
  {
    "id": call.id,
    "type": "function",
    "function": { "name": call.name, "arguments": call.arguments_json },
  }
}

///|
fn project_content(
  content : @content.MessageContent?,
  resolve : (String) -> Result[ResolvedAttachment, @errors.EngineError],
  consumed : Ref[Int],
) -> Result[Json, @errors.EngineError] {
  match content {
    None => Ok(Json::null())
    Some(@content.Text(value)) => Ok(Json::string(value))
    Some(@content.Parts(parts)) => {
      let projected : Array[Json] = []
      for part in parts {
        match project_part(part, resolve, consumed) {
          Ok(value) => projected.push(value)
          Err(error) => return Err(error)
        }
      }
      Ok(Json::array(projected))
    }
  }
}

///|
/// Project canonical messages immediately before the provider request.
pub fn project_messages(
  messages : Array[@content.Message],
  resolve : (String) -> Result[ResolvedAttachment, @errors.EngineError],
) -> Result[Array[Json], @errors.EngineError] {
  let output : Array[Json] = []
  let consumed = Ref(0)
  for message in messages {
    let projected = match project_content(message.content, resolve, consumed) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let object : Map[String, Json] = {
      "role": Json::string(canonical_role(message.role)),
      "content": projected,
    }
    match message.name {
      Some(value) => object.set("name", Json::string(value))
      None => ()
    }
    match message.tool_call_id {
      Some(value) => object.set("tool_call_id", Json::string(value))
      None => ()
    }
    match message.reasoning_content {
      Some(value) => object.set("reasoning_content", Json::string(value))
      None => ()
    }
    if !message.tool_calls.is_empty() {
      object.set(
        "tool_calls",
        Json::array(message.tool_calls.map(canonical_tool_call)),
      )
    }
    match message.refusal {
      Some(value) => object.set("refusal", Json::string(value))
      None => ()
    }
    output.push(Json::object(object))
  }
  Ok(output)
}

///|
/// Build an OpenAI-compatible request from already validated canonical input.
pub fn canonical_request_json(
  model : String,
  messages : Array[@content.Message],
  temperature : Double,
  max_tokens : Int,
  stream : Bool,
  tools : Array[ToolDefinition],
  resolve : (String) -> Result[ResolvedAttachment, @errors.EngineError],
) -> Result[Json, @errors.EngineError] {
  let projected = match project_messages(messages, resolve) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let result : Map[String, Json] = {
    "model": Json::string(model),
    "messages": Json::array(projected),
    "temperature": Json::number(temperature),
    "max_tokens": Json::number(max_tokens.to_double()),
    "stream": Json::boolean(stream),
  }
  if stream {
    result.set("stream_options", { "include_usage": true })
  }
  if !tools.is_empty() {
    result.set(
      "tools",
      Json::array(
        tools.map(tool => {
          "type": "function",
          "function": {
            "name": tool.name,
            "description": tool.description,
            "parameters": tool.input_schema,
          },
        }),
      ),
    )
  }
  Ok(Json::object(result))
}
