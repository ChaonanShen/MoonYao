///|
fn gemini_data_url(value : String) -> (String, String)? {
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
fn gemini_parts(content : Json) -> Result[Array[Json], @errors.EngineError] {
  match content {
    String(value) => Ok([{ "text": value }])
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
              Some(String(text)) => output.push({ "text": text })
              _ =>
                return Err(@errors.llm_error("provider projection is invalid"))
            }
          Some(String("image_url")) => {
            guard object.get("image_url") is Some(Object(image)) &&
              image.get("url") is Some(String(url)) else {
              return Err(@errors.llm_error("provider projection is invalid"))
            }
            let (mime_type, data) = match gemini_data_url(url) {
              Some(value) => value
              None =>
                return Err(
                  @errors.llm_error("provider image projection is invalid"),
                )
            }
            output.push({
              "inlineData": { "mimeType": mime_type, "data": data },
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
pub fn gemini_request_json(
  request : ChatRequest,
) -> Result[Json, @errors.EngineError] {
  let systems = StringBuilder::new()
  let contents : Array[Json] = []
  for raw in request_wire_messages(request) {
    guard raw is Object(object) && object.get("role") is Some(String(role)) else {
      return Err(@errors.llm_error("provider projection is invalid"))
    }
    if role == "system" || role == "developer" {
      let content = match object.get("content") {
        Some(value) => value
        None => Json::null()
      }
      let parts = match gemini_parts(content) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      for part in parts {
        guard part is Object(data) && data.get("text") is Some(String(text)) else {
          return Err(@errors.llm_error("system image content is unsupported"))
        }
        if systems.to_string().length() > 0 {
          systems.write_string("\n\n")
        }
        systems.write_string(text)
      }
    } else if role == "tool" {
      let name = match object.get("name") {
        Some(String(value)) => value
        _ => return Err(@errors.llm_error("provider tool result is invalid"))
      }
      let response = match object.get("content") {
        Some(String(value)) => {
          let parsed = @json.parse(value) catch { _ => Json::null() }
          match parsed {
            Object(data) => Json::object(data)
            parsed => { "content": parsed }
          }
        }
        Some(value) => { "content": value }
        None => { "content": Json::null() }
      }
      contents.push({
        "role": "user",
        "parts": [
          { "functionResponse": { "name": name, "response": response } },
        ],
      })
    } else if role == "user" || role == "assistant" {
      let content = match object.get("content") {
        Some(value) => value
        None => Json::null()
      }
      let parts = match gemini_parts(content) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if role == "assistant" {
        match object.get("tool_calls") {
          Some(Array(calls)) =>
            for call in calls {
              guard call is Object(call_object) &&
                call_object.get("function") is Some(Object(function)) &&
                function.get("name") is Some(String(name)) &&
                function.get("arguments") is Some(String(arguments)) else {
                return Err(@errors.llm_error("provider tool call is invalid"))
              }
              let args = @json.parse(arguments) catch {
                _ =>
                  return Err(
                    @errors.llm_error("provider tool arguments are invalid"),
                  )
              }
              parts.push({ "functionCall": { "name": name, "args": args } })
            }
          None => ()
          _ => return Err(@errors.llm_error("provider tool calls are invalid"))
        }
      }
      contents.push({
        "role": if role == "assistant" {
          "model"
        } else {
          "user"
        },
        "parts": parts,
      })
    } else {
      return Err(@errors.llm_error("provider message role is unsupported"))
    }
  }
  let output : Map[String, Json] = {
    "contents": contents,
    "generationConfig": {
      "temperature": request.temperature,
      "maxOutputTokens": request.max_tokens,
    },
  }
  if systems.to_string().length() > 0 {
    output.set("systemInstruction", {
      "parts": [{ "text": systems.to_string() }],
    })
  }
  if !request.tools.is_empty() {
    output.set("tools", [
      {
        "functionDeclarations": request.tools.map(tool => {
          (
            {
              "name": tool.name,
              "description": tool.description,
              "parameters": tool.input_schema,
            } : Json)
        }),
      },
    ])
  }
  Ok(Json::object(output))
}

///|
fn gemini_usage(value : Json) -> Usage {
  guard value is Object(object) else {
    return { prompt_tokens: -1, completion_tokens: -1 }
  }
  let prompt = match object.get("promptTokenCount") {
    Some(Number(number, ..)) => number.to_int()
    _ => -1
  }
  let completion = match object.get("candidatesTokenCount") {
    Some(Number(number, ..)) => number.to_int()
    _ => -1
  }
  { prompt_tokens: prompt, completion_tokens: completion }
}

///|
pub fn parse_gemini_completion(
  source : String,
) -> Result[(Array[CompletionEvent], String, Usage), @errors.EngineError] {
  let value = @json.parse(source) catch {
    _ => return Err(@errors.llm_error("provider returned invalid JSON"))
  }
  guard value is Object(object) &&
    object.get("candidates") is Some(Array(candidates)) &&
    candidates.length() > 0 &&
    candidates[0] is Object(candidate) &&
    candidate.get("content") is Some(Object(content)) &&
    content.get("parts") is Some(Array(parts)) else {
    return Err(@errors.llm_error("provider returned invalid completion"))
  }
  let events : Array[CompletionEvent] = [Started]
  let text = StringBuilder::new()
  let mut call_index = 0
  for part in parts {
    guard part is Object(data) else {
      return Err(@errors.llm_error("provider returned invalid content"))
    }
    match data.get("text") {
      Some(String(value)) => {
        text.write_string(value)
        events.push(TextDelta(value))
      }
      _ =>
        match data.get("functionCall") {
          Some(Object(call)) => {
            guard call.get("name") is Some(String(name)) &&
              call.get("args") is Some(args) else {
              return Err(
                @errors.llm_error("provider returned invalid tool call"),
              )
            }
            let id = "gemini_call_" + call_index.to_string()
            let arguments = args.stringify()
            events.push(ToolCallStarted(call_index, id, name))
            events.push(ToolArgumentsDelta(call_index, arguments))
            events.push(
              ToolCallCompleted({ id, name, arguments_json: arguments }),
            )
            call_index = call_index + 1
          }
          _ =>
            return Err(
              @errors.llm_error("provider returned unsupported content"),
            )
        }
    }
  }
  let usage = match object.get("usageMetadata") {
    Some(value) => gemini_usage(value)
    None => { prompt_tokens: -1, completion_tokens: -1 }
  }
  events.push(Usage(usage))
  events.push(Completed)
  if text.to_string().length() == 0 && call_index == 0 {
    return Err(@errors.llm_error("provider returned empty completion"))
  }
  Ok((events, text.to_string(), usage))
}

///|
fn gemini_failure(kind : ProviderFailureKind) -> ProviderFailure {
  { kind, visible_output: false, retry_after_ms: None }
}

///|
async fn gemini_stream_attempt(
  connector : Connector,
  body : String,
  api_key : String,
  sink : (CompletionEvent) -> Unit,
) -> Result[(Array[CompletionEvent], String, Usage), ProviderFailure] {
  let client = @http.post_stream(
    connector.base_url +
    "/models/" +
    connector.model +
    ":streamGenerateContent?alt=sse",
    headers={
      "x-goog-api-key": api_key,
      "Content-Type": "application/json",
      "Accept": "text/event-stream",
    },
  )
  defer client.close()
  client.write(body)
  let response = client.end_request()
  if response.code < 200 || response.code >= 300 {
    return Err(gemini_failure(HttpStatus(response.code)))
  }
  let events : Array[CompletionEvent] = [Started]
  let text = StringBuilder::new()
  let mut usage : Usage = { prompt_tokens: -1, completion_tokens: -1 }
  let mut call_index = 0
  let mut pending : Array[Byte] = []
  let visible = Ref(false)
  while client.read_some(max_len=4096) is Some(chunk) {
    for byte in chunk {
      pending.push(byte)
    }
    while provider_event_boundary(pending) is Some((boundary, width)) {
      let bytes = Bytes::from_array(pending[:boundary].to_owned())
      pending = pending[boundary + width:].to_owned()
      let block = @utf8.decode(bytes) catch {
        _ =>
          return Err({
            kind: Protocol,
            visible_output: visible.val,
            retry_after_ms: None,
          })
      }
      let source = match provider_sse_data(block) {
        Some(value) => value
        None => continue
      }
      let value = @json.parse(source) catch {
        _ =>
          return Err({
            kind: Protocol,
            visible_output: visible.val,
            retry_after_ms: None,
          })
      }
      guard value is Object(object) else {
        return Err({
          kind: Protocol,
          visible_output: visible.val,
          retry_after_ms: None,
        })
      }
      match object.get("candidates") {
        Some(Array(candidates)) if !candidates.is_empty() => {
          guard candidates[0] is Object(candidate) &&
            candidate.get("content") is Some(Object(content)) &&
            content.get("parts") is Some(Array(parts)) else {
            return Err({
              kind: Protocol,
              visible_output: visible.val,
              retry_after_ms: None,
            })
          }
          for part in parts {
            guard part is Object(data) else {
              return Err({
                kind: Protocol,
                visible_output: visible.val,
                retry_after_ms: None,
              })
            }
            match data.get("text") {
              Some(String(value)) => {
                text.write_string(value)
                let event = TextDelta(value)
                events.push(event)
                sink(event)
                visible.val = true
              }
              _ =>
                match data.get("functionCall") {
                  Some(Object(call)) => {
                    guard call.get("name") is Some(String(name)) &&
                      call.get("args") is Some(args) else {
                      return Err({
                        kind: Protocol,
                        visible_output: visible.val,
                        retry_after_ms: None,
                      })
                    }
                    let id = "gemini_call_" + call_index.to_string()
                    let arguments = args.stringify()
                    for
                      event in [
                        ToolCallStarted(call_index, id, name),
                        ToolArgumentsDelta(call_index, arguments),
                        ToolCallCompleted({
                          id,
                          name,
                          arguments_json: arguments,
                        }),
                      ] {
                      events.push(event)
                      sink(event)
                    }
                    call_index = call_index + 1
                    visible.val = true
                  }
                  _ =>
                    return Err({
                      kind: Protocol,
                      visible_output: visible.val,
                      retry_after_ms: None,
                    })
                }
            }
          }
        }
        _ => ()
      }
      match object.get("usageMetadata") {
        Some(value) => usage = gemini_usage(value)
        None => ()
      }
    }
  }
  if !pending.is_empty() || (text.to_string().length() == 0 && call_index == 0) {
    return Err({
      kind: TruncatedStream,
      visible_output: visible.val,
      retry_after_ms: None,
    })
  }
  let usage_event = Usage(usage)
  events.push(usage_event)
  sink(usage_event)
  events.push(Completed)
  Ok((events, text.to_string(), usage))
}

///|
async fn gemini_attempt(
  connector : Connector,
  request : ChatRequest,
  api_key : String,
  sink : (CompletionEvent) -> Unit,
  timeout_ms : Int,
) -> Result[(Array[CompletionEvent], String, Usage), ProviderFailure] {
  let body = match gemini_request_json(request) {
    Ok(value) => value.stringify()
    Err(_) => return Err(gemini_failure(Protocol))
  }
  if request.stream {
    return @async.with_timeout(timeout_ms, () => {
      gemini_stream_attempt(connector, body, api_key, sink)
    }) catch {
      @async.TimeoutError => Err(gemini_failure(Timeout))
      error if @async.is_being_cancelled() => raise error
      _ => Err(gemini_failure(Transport))
    }
  }
  @async.with_timeout(timeout_ms, () => {
    let (response, response_body) = @http.post(
      connector.base_url + "/models/" + connector.model + ":generateContent",
      body,
      headers={ "x-goog-api-key": api_key, "Content-Type": "application/json" },
    )
    if response.code < 200 || response.code >= 300 {
      return Err(gemini_failure(HttpStatus(response.code)))
    }
    let source = response_body.text() catch {
      _ => return Err(gemini_failure(Protocol))
    }
    let parsed = match parse_gemini_completion(source) {
      Ok(value) => value
      Err(_) => return Err(gemini_failure(Protocol))
    }
    let (events, content, usage) = parsed
    for event in events {
      if event != Started && event != Completed {
        sink(event)
      }
    }
    Ok((events, content, usage))
  }) catch {
    @async.TimeoutError => Err(gemini_failure(Timeout))
    error if @async.is_being_cancelled() => raise error
    _ => Err(gemini_failure(Transport))
  }
}

///|
pub async fn complete_gemini_until(
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
    match gemini_attempt(connector, request, api_key, sink, timeout) {
      Ok(value) => return Ok(value)
      Err(failure) => {
        if !provider_failure_retryable(failure) ||
          attempt == policy.max_attempts {
          return Err(provider_failure_error(failure, attempt))
        }
        let delay = provider_retry_delay(failure, attempt, policy)
        if @async.now() + delay.to_int64() >= deadline_at {
          return Err(provider_failure_error(gemini_failure(Timeout), attempt))
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
