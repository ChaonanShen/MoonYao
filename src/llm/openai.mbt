///|
fn role_string(role : Role) -> String {
  match role {
    System => "system"
    User => "user"
    Assistant => "assistant"
    Tool => "tool"
  }
}

///|
fn wire_message(message : ChatMessage) -> Json {
  if message.role == Assistant {
    let parsed = @json.parse(message.content) catch { _ => Json::null() }
    guard parsed is Object(object) else {
      return { "role": "assistant", "content": message.content }
    }
    match object.get("tool_calls") {
      Some(Array(_)) => return Json::object(object)
      _ => ()
    }
  }
  if message.role == Tool {
    let parsed = @json.parse(message.content) catch { _ => Json::null() }
    guard parsed is Object(object) else {
      return { "role": "tool", "content": message.content }
    }
    let result : Map[String, Json] = { "role": "tool" }
    for key in ["tool_call_id", "name", "content"] {
      match object.get(key) {
        Some(value) => result.set(key, value)
        None => ()
      }
    }
    return Json::object(result)
  }
  { "role": role_string(message.role), "content": message.content }
}

///|
pub fn request_json(request : ChatRequest) -> Json {
  let messages : Array[Json] = request.messages.map(wire_message)
  let result : Map[String, Json] = {
    "model": request.model,
    "messages": messages,
    "temperature": request.temperature,
    "max_tokens": request.max_tokens,
    "stream": request.stream,
  }
  if request.stream {
    result.set("stream_options", { "include_usage": true })
  }
  if !request.tools.is_empty() {
    let tools : Array[Json] = []
    for tool in request.tools {
      tools.push({
        "type": "function",
        "function": Json::object({
          "name": Json::string(tool.name),
          "description": Json::string(tool.description),
          "parameters": tool.input_schema,
        }),
      })
    }
    result.set("tools", Json::array(tools))
  }
  Json::object(result)
}

///|
fn integer(value : Json) -> Int? {
  match value {
    Number(number, ..) if number.to_int().to_double() == number =>
      Some(number.to_int())
    _ => None
  }
}

///|
fn complete_tool_call(value : Json) -> ToolCall? {
  guard value is Object(object) else { return None }
  guard object.get("id") is Some(String(id)) else { return None }
  guard object.get("function") is Some(Object(function)) else { return None }
  guard function.get("name") is Some(String(name)) else { return None }
  guard function.get("arguments") is Some(String(arguments)) else {
    return None
  }
  Some({ id, name, arguments_json: arguments })
}

///|
fn usage_from(value : Json) -> Usage? {
  guard value is Object(object) else { return None }
  let prompt = match object.get("prompt_tokens") {
    Some(Number(v, ..)) => v.to_int()
    _ => return None
  }
  let completion = match object.get("completion_tokens") {
    Some(Number(v, ..)) => v.to_int()
    _ => return None
  }
  Some({ prompt_tokens: prompt, completion_tokens: completion })
}

///|
pub fn parse_completion(
  source : String,
) -> Result[(Array[CompletionEvent], String, Usage), @errors.EngineError] {
  let value = @json.parse(source) catch {
    _ => return Err(@errors.llm_error("provider returned invalid JSON"))
  }
  guard value is Object(object) else {
    return Err(@errors.llm_error("provider returned invalid completion"))
  }
  let events : Array[CompletionEvent] = [Started]
  let content = match object.get("choices") {
    Some(Array(choices)) if !choices.is_empty() =>
      match choices[0] {
        Object(choice) =>
          match choice.get("message") {
            Some(Object(message)) => {
              let text = match message.get("content") {
                Some(String(value)) => value
                None | Some(Null) => ""
                _ =>
                  return Err(
                    @errors.llm_error("provider returned non-text content"),
                  )
              }
              match message.get("tool_calls") {
                Some(Array(calls)) =>
                  for call in calls {
                    match complete_tool_call(call) {
                      Some(value) => events.push(ToolCallCompleted(value))
                      None =>
                        return Err(
                          @errors.llm_error(
                            "provider returned invalid tool call",
                          ),
                        )
                    }
                  }
                None => ()
                _ =>
                  return Err(
                    @errors.llm_error("provider returned invalid tool calls"),
                  )
              }
              text
            }
            _ =>
              return Err(
                @errors.llm_error("provider returned invalid completion"),
              )
          }
        _ =>
          return Err(@errors.llm_error("provider returned invalid completion"))
      }
    _ => return Err(@errors.llm_error("provider returned no choices"))
  }
  let usage = match object.get("usage") {
    None | Some(Null) => { prompt_tokens: -1, completion_tokens: -1 }
    Some(value) =>
      match usage_from(value) {
        Some(parsed) => parsed
        None => return Err(@errors.llm_error("provider returned invalid usage"))
      }
  }
  if content.length() > 0 {
    events.push(TextDelta(content))
  }
  if content.length() == 0 &&
    !events.any(event => event is ToolCallCompleted(_)) {
    return Err(@errors.llm_error("provider returned empty completion"))
  }
  events.push(Usage(usage))
  events.push(Completed)
  Ok((events, content, usage))
}

