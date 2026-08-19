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
/// Encode legacy runtime messages for a request-level canonical override.
pub fn chat_messages_json(messages : Array[ChatMessage]) -> Array[Json] {
  messages.map(wire_message)
}

///|
pub fn request_json(request : ChatRequest) -> Json {
  let messages : Array[Json] = match request.wire_messages {
    Some(values) => values
    None => request.messages.map(wire_message)
  }
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
              Some(String(text)) =>
                if text.length() > 0 {
                  events.push(TextDelta(text))
                }
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
fn provider_failure(
  kind : ProviderFailureKind,
  visible_output : Bool,
  retry_after_ms? : Int? = None,
) -> ProviderFailure {
  { kind, visible_output, retry_after_ms }
}

///|
fn response_retry_after_ms(response : @http.Response) -> Int? {
  let value = match response.headers.get("retry-after") {
    Some(raw) => raw
    None =>
      match response.headers.get("Retry-After") {
        Some(raw) => raw
        None => return None
      }
  }
  let seconds = @string.parse_int(value.trim()) catch { _ => return None }
  if seconds < 0 {
    return None
  }
  let bounded = if seconds > 60 { 60 } else { seconds }
  Some(bounded * 1000)
}

///|
async fn complete_stream_attempt(
  connector : Connector,
  body : String,
  headers : Map[String, String],
  sink : (CompletionEvent) -> Unit,
  visible : Ref[Bool],
) -> Result[(Array[CompletionEvent], String, Usage), ProviderFailure] {
  let client = @http.post_stream(
    connector.base_url + "/chat/completions",
    headers~,
  )
  defer client.close()
  client.write(body)
  let response = client.end_request()
  if response.code < 200 || response.code >= 300 {
    return Err(
      provider_failure(
        HttpStatus(response.code),
        false,
        retry_after_ms=response_retry_after_ms(response),
      ),
    )
  }
  let events : Array[CompletionEvent] = [Started]
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
        _ => return Err(provider_failure(Protocol, visible.val))
      }
      if done && block.trim().length() > 0 {
        return Err(provider_failure(Protocol, visible.val))
      }
      let (parsed, block_done) = match parse_sse_block(block) {
        Ok(value) => value
        Err(_) => return Err(provider_failure(Protocol, visible.val))
      }
      if block_done {
        done = true
        continue
      }
      for event in parsed {
        match event {
          TextDelta(text) => {
            visible.val = true
            output.write_string(text)
          }
          ToolCallStarted(_, _, _) | ToolArgumentsDelta(_, _) =>
            visible.val = true
          Usage(value) => usage = value
          _ => ()
        }
        events.push(event)
        sink(event)
      }
    }
  }
  if !pending.is_empty() || !done {
    return Err(provider_failure(TruncatedStream, visible.val))
  }
  let calls = match assemble_tool_calls(events) {
    Ok(value) => value
    Err(_) => return Err(provider_failure(Protocol, visible.val))
  }
  for call in calls {
    let event = ToolCallCompleted(call)
    events.push(event)
    sink(event)
  }
  if output.to_string().length() == 0 && calls.is_empty() {
    return Err(provider_failure(Protocol, visible.val))
  }
  events.push(Completed)
  Ok((events, output.to_string(), usage))
}

///|
async fn complete_non_stream_attempt(
  connector : Connector,
  body : String,
  headers : Map[String, String],
  sink : (CompletionEvent) -> Unit,
) -> Result[(Array[CompletionEvent], String, Usage), ProviderFailure] {
  let (response, response_body) = @http.post(
    connector.base_url + "/chat/completions",
    body,
    headers~,
  )
  if response.code < 200 || response.code >= 300 {
    return Err(
      provider_failure(
        HttpStatus(response.code),
        false,
        retry_after_ms=response_retry_after_ms(response),
      ),
    )
  }
  let source = response_body.text() catch {
    _ => return Err(provider_failure(Protocol, false))
  }
  match parse_completion(source) {
    Ok((events, content, usage)) => {
      for event in events {
        if event != Started && event != Completed {
          sink(event)
        }
      }
      Ok((events, content, usage))
    }
    Err(_) => Err(provider_failure(Protocol, false))
  }
}

///|
async fn guarded_stream_attempt(
  connector : Connector,
  body : String,
  headers : Map[String, String],
  sink : (CompletionEvent) -> Unit,
  timeout_ms : Int,
) -> Result[(Array[CompletionEvent], String, Usage), ProviderFailure] {
  let visible = Ref(false)
  @async.with_timeout(timeout_ms, () => {
    complete_stream_attempt(connector, body, headers, sink, visible)
  }) catch {
    @async.TimeoutError => Err(provider_failure(Timeout, visible.val))
    error if @async.is_being_cancelled() => raise error
    _ => Err(provider_failure(Transport, visible.val))
  }
}

