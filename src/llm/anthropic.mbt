///|
fn anthropic_data_url(value : String) -> (String, String)? {
  if !value.has_prefix("data:") {
    return None
  }
  let marker = ";base64,"
  let mut found = -1
  for index = 5; index + marker.length() <= value.length(); index = index + 1 {
    if value[index:index + marker.length()].to_owned() == marker {
      found = index
      break
    }
  }
  if found < 6 || found + marker.length() >= value.length() {
    return None
  }
  Some((value[5:found].to_owned(), value[found + marker.length():].to_owned()))
}

///|
fn anthropic_content_blocks(
  content : Json,
) -> Result[Array[Json], @errors.EngineError] {
  match content {
    String(value) => Ok([{ "type": "text", "text": value }])
    Null => Ok([])
    Array(parts) => {
      let output : Array[Json] = []
      for part in parts {
        guard part is Object(object) else {
          return Err(@errors.llm_error("provider projection is invalid"))
        }
        match object.get("type") {
          Some(String("text")) =>
            match object.get("text") {
              Some(String(text)) =>
                output.push({ "type": "text", "text": text })
              _ =>
                return Err(@errors.llm_error("provider projection is invalid"))
            }
          Some(String("image_url")) => {
            guard object.get("image_url") is Some(Object(image)) &&
              image.get("url") is Some(String(url)) else {
              return Err(@errors.llm_error("provider projection is invalid"))
            }
            let (media_type, data) = match anthropic_data_url(url) {
              Some(value) => value
              None =>
                return Err(
                  @errors.llm_error("provider image projection is invalid"),
                )
            }
            output.push({
              "type": "image",
              "source": {
                "type": "base64",
                "media_type": media_type,
                "data": data,
              },
            })
          }
          _ =>
            return Err(
              @errors.llm_error("provider content part is unsupported"),
            )
        }
      }
      Ok(output)
    }
    _ => Err(@errors.llm_error("provider projection is invalid"))
  }
}

///|
fn anthropic_messages(
  request : ChatRequest,
) -> Result[(String, Array[Json]), @errors.EngineError] {
  let systems = StringBuilder::new()
  let messages : Array[Json] = []
  for raw in request_wire_messages(request) {
    guard raw is Object(object) && object.get("role") is Some(String(role)) else {
      return Err(@errors.llm_error("provider projection is invalid"))
    }
    let content = match object.get("content") {
      Some(value) => value
      None => Json::null()
    }
    if role == "system" || role == "developer" {
      let blocks = match anthropic_content_blocks(content) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      for block in blocks {
        guard block is Object(data) && data.get("text") is Some(String(text)) else {
          return Err(@errors.llm_error("system image content is unsupported"))
        }
        if systems.to_string().length() > 0 {
          systems.write_string("\n\n")
        }
        systems.write_string(text)
      }
    } else if role == "tool" {
      guard object.get("tool_call_id") is Some(String(id)) else {
        return Err(@errors.llm_error("provider tool result is invalid"))
      }
      let result = match object.get("content") {
        Some(String(value)) => value
        Some(value) => value.stringify()
        None => ""
      }
      messages.push({
        "role": "user",
        "content": [
          { "type": "tool_result", "tool_use_id": id, "content": result },
        ],
      })
    } else if role == "user" || role == "assistant" {
      let blocks = match anthropic_content_blocks(content) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if role == "assistant" {
        match object.get("tool_calls") {
          Some(Array(calls)) =>
            for call in calls {
              guard call is Object(call_object) &&
                call_object.get("id") is Some(String(id)) &&
                call_object.get("function") is Some(Object(function)) &&
                function.get("name") is Some(String(name)) &&
                function.get("arguments") is Some(String(arguments)) else {
                return Err(@errors.llm_error("provider tool call is invalid"))
              }
              let input = @json.parse(arguments) catch {
                _ =>
                  return Err(
                    @errors.llm_error("provider tool arguments are invalid"),
                  )
              }
              blocks.push({
                "type": "tool_use",
                "id": id,
                "name": name,
                "input": input,
              })
            }
          None => ()
          _ => return Err(@errors.llm_error("provider tool calls are invalid"))
        }
      }
      messages.push({ "role": role, "content": blocks })
    } else {
      return Err(@errors.llm_error("provider message role is unsupported"))
    }
  }
  Ok((systems.to_string(), messages))
}