///|
fn parse_stream_json(
  source : String,
) -> Result[Array[CompletionEvent], @errors.EngineError] {
  let value = @json.parse(source) catch {
    _ =>
      return Err(@errors.llm_error("provider returned malformed stream data"))
  }
  guard value is Object(object) else {
    return Err(@errors.llm_error("provider returned malformed stream data"))
  }
  let events : Array[CompletionEvent] = []
  match object.get("usage") {
    None | Some(Null) => ()
    Some(value) =>
      match usage_from(value) {
        Some(usage) => events.push(Usage(usage))
        None => return Err(@errors.llm_error("provider returned invalid usage"))
      }
  }
  match object.get("choices") {
    Some(Array(choices)) =>
      for choice in choices {
        guard choice is Object(choice_object) else {
          return Err(
            @errors.llm_error("provider returned malformed stream choice"),
          )
        }
        match choice_object.get("delta") {
          Some(Object(delta)) =>
            match delta.get("content") {
              Some(String(text)) if text.length() > 0 =>
                events.push(TextDelta(text))
              None | Some(Null) => ()
              _ =>
                return Err(
                  @errors.llm_error("provider returned non-text delta"),
                )
            }
          _ =>
            return Err(
              @errors.llm_error("provider returned malformed stream delta"),
            )
        }
      }
    _ =>
      return Err(
        @errors.llm_error("provider returned malformed stream choices"),
      )
  }
  match object.get("choices") {
    Some(Array(choices)) =>
      for choice in choices {
        guard choice is Object(choice_object) else { continue }
        guard choice_object.get("delta") is Some(Object(delta)) else {
          continue
        }
        match delta.get("tool_calls") {
          Some(Array(calls)) =>
            for call in calls {
              guard call is Object(call_object) else {
                return Err(
                  @errors.llm_error("provider returned malformed tool delta"),
                )
              }
              let index = match call_object.get("index") {
                Some(value) =>
                  match integer(value) {
                    Some(v) if v >= 0 && v < 32 => v
                    _ =>
                      return Err(
                        @errors.llm_error(
                          "provider returned invalid tool index",
                        ),
                      )
                  }
                None =>
                  return Err(@errors.llm_error("provider omitted tool index"))
              }
              match (call_object.get("id"), call_object.get("function")) {
                (Some(String(id)), Some(Object(function))) =>
                  match function.get("name") {
                    Some(String(name)) if id.length() > 0 && name.length() > 0 =>
                      events.push(ToolCallStarted(index, id, name))
                    _ =>
                      return Err(
                        @errors.llm_error(
                          "provider returned invalid tool start",
                        ),
                      )
                  }
                (None, Some(Object(_))) | (None, None) => ()
                _ =>
                  return Err(
                    @errors.llm_error("provider returned malformed tool delta"),
                  )
              }
              match call_object.get("function") {
                Some(Object(function)) =>
                  match function.get("arguments") {
                    Some(String(arguments)) if arguments.length() > 0 =>
                      events.push(ToolArgumentsDelta(index, arguments))
                    None => ()
                    _ =>
                      return Err(
                        @errors.llm_error(
                          "provider returned invalid tool arguments",
                        ),
                      )
                  }
                None => ()
                _ =>
                  return Err(
                    @errors.llm_error(
                      "provider returned malformed tool function",
                    ),
                  )
              }
            }
          None => ()
          _ =>
            return Err(
              @errors.llm_error("provider returned invalid tool calls"),
            )
        }
      }
    _ => ()
  }
  Ok(events)
}