///|
async fn guarded_non_stream_attempt(
  connector : Connector,
  body : String,
  headers : Map[String, String],
  sink : (CompletionEvent) -> Unit,
  timeout_ms : Int,
) -> Result[(Array[CompletionEvent], String, Usage), ProviderFailure] {
  @async.with_timeout(timeout_ms, () => {
    complete_non_stream_attempt(connector, body, headers, sink)
  }) catch {
    @async.TimeoutError => Err(provider_failure(Timeout, false))
    error if @async.is_being_cancelled() => raise error
    _ => Err(provider_failure(Transport, false))
  }
}

///|
pub async fn complete_http_with_retry(
  connector : Connector,
  request : ChatRequest,
  api_key : String,
  sink : (CompletionEvent) -> Unit,
  policy : RetryPolicy,
  now : () -> Int64,
  sleep : async (Int) -> Unit,
) -> Result[(Array[CompletionEvent], String, Usage), @errors.EngineError] {
  if api_key.length() == 0 {
    return Err(@errors.llm_error("connector API key is not configured"))
  }
  if policy.max_attempts < 1 ||
    policy.max_attempts > 8 ||
    policy.initial_backoff_ms < 0 ||
    policy.max_backoff_ms < policy.initial_backoff_ms ||
    policy.max_backoff_ms > 60000 {
    return Err(
      @errors.invalid_argument("invalid provider retry policy", "llm.retry"),
    )
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
  let prefix_events : Array[CompletionEvent] = [Started]
  sink(Started)
  for attempt = 1; attempt <= policy.max_attempts; attempt = attempt + 1 {
    let remaining = policy.deadline_at - now()
    if remaining <= 0L {
      return Err(
        provider_failure_error(provider_failure(Timeout, false), attempt - 1),
      )
    }
    let attempt_timeout = if remaining > connector.timeout_ms.to_int64() {
      connector.timeout_ms
    } else {
      remaining.to_int()
    }
    let result = if request.stream {
      guarded_stream_attempt(connector, body, headers, sink, attempt_timeout)
    } else {
      guarded_non_stream_attempt(
        connector, body, headers, sink, attempt_timeout,
      )
    }
    match result {
      Ok((attempt_events, content, usage)) => {
        for event in attempt_events {
          if event != Started {
            prefix_events.push(event)
          }
        }
        return Ok((prefix_events, content, usage))
      }
      Err(failure) => {
        if !provider_failure_retryable(failure) ||
          attempt >= policy.max_attempts {
          return Err(provider_failure_error(failure, attempt))
        }
        let delay = provider_retry_delay(failure, attempt, policy)
        let before_sleep = now()
        if before_sleep >= policy.deadline_at ||
          delay.to_int64() >= policy.deadline_at - before_sleep {
          return Err(
            provider_failure_error(provider_failure(Timeout, false), attempt),
          )
        }
        let retry_event = ProviderRetrying(
          attempt + 1,
          policy.max_attempts,
          delay,
          provider_failure_reason(failure),
        )
        prefix_events.push(retry_event)
        sink(retry_event)
        sleep(delay)
        if now() >= policy.deadline_at {
          return Err(
            provider_failure_error(provider_failure(Timeout, false), attempt),
          )
        }
      }
    }
  }
  Err(@errors.llm_error("provider request failed"))
}

///|
fn retry_now() -> Int64 {
  @async.now()
}

///|
async fn retry_sleep(duration : Int) -> Unit {
  @async.sleep(duration)
}

///|
pub async fn complete_http(
  connector : Connector,
  request : ChatRequest,
  api_key : String,
  sink : (CompletionEvent) -> Unit,
) -> Result[(Array[CompletionEvent], String, Usage), @errors.EngineError] {
  let deadline_at = @async.now() + connector.timeout_ms.to_int64()
  complete_http_with_retry(
    connector,
    request,
    api_key,
    sink,
    default_retry_policy(deadline_at),
    retry_now,
    retry_sleep,
  )
}

///|
pub async fn complete_http_until(
  connector : Connector,
  request : ChatRequest,
  api_key : String,
  sink : (CompletionEvent) -> Unit,
  deadline_at : Int64,
) -> Result[(Array[CompletionEvent], String, Usage), @errors.EngineError] {
  complete_http_with_retry(
    connector,
    request,
    api_key,
    sink,
    default_retry_policy(deadline_at),
    retry_now,
    retry_sleep,
  )
}