///|
pub fn anthropic_request_json(
  request : ChatRequest,
) -> Result[Json, @errors.EngineError] {
  let (system, messages) = match anthropic_messages(request) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let output : Map[String, Json] = {
    "model": request.model,
    "messages": messages,
    "max_tokens": request.max_tokens,
    "temperature": request.temperature,
    "stream": request.stream,
  }
  if system.length() > 0 {
    output.set("system", Json::string(system))
  }
  if !request.tools.is_empty() {
    output.set(
      "tools",
      Json::array(
        request.tools.map(tool => {
          "name": tool.name,
          "description": tool.description,
          "input_schema": tool.input_schema,
        }),
      ),
    )
  }
  Ok(Json::object(output))
}

///|
fn anthropic_usage(value : Json) -> Usage? {
  guard value is Object(object) else { return None }
  let input = match object.get("input_tokens") {
    Some(Number(number, ..)) => number.to_int()
    _ => -1
  }
  let output = match object.get("output_tokens") {
    Some(Number(number, ..)) => number.to_int()
    _ => -1
  }
  Some({ prompt_tokens: input, completion_tokens: output })
}

///|
pub fn parse_anthropic_completion(
  source : String,
) -> Result[(Array[CompletionEvent], String, Usage), @errors.EngineError] {
  let value = @json.parse(source) catch {
    _ => return Err(@errors.llm_error("provider returned invalid JSON"))
  }
  guard value is Object(object) && object.get("content") is Some(Array(blocks)) else {
    return Err(@errors.llm_error("provider returned invalid completion"))
  }
  let events : Array[CompletionEvent] = [Started]
  let text = StringBuilder::new()
  for index = 0; index < blocks.length(); index = index + 1 {
    guard blocks[index] is Object(block) else {
      return Err(@errors.llm_error("provider returned invalid content"))
    }
    match block.get("type") {
      Some(String("text")) =>
        match block.get("text") {
          Some(String(value)) => {
            text.write_string(value)
            events.push(TextDelta(value))
          }
          _ => return Err(@errors.llm_error("provider returned invalid text"))
        }
      Some(String("tool_use")) => {
        guard block.get("id") is Some(String(id)) &&
          block.get("name") is Some(String(name)) &&
          block.get("input") is Some(input) else {
          return Err(@errors.llm_error("provider returned invalid tool call"))
        }
        let arguments = input.stringify()
        events.push(ToolCallStarted(index, id, name))
        events.push(ToolArgumentsDelta(index, arguments))
        events.push(ToolCallCompleted({ id, name, arguments_json: arguments }))
      }
      _ =>
        return Err(@errors.llm_error("provider returned unsupported content"))
    }
  }
  let usage = match object.get("usage") {
    Some(value) =>
      match anthropic_usage(value) {
        Some(v) => v
        None => { prompt_tokens: -1, completion_tokens: -1 }
      }
    None => { prompt_tokens: -1, completion_tokens: -1 }
  }
  events.push(Usage(usage))
  events.push(Completed)
  if text.to_string().length() == 0 &&
    !events.any(event => event is ToolCallCompleted(_)) {
    return Err(@errors.llm_error("provider returned empty completion"))
  }
  Ok((events, text.to_string(), usage))
}

///|
fn anthropic_failure(
  kind : ProviderFailureKind,
  visible : Bool,
) -> ProviderFailure {
  { kind, visible_output: visible, retry_after_ms: None }
}

///|
fn anthropic_integer(value : Json) -> Int? {
  match value {
    Number(number, ..) if number.to_int().to_double() == number =>
      Some(number.to_int())
    _ => None
  }
}