///|
priv struct ToolBuffer {
  id : String
  name : String
  arguments : StringBuilder
  started : Bool
}

///|
fn assemble_tool_calls(
  events : Array[CompletionEvent],
) -> Result[Array[ToolCall], @errors.EngineError] {
  let buffers : Array[ToolBuffer] = []
  for event in events {
    match event {
      ToolCallStarted(index, id, name) => {
        if index > buffers.length() {
          return Err(@errors.llm_error("provider skipped a tool-call index"))
        }
        if index == buffers.length() {
          buffers.push({
            id,
            name,
            arguments: StringBuilder::new(),
            started: true,
          })
        } else if buffers[index].started {
          return Err(@errors.llm_error("provider repeated a tool-call start"))
        }
      }
      ToolArgumentsDelta(index, delta) => {
        if index >= buffers.length() || !buffers[index].started {
          return Err(
            @errors.llm_error("provider sent arguments before tool start"),
          )
        }
        buffers[index].arguments.write_string(delta)
        if buffers[index].arguments.to_string().length() > 131072 {
          return Err(@errors.llm_error("provider tool arguments are too large"))
        }
      }
      _ => ()
    }
  }
  let calls : Array[ToolCall] = []
  for buffer in buffers {
    let arguments = buffer.arguments.to_string()
    if arguments.length() == 0 {
      return Err(@errors.llm_error("provider omitted tool arguments"))
    }
    calls.push({ id: buffer.id, name: buffer.name, arguments_json: arguments })
  }
  Ok(calls)
}

///|
fn parse_sse_block(
  block : String,
) -> Result[(Array[CompletionEvent], Bool), @errors.EngineError] {
  let data = StringBuilder::new()
  for line in block.replace_all(old="\r\n", new="\n").split("\n") {
    if line.has_prefix("data:") {
      let part = line[5:].trim().to_owned()
      if data.to_string().length() > 0 {
        data.write_char('\n')
      }
      data.write_string(part)
    }
  }
  let payload = data.to_string()
  if payload == "" {
    return Ok(([], false))
  }
  if payload == "[DONE]" {
    return Ok(([], true))
  }
  match parse_stream_json(payload) {
    Ok(events) => Ok((events, false))
    Err(error) => Err(error)
  }
}

///|
pub fn parse_sse(
  source : String,
) -> Result[(Array[CompletionEvent], String, Usage), @errors.EngineError] {
  let normalized = source.replace_all(old="\r\n", new="\n")
  let blocks : Array[String] = []
  normalized.split("\n\n").each(block => blocks.push(block.to_owned()))
  let events : Array[CompletionEvent] = [Started]
  let output = StringBuilder::new()
  let mut usage : Usage = { prompt_tokens: -1, completion_tokens: -1 }
  let mut done = false
  for block in blocks {
    if block.trim().length() == 0 {
      continue
    }
    if done {
      return Err(
        @errors.llm_error("provider sent data after stream termination"),
      )
    }
    let (parsed, block_done) = match parse_sse_block(block) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if block_done {
      done = true
      continue
    }
    for event in parsed {
      match event {
        TextDelta(text) => {
          output.write_string(text)
          events.push(event)
        }
        Usage(value) => {
          usage = value
          events.push(event)
        }
        _ => events.push(event)
      }
    }
  }
  if !done {
    return Err(@errors.llm_error("provider stream ended before [DONE]"))
  }
  let calls = match assemble_tool_calls(events) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  for call in calls {
    events.push(ToolCallCompleted(call))
  }
  if output.to_string().length() == 0 && calls.is_empty() {
    return Err(@errors.llm_error("provider returned empty text"))
  }
  events.push(Completed)
  Ok((events, output.to_string(), usage))
}

///|
fn event_boundary(bytes : Array[Byte]) -> (Int, Int)? {
  for index = 0; index + 1 < bytes.length(); index = index + 1 {
    if bytes[index] == b'\n' && bytes[index + 1] == b'\n' {
      return Some((index, 2))
    }
    if index + 3 < bytes.length() &&
      bytes[index] == b'\r' &&
      bytes[index + 1] == b'\n' &&
      bytes[index + 2] == b'\r' &&
      bytes[index + 3] == b'\n' {
      return Some((index, 4))
    }
  }
  None
}

///|
async fn complete_stream(
  connector : Connector,
  body : String,
  headers : Map[String, String],
  sink : (CompletionEvent) -> Unit,
) -> Result[(Array[CompletionEvent], String, Usage), @errors.EngineError] {
  let client = @http.post_stream(
    connector.base_url + "/chat/completions",
    headers~,
  )
  defer client.close()
  client.write(body)
  let response = client.end_request()
  if response.code < 200 || response.code >= 300 {
    return Err(
      @errors.llm_error("provider returned HTTP " + response.code.to_string()),
    )
  }
  let events : Array[CompletionEvent] = [Started]
  sink(Started)
  let output = StringBuilder::new()
  let mut usage : Usage = { prompt_tokens: -1, completion_tokens: -1 }
  let mut pending : Array[Byte] = []
  let mut done = false
  while client.read_some(max_len=4096) is Some(chunk) {
    for byte in chunk {
      pending.push(byte)
    }
    while event_boundary(pending) is Some((boundary, width)) {
      let event_bytes = Bytes::from_array(pending[:boundary].to_owned())
      pending = pending[boundary + width:].to_owned()
      let block = @utf8.decode(event_bytes) catch {
        _ => return Err(@errors.llm_error("provider returned invalid UTF-8"))
      }
      if done && block.trim().length() > 0 {
        return Err(
          @errors.llm_error("provider sent data after stream termination"),
        )
      }
      let (parsed, block_done) = match parse_sse_block(block) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if block_done {
        done = true
        continue
      }
      for event in parsed {
        match event {
          TextDelta(text) => output.write_string(text)
          Usage(value) => usage = value
          _ => ()
        }
        events.push(event)
        sink(event)
      }
    }
  }
  if !pending.is_empty() || !done {
    return Err(@errors.llm_error("provider stream ended before [DONE]"))
  }
  let calls = match assemble_tool_calls(events) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  for call in calls {
    let event = ToolCallCompleted(call)
    events.push(event)
    sink(event)
  }
  if output.to_string().length() == 0 && calls.is_empty() {
    return Err(@errors.llm_error("provider returned empty text"))
  }
  events.push(Completed)
  Ok((events, output.to_string(), usage))
}

///|
pub async fn complete_http(
  connector : Connector,
  request : ChatRequest,
  api_key : String,
  sink : (CompletionEvent) -> Unit,
) -> Result[(Array[CompletionEvent], String, Usage), @errors.EngineError] {
  if api_key.length() == 0 {
    return Err(@errors.llm_error("connector API key is not configured"))
  }
  let headers = {
    "Authorization": "Bearer " + api_key,
    "Content-Type": "application/json",
    "Accept": if request.stream {
      "text/event-stream"
    } else {
      "application/json"
    },
  }
  let body = request_json(request).stringify()
  if request.stream {
    return @async.with_timeout(connector.timeout_ms, () => {
      complete_stream(connector, body, headers, sink)
    }) catch {
      _ => Err(@errors.llm_error("provider request failed"))
    }
  }
  let (response, response_body) = @async.with_timeout(connector.timeout_ms, () => {
    @http.post(connector.base_url + "/chat/completions", body, headers~)
  }) catch {
    _ => return Err(@errors.llm_error("provider request failed"))
  }
  if response.code < 200 || response.code >= 300 {
    return Err(
      @errors.llm_error("provider returned HTTP " + response.code.to_string()),
    )
  }
  let source = response_body.text() catch {
    _ => return Err(@errors.llm_error("provider returned invalid text"))
  }
  match parse_completion(source) {
    Ok((events, content, usage)) => {
      for event in events {
        if event != Completed {
          sink(event)
        }
      }
      Ok((events, content, usage))
    }
    Err(error) => Err(error)
  }
}