///|
async fn anthropic_stream_attempt(
  connector : Connector,
  body : String,
  api_key : String,
  sink : (CompletionEvent) -> Unit,
) -> Result[(Array[CompletionEvent], String, Usage), ProviderFailure] {
  let client = @http.post_stream(connector.base_url + "/messages", headers={
    "x-api-key": api_key,
    "anthropic-version": "2023-06-01",
    "Content-Type": "application/json",
    "Accept": "text/event-stream",
  })
  defer client.close()
  client.write(body)
  let response = client.end_request()
  if response.code < 200 || response.code >= 300 {
    return Err(anthropic_failure(HttpStatus(response.code), false))
  }
  let events : Array[CompletionEvent] = [Started]
  let text = StringBuilder::new()
  let mut usage : Usage = { prompt_tokens: -1, completion_tokens: -1 }
  let ids : Array[String] = []
  let names : Array[String] = []
  let arguments : Array[StringBuilder] = []
  let mut pending : Array[Byte] = []
  let mut done = false
  let visible = Ref(false)
  while client.read_some(max_len=4096) is Some(chunk) {
    for byte in chunk {
      pending.push(byte)
    }
    while provider_event_boundary(pending) is Some((boundary, width)) {
      let bytes = Bytes::from_array(pending[:boundary].to_owned())
      pending = pending[boundary + width:].to_owned()
      let block = @utf8.decode(bytes) catch {
        _ => return Err(anthropic_failure(Protocol, visible.val))
      }
      let source = match provider_sse_data(block) {
        Some(value) => value
        None => continue
      }
      let value = @json.parse(source) catch {
        _ => return Err(anthropic_failure(Protocol, visible.val))
      }
      guard value is Object(object) && object.get("type") is Some(String(kind)) else {
        return Err(anthropic_failure(Protocol, visible.val))
      }
      if kind == "message_start" {
        match object.get("message") {
          Some(Object(message)) =>
            match message.get("usage") {
              Some(value) =>
                match anthropic_usage(value) {
                  Some(current) => usage = current
                  None => ()
                }
              None => ()
            }
          _ => ()
        }
      } else if kind == "content_block_start" {
        guard object.get("index") is Some(index_value) &&
          anthropic_integer(index_value) is Some(index) &&
          object.get("content_block") is Some(Object(content)) else {
          return Err(anthropic_failure(Protocol, visible.val))
        }
        while ids.length() <= index {
          ids.push("")
          names.push("")
          arguments.push(StringBuilder::new())
        }
        match content.get("type") {
          Some(String("tool_use")) => {
            guard content.get("id") is Some(String(id)) &&
              content.get("name") is Some(String(name)) else {
              return Err(anthropic_failure(Protocol, visible.val))
            }
            ids[index] = id
            names[index] = name
            let event = ToolCallStarted(index, id, name)
            events.push(event)
            sink(event)
            visible.val = true
          }
          Some(String("text")) => ()
          _ => return Err(anthropic_failure(Protocol, visible.val))
        }
      } else if kind == "content_block_delta" {
        guard object.get("index") is Some(index_value) &&
          anthropic_integer(index_value) is Some(index) &&
          object.get("delta") is Some(Object(delta)) else {
          return Err(anthropic_failure(Protocol, visible.val))
        }
        match delta.get("type") {
          Some(String("text_delta")) =>
            match delta.get("text") {
              Some(String(value)) => {
                text.write_string(value)
                let event = TextDelta(value)
                events.push(event)
                sink(event)
                visible.val = true
              }
              _ => return Err(anthropic_failure(Protocol, visible.val))
            }
          Some(String("input_json_delta")) =>
            match delta.get("partial_json") {
              Some(String(value)) if index < arguments.length() => {
                arguments[index].write_string(value)
                let event = ToolArgumentsDelta(index, value)
                events.push(event)
                sink(event)
                visible.val = true
              }
              _ => return Err(anthropic_failure(Protocol, visible.val))
            }
          _ => return Err(anthropic_failure(Protocol, visible.val))
        }
      } else if kind == "content_block_stop" {
        guard object.get("index") is Some(index_value) &&
          anthropic_integer(index_value) is Some(index) else {
          return Err(anthropic_failure(Protocol, visible.val))
        }
        if index < ids.length() && ids[index].length() > 0 {
          let source = arguments[index].to_string()
          ignore(@json.parse(source)) catch {
            _ => return Err(anthropic_failure(Protocol, visible.val))
          }
          let event = ToolCallCompleted({
            id: ids[index],
            name: names[index],
            arguments_json: source,
          })
          events.push(event)
          sink(event)
        }
      } else if kind == "message_delta" {
        match object.get("usage") {
          Some(Object(data)) =>
            match data.get("output_tokens") {
              Some(Number(number, ..)) =>
                usage = {
                  prompt_tokens: usage.prompt_tokens,
                  completion_tokens: number.to_int(),
                }
              _ => ()
            }
          _ => ()
        }
      } else if kind == "message_stop" {
        done = true
      } else if kind == "ping" {
        ()
      } else if kind == "error" {
        return Err(anthropic_failure(Protocol, visible.val))
      }
    }
  }
  if !pending.is_empty() || !done {
    return Err(anthropic_failure(TruncatedStream, visible.val))
  }
  if text.to_string().length() == 0 &&
    !events.any(event => event is ToolCallCompleted(_)) {
    return Err(anthropic_failure(Protocol, visible.val))
  }
  let usage_event = Usage(usage)
  events.push(usage_event)
  sink(usage_event)
  events.push(Completed)
  Ok((events, text.to_string(), usage))
}

///|
async fn anthropic_attempt(
  connector : Connector,
  request : ChatRequest,
  api_key : String,
  sink : (CompletionEvent) -> Unit,
  timeout_ms : Int,
) -> Result[(Array[CompletionEvent], String, Usage), ProviderFailure] {
  let body = match anthropic_request_json(request) {
    Ok(value) => value.stringify()
    Err(_) => return Err(anthropic_failure(Protocol, false))
  }
  if request.stream {
    return @async.with_timeout(timeout_ms, () => {
      anthropic_stream_attempt(connector, body, api_key, sink)
    }) catch {
      @async.TimeoutError => Err(anthropic_failure(Timeout, false))
      error if @async.is_being_cancelled() => raise error
      _ => Err(anthropic_failure(Transport, false))
    }
  }
  @async.with_timeout(timeout_ms, () => {
    let (response, response_body) = @http.post(
      connector.base_url + "/messages",
      body,
      headers={
        "x-api-key": api_key,
        "anthropic-version": "2023-06-01",
        "Content-Type": "application/json",
      },
    )
    if response.code < 200 || response.code >= 300 {
      return Err(anthropic_failure(HttpStatus(response.code), false))
    }
    let source = response_body.text() catch {
      _ => return Err(anthropic_failure(Protocol, false))
    }
    let parsed = match parse_anthropic_completion(source) {
      Ok(value) => value
      Err(_) => return Err(anthropic_failure(Protocol, false))
    }
    let (events, content, usage) = parsed
    for event in events {
      if event != Started && event != Completed {
        sink(event)
      }
    }
    Ok((events, content, usage))
  }) catch {
    @async.TimeoutError => Err(anthropic_failure(Timeout, false))
    error if @async.is_being_cancelled() => raise error
    _ => Err(anthropic_failure(Transport, false))
  }
}

///|
pub async fn complete_anthropic_until(
  connector : Connector,
  request : ChatRequest,
  api_key : String,
  sink : (CompletionEvent) -> Unit,
  deadline_at : Int64,
) -> Result[(Array[CompletionEvent], String, Usage), @errors.EngineError] {
  if api_key.length() == 0 {
    return Err(@errors.llm_error("connector API key is not configured"))
  }
  let policy = default_retry_policy(deadline_at)
  sink(Started)
  for attempt = 1; attempt <= policy.max_attempts; attempt = attempt + 1 {
    let remaining = deadline_at - @async.now()
    if remaining <= 0L {
      return Err(@errors.llm_error("provider request timed out"))
    }
    let timeout = if remaining > connector.timeout_ms.to_int64() {
      connector.timeout_ms
    } else {
      remaining.to_int()
    }
    match anthropic_attempt(connector, request, api_key, sink, timeout) {
      Ok(value) => return Ok(value)
      Err(failure) => {
        if !provider_failure_retryable(failure) ||
          attempt == policy.max_attempts {
          return Err(provider_failure_error(failure, attempt))
        }
        let delay = provider_retry_delay(failure, attempt, policy)
        if @async.now() + delay.to_int64() >= deadline_at {
          return Err(
            provider_failure_error(
              { kind: Timeout, visible_output: false, retry_after_ms: None },
              attempt,
            ),
          )
        }
        sink(
          ProviderRetrying(
            attempt + 1,
            policy.max_attempts,
            delay,
            provider_failure_reason(failure),
          ),
        )
        @async.sleep(delay)
      }
    }
  }
  Err(@errors.llm_error("provider request failed"))
}
