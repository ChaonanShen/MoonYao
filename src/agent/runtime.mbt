///|
pub(all) struct History {
  messages : Array[@llm.ChatMessage]
  truncated : Bool
} derive(Debug)

///|
pub(all) struct Ids {
  chat_id : String
  turn_id : String
  user_message_id : String
  assistant_message_id : String
} derive(Eq, Debug)

///|
pub(all) struct TurnResult {
  chat_id : String
  turn_id : String
  content : String
  next : Json?
  events : Array[@llm.CompletionEvent]
  history_truncated : Bool
  usage : @llm.Usage
} derive(Debug)

///|
pub(all) struct FakeResponse {
  events : Array[@llm.CompletionEvent]
  content : String
  usage : @llm.Usage
  error : @errors.EngineError?
} derive(Debug)

///|
pub(all) enum Client {
  Fake(FakeResponse)
  FakeSequence(Array[FakeResponse])
  OpenAI(@llm.Connector, String)
  Provider(@llm.Connector, String)
} derive(Debug)

///|
fn role_of(value : String) -> @llm.Role {
  if value == "user" {
    @llm.User
  } else if value == "tool" {
    @llm.Tool
  } else {
    @llm.Assistant
  }
}

///|
fn history_message(message : @conversation.Message) -> @llm.ChatMessage {
  if message.kind == "tool_result" {
    let parsed = @json.parse(message.content) catch { _ => Json::null() }
    guard parsed is Object(object) else {
      return { role: @llm.Tool, content: message.content }
    }
    let content = match object.get("result") {
      Some(value) => value.stringify()
      None =>
        match object.get("error") {
          Some(value) => value.stringify()
          None => "{}"
        }
    }
    let wire : Json = {
      "tool_call_id": match object.get("tool_call_id") {
        Some(v) => v
        None => Json::string("")
      },
      "name": match object.get("name") {
        Some(v) => v
        None => Json::string("")
      },
      "content": content,
    }
    return { role: @llm.Tool, content: wire.stringify() }
  }
  { role: role_of(message.role), content: message.content }
}

///|
pub fn build_history(
  prompts : Array[@llm.ChatMessage],
  stored : Array[@conversation.Message],
  current : String,
) -> Result[History, @errors.EngineError] {
  let mut fixed_bytes = current.length()
  for prompt in prompts {
    fixed_bytes = fixed_bytes + prompt.content.length()
  }
  if current.length() == 0 {
    return Err(@errors.invalid_argument("message must not be empty", "message"))
  }
  if fixed_bytes > 262144 || prompts.length() + 1 > 100 {
    return Err(
      @errors.invalid_argument(
        "system prompts or current message exceed history limits", "message",
      ),
    )
  }
  let groups : Array[Array[@conversation.Message]] = []
  for message in stored {
    if groups.is_empty() || groups.last().unwrap()[0].turn_id != message.turn_id {
      groups.push([message])
    } else {
      groups.last().unwrap().push(message)
    }
  }
  let selected : Array[Array[@conversation.Message]] = []
  let mut total_bytes = fixed_bytes
  let mut total_messages = prompts.length() + 1
  let mut truncated = false
  for index = groups.length() - 1; index >= 0; index = index - 1 {
    let group = groups[index]
    let mut bytes = 0
    for message in group {
      bytes = bytes + message.content.length()
    }
    if total_messages + group.length() > 100 || total_bytes + bytes > 262144 {
      truncated = true
      break
    } else {
      selected.push(group)
      total_messages = total_messages + group.length()
      total_bytes = total_bytes + bytes
    }
  }
  let messages = prompts.copy()
  for index = selected.length() - 1; index >= 0; index = index - 1 {
    for message in selected[index] {
      messages.push(history_message(message))
    }
  }
  messages.push({ role: @llm.User, content: current })
  Ok({ messages, truncated })
}

///|
async fn complete(
  client : Client,
  request : @llm.ChatRequest,
  sink : (@llm.CompletionEvent) -> Unit,
  round : Int,
  deadline_at : Int64,
) -> Result[
  (Array[@llm.CompletionEvent], String, @llm.Usage),
  @errors.EngineError,
] {
  match client {
    Fake(response) =>
      match response.error {
        Some(error) => Err(error)
        None => {
          for event in response.events {
            if event != @llm.Completed {
              sink(event)
            }
          }
          Ok((response.events, response.content, response.usage))
        }
      }
    FakeSequence(responses) => {
      if round >= responses.length() {
        return Err(@errors.llm_error("fake response sequence is exhausted"))
      }
      let response = responses[round]
      match response.error {
        Some(error) => Err(error)
        None => {
          for event in response.events {
            if event != @llm.Completed {
              sink(event)
            }
          }
          Ok((response.events, response.content, response.usage))
        }
      }
    }
    OpenAI(connector, api_key) =>
      @llm.complete_http_until(connector, request, api_key, sink, deadline_at)
    Provider(connector, api_key) =>
      @llm.complete_provider_until(
        connector, request, api_key, sink, deadline_at,
      )
  }
}

///|
fn title_for(content : String) -> String {
  let output = StringBuilder::new()
  let mut count = 0
  for character in content {
    if count >= 80 {
      break
    }
    output.write_char(character)
    count = count + 1
  }
  output.to_string()
}

///|
fn fail_active_turn(
  runtime : TurnRuntimeContext,
  assistant_message_id : String,
  error : @errors.EngineError,
  now : Int64,
) -> @errors.EngineError {
  let outcome = match error.code {
    @errors.TurnCancelled => TurnOutcome::Cancelled
    @errors.TurnTimedOut => TurnOutcome::TimedOut
    @errors.TurnInterrupted => TurnOutcome::Interrupted
    _ => Failed(error)
  }
  match finalize_turn(runtime, assistant_message_id, outcome, now) {
    Err(terminal) => terminal
    Ok(_) => error
  }
}

///|
fn turn_control_error(
  execution : TurnExecutionOptions,
  snapshot : TurnContextSnapshot,
) -> @errors.EngineError? {
  if execution.cancellation.is_requested() {
    Some(@errors.turn_cancelled())
  } else if @env.now().reinterpret_as_int64() >= snapshot.deadline_at {
    Some(@errors.turn_timed_out())
  } else {
    None
  }
}

///|
fn is_turn_control_error(error : @errors.EngineError) -> Bool {
  [@errors.TurnCancelled, @errors.TurnTimedOut, @errors.TurnInterrupted].contains(
    error.code,
  )
}

///|
fn invoke_controlled(
  execution : TurnExecutionOptions,
  snapshot : TurnContextSnapshot,
  process : String,
  input : Json,
  invoke : (String, Json) -> Result[Json, @errors.EngineError],
  sink : (@llm.CompletionEvent) -> Unit,
) -> Result[Json, @errors.EngineError] {
  match turn_control_error(execution, snapshot) {
    Some(error) => return Err(error)
    None => ()
  }
  let result = invoke(process, input)
  if execution.cancellation.is_requested() {
    sink(@llm.CancellationPendingProcess(process))
    return Err(@errors.turn_cancelled())
  }
  if @env.now().reinterpret_as_int64() >= snapshot.deadline_at {
    return Err(@errors.turn_timed_out())
  }
  result
}

///|
fn tool_definitions(agent : Agent) -> Array[@llm.ToolDefinition] {
  agent.tools.map(tool => {
    (
      {
        name: tool.name,
        description: tool.description,
        input_schema: tool.input_schema,
      } : @llm.ToolDefinition)
  })
}

///|
fn completed_tool_calls(
  events : Array[@llm.CompletionEvent],
) -> Array[@llm.ToolCall] {
  let calls : Array[@llm.ToolCall] = []
  for event in events {
    match event {
      @llm.ToolCallCompleted(call) => calls.push(call)
      _ => ()
    }
  }
  calls
}

///|
fn assistant_tool_message(
  content : String,
  calls : Array[@llm.ToolCall],
) -> Json {
  let values : Array[Json] = calls.map(call => {
    "id": call.id,
    "type": "function",
    "function": { "name": call.name, "arguments": call.arguments_json },
  })
  { "role": "assistant", "content": content, "tool_calls": Json::array(values) }
}

///|
fn tool_result_message(call : @llm.ToolCall, ok : Bool, value : Json) -> Json {
  let result : Map[String, Json] = {
    "tool_call_id": call.id,
    "name": call.name,
    "ok": ok,
  }
  if ok {
    result.set("result", value)
  } else {
    result.set("error", value)
  }
  Json::object(result)
}

///|
fn tool_wire_message(call : @llm.ToolCall, value : Json) -> @llm.ChatMessage {
  {
    role: @llm.Tool,
    content: (
      {
        "tool_call_id": call.id,
        "name": call.name,
        "content": value.stringify(),
      } : Json).stringify(),
  }
}

///|
fn find_tool(agent : Agent, name : String) -> Tool? {
  for tool in agent.tools {
    if tool.name == name {
      return Some(tool)
    }
  }
  None
}

///|
fn known_hook_keys(
  object : Map[String, Json],
  allowed : Array[String],
  path : String,
) -> Result[Unit, @errors.EngineError] {
  for key in object.keys() {
    if !allowed.contains(key) {
      return Err(
        @errors.tool_error("hook returned an unknown field at " + path),
      )
    }
  }
  Ok(())
}

///|
fn hook_messages_json(messages : Array[@llm.ChatMessage]) -> Json {
  Json::array(
    messages.map(message => {
      "role": match message.role {
        @llm.System => "system"
        @llm.User => "user"
        @llm.Assistant => "assistant"
        @llm.Tool => "tool"
      },
      "content": message.content,
    }),
  )
}

///|
fn parse_hook_messages(
  value : Json,
  path : String,
) -> Result[Array[@llm.ChatMessage], @errors.EngineError] {
  guard value is Array(items) else {
    return Err(@errors.tool_error("hook messages must be an array"))
  }
  if items.length() > 100 {
    return Err(@errors.tool_error("hook returned too many messages"))
  }
  let messages : Array[@llm.ChatMessage] = []
  let mut bytes = 0
  for index = 0; index < items.length(); index = index + 1 {
    guard items[index] is Object(object) else {
      return Err(@errors.tool_error("hook message must be an object"))
    }
    match known_hook_keys(object, ["role", "content"], path) {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
    let role = match object.get("role") {
      Some(String("system")) => @llm.System
      Some(String("user")) => @llm.User
      Some(String("assistant")) => @llm.Assistant
      _ =>
        return Err(@errors.tool_error("hook returned an invalid message role"))
    }
    let content = match object.get("content") {
      Some(String(text)) if text.length() > 0 => text
      _ =>
        return Err(@errors.tool_error("hook returned invalid message content"))
    }
    bytes = bytes + content.length()
    if bytes > 262144 {
      return Err(@errors.tool_error("hook messages are too large"))
    }
    messages.push({ role, content })
  }
  Ok(messages)
}

///|
priv enum AfterAction {
  Finish(String)
  Continue(Array[@llm.ChatMessage])
}

///|
fn parse_after(value : Json) -> Result[AfterAction, @errors.EngineError] {
  guard value is Object(object) else {
    return Err(@errors.tool_error("after hook must return an object"))
  }
  guard object.get("action") is Some(String(action)) else {
    return Err(@errors.tool_error("after hook omitted action"))
  }
  if action == "finish" {
    match known_hook_keys(object, ["action", "content"], "after") {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
    match object.get("content") {
      Some(String(content)) if content.length() > 0 &&
        content.length() <= 262144 => Ok(Finish(content))
      _ => Err(@errors.tool_error("after hook returned invalid content"))
    }
  } else if action == "continue" {
    match known_hook_keys(object, ["action", "messages"], "after") {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
    match object.get("messages") {
      Some(messages) =>
        match parse_hook_messages(messages, "after.messages") {
          Ok(v) if !v.is_empty() => Ok(Continue(v))
          Ok(_) => Err(@errors.tool_error("after hook returned no messages"))
          Err(e) => Err(e)
        }
      None => Err(@errors.tool_error("after hook omitted messages"))
    }
  } else {
    Err(@errors.tool_error("after hook returned an unknown action"))
  }
}

///|
pub async fn run_turn(
  connection : @sqlite3.Connection,
  agent : Agent,
  connector : @llm.Connector,
  client : Client,
  existing_chat_id : String?,
  input : String,
  ids : Ids,
  now : Int64,
  invoke : (String, Json) -> Result[Json, @errors.EngineError],
  sink : (@llm.CompletionEvent) -> Unit,
) -> Result[TurnResult, @errors.EngineError] {
  run_turn_controlled(
    connection,
    agent,
    connector,
    client,
    existing_chat_id,
    input,
    ids,
    now,
    default_turn_execution_options(),
    invoke,
    sink,
  )
}

///|
pub async fn run_turn_controlled(
  connection : @sqlite3.Connection,
  agent : Agent,
  connector : @llm.Connector,
  client : Client,
  existing_chat_id : String?,
  input : String,
  ids : Ids,
  now : Int64,
  execution : TurnExecutionOptions,
  invoke : (String, Json) -> Result[Json, @errors.EngineError],
  sink : (@llm.CompletionEvent) -> Unit,
) -> Result[TurnResult, @errors.EngineError] {
  run_turn_inner(
    connection,
    agent,
    connector,
    client,
    existing_chat_id,
    input,
    None,
    messages => {
      @llm.project_messages(messages, _ => {
        Err(
          @errors.invalid_argument(
            "Create introduced an attachment without a resolver", "create.messages",
          ),
        )
      })
    },
    ids,
    now,
    execution,
    invoke,
    sink,
  )
}

///|
/// Run one canonical user message with an ephemeral provider projection.
pub async fn run_turn_message(
  connection : @sqlite3.Connection,
  agent : Agent,
  connector : @llm.Connector,
  client : Client,
  existing_chat_id : String?,
  input : @content.Message,
  preview : String,
  project : (Array[@content.Message]) -> Result[
    Array[Json],
    @errors.EngineError,
  ],
  ids : Ids,
  now : Int64,
  invoke : (String, Json) -> Result[Json, @errors.EngineError],
  sink : (@llm.CompletionEvent) -> Unit,
) -> Result[TurnResult, @errors.EngineError] {
  run_turn_message_controlled(
    connection,
    agent,
    connector,
    client,
    existing_chat_id,
    input,
    preview,
    project,
    ids,
    now,
    default_turn_execution_options(),
    invoke,
    sink,
  )
}

///|
pub async fn run_turn_message_controlled(
  connection : @sqlite3.Connection,
  agent : Agent,
  connector : @llm.Connector,
  client : Client,
  existing_chat_id : String?,
  input : @content.Message,
  preview : String,
  project : (Array[@content.Message]) -> Result[
    Array[Json],
    @errors.EngineError,
  ],
  ids : Ids,
  now : Int64,
  execution : TurnExecutionOptions,
  invoke : (String, Json) -> Result[Json, @errors.EngineError],
  sink : (@llm.CompletionEvent) -> Unit,
) -> Result[TurnResult, @errors.EngineError] {
  if agent.before_process.length() > 0 {
    return Err(
      @errors.invalid_argument(
        "multimodal turns require the canonical Create hook lifecycle", "message",
      ),
    )
  }
  run_turn_inner(
    connection,
    agent,
    connector,
    client,
    existing_chat_id,
    preview,
    Some(input),
    project,
    ids,
    now,
    execution,
    invoke,
    sink,
  )
}

///|
async fn run_turn_inner(
  connection : @sqlite3.Connection,
  agent : Agent,
  connector : @llm.Connector,
  client : Client,
  existing_chat_id : String?,
  input : String,
  canonical_current : @content.Message?,
  project : (Array[@content.Message]) -> Result[
    Array[Json],
    @errors.EngineError,
  ],
  ids : Ids,
  now : Int64,
  execution : TurnExecutionOptions,
  invoke : (String, Json) -> Result[Json, @errors.EngineError],
  sink : (@llm.CompletionEvent) -> Unit,
) -> Result[TurnResult, @errors.EngineError] {
  let started_at = @env.now().reinterpret_as_int64()
  match build_history(agent.prompts, [], input) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let chat_id = match existing_chat_id {
    Some(id) => {
      let chat = match @conversation.get_chat(connection, id) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if chat.agent_id != agent.id {
        return Err(
          @errors.invalid_argument("chat belongs to a different agent", "chat"),
        )
      }
      id
    }
    None => {
      match
        @conversation.create_chat(
          connection,
          ids.chat_id,
          agent.id,
          title_for(input),
          now,
        ) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
      ids.chat_id
    }
  }
  let deadline_at = if execution.deadline_at > started_at &&
    execution.deadline_at - started_at <= 300000 {
    execution.deadline_at
  } else {
    started_at + 300000
  }
  let mut snapshot = match
    context_snapshot(
      "ctx_" + ids.turn_id,
      "req_" + ids.turn_id,
      chat_id,
      ids.turn_id,
      agent.id,
      connector.id,
      execution.metadata,
      started_at,
      deadline_at,
      retry_of_turn_id=execution.retry_of_turn_id,
      attempt=execution.attempt,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut runtime : TurnRuntimeContext = { snapshot, connection, invoke, sink }
  let mut lifecycle = begin_lifecycle(snapshot)
  if !execution.prestarted {
    match
      @conversation.begin_turn(
        connection,
        ids.turn_id,
        ids.user_message_id,
        chat_id,
        input,
        now,
        deadline_at=snapshot.deadline_at,
        idempotency_key=execution.idempotency_key,
        request_hash=execution.request_hash,
        canonical_message=canonical_current,
        retry_source_turn_id=execution.retry_source_turn_id,
      ) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
  }
  let persisted_turn = match @conversation.get_turn(connection, ids.turn_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if persisted_turn.chat_id != chat_id || persisted_turn.status != "active" {
    return Err(@errors.turn_conflict())
  }
  snapshot = {
    ..snapshot,
    retry_of_turn_id: if persisted_turn.retry_of_turn_id.length() > 0 {
      Some(persisted_turn.retry_of_turn_id)
    } else {
      None
    },
    attempt: persisted_turn.attempt,
  }
  runtime = { ..runtime, snapshot, }
  lifecycle = lifecycle.advance(Begun).unwrap()
  let stored = match @conversation.completed_messages(connection, chat_id) {
    Ok(value) => value
    Err(error) =>
      return Err(
        fail_active_turn(runtime, ids.assistant_message_id, error, now),
      )
  }
  let history = match build_history(agent.prompts, stored, input) {
    Ok(value) => value
    Err(error) =>
      return Err(
        fail_active_turn(runtime, ids.assistant_message_id, error, now),
      )
  }
  lifecycle = lifecycle.advance(HistoryLoaded).unwrap()
  let messages = history.messages.copy()
  let canonical_messages = messages.map(canonical_from_chat)
  match canonical_current {
    Some(message) =>
      canonical_messages[canonical_messages.length() - 1] = message
    None => ()
  }
  let mut canonical_base_count = 0
  let mut canonical_wire : Array[Json]? = None
  let mut request_temperature = agent.options.temperature
  let mut request_max_tokens = agent.options.max_tokens
  let mut metadata : Json = snapshot.metadata
  let all_events : Array[@llm.CompletionEvent] = []
  lifecycle = lifecycle.advance(Creating).unwrap()
  if agent.create_process.length() > 0 {
    match turn_control_error(execution, snapshot) {
      Some(error) =>
        return Err(
          fail_active_turn(
            runtime,
            ids.assistant_message_id,
            error,
            @env.now().reinterpret_as_int64(),
          ),
        )
      None => ()
    }
    let started = @llm.HookStarted("create")
    sink(started)
    all_events.push(started)
    let output = match
      invoke_controlled(
        execution,
        snapshot,
        agent.create_process,
        create_input_json(
          snapshot,
          canonical_messages,
          connector.id,
          request_temperature,
          request_max_tokens,
        ),
        invoke,
        sink,
      ) {
      Ok(value) => value
      Err(error) =>
        return Err(
          fail_active_turn(
            runtime,
            ids.assistant_message_id,
            error,
            @env.now().reinterpret_as_int64(),
          ),
        )
    }
    let decision = match
      apply_create_decision(
        output,
        canonical_messages,
        connector.id,
        request_temperature,
        request_max_tokens,
        snapshot,
      ) {
      Ok(value) => value
      Err(error) =>
        return Err(
          fail_active_turn(runtime, ids.assistant_message_id, error, now),
        )
    }
    snapshot = decision.context
    runtime = { ..runtime, snapshot, }
    metadata = snapshot.metadata
    request_temperature = decision.temperature
    request_max_tokens = decision.max_tokens
    match
      @conversation.save_create_snapshot(
        connection,
        ids.turn_id,
        context_json(snapshot),
        decision.snapshot,
      ) {
      Err(error) =>
        return Err(
          fail_active_turn(runtime, ids.assistant_message_id, error, now),
        )
      Ok(_) => ()
    }
    let projected = match project(decision.messages) {
      Ok(value) => value
      Err(error) =>
        return Err(
          fail_active_turn(runtime, ids.assistant_message_id, error, now),
        )
    }
    messages.clear()
    for message in decision.messages {
      messages.push(chat_from_canonical(message))
    }
    canonical_base_count = messages.length()
    canonical_wire = Some(projected)
    let completed = @llm.HookCompleted("create")
    sink(completed)
    all_events.push(completed)
  } else {
    match canonical_current {
      Some(_) => {
        let projected = match project(canonical_messages) {
          Ok(value) => value
          Err(error) =>
            return Err(
              fail_active_turn(runtime, ids.assistant_message_id, error, now),
            )
        }
        canonical_base_count = messages.length()
        canonical_wire = Some(projected)
      }
      None => ()
    }
  }
  if agent.before_process.length() > 0 {
    match turn_control_error(execution, snapshot) {
      Some(error) =>
        return Err(
          fail_active_turn(
            runtime,
            ids.assistant_message_id,
            error,
            @env.now().reinterpret_as_int64(),
          ),
        )
      None => ()
    }
    let started = @llm.HookStarted("before")
    sink(started)
    all_events.push(started)
    let hook_input : Json = {
      "agent_id": agent.id,
      "chat_id": chat_id,
      "turn_id": ids.turn_id,
      "context": context_json(snapshot),
      "messages": hook_messages_json(messages),
      "input": { "content": input },
      "metadata": metadata,
    }
    let output = match
      invoke_controlled(
        execution,
        snapshot,
        agent.before_process,
        hook_input,
        invoke,
        sink,
      ) {
      Ok(value) => value
      Err(error) =>
        return Err(
          fail_active_turn(
            runtime,
            ids.assistant_message_id,
            error,
            @env.now().reinterpret_as_int64(),
          ),
        )
    }
    guard output is Object(object) else {
      let error = @errors.tool_error("before hook must return an object")
      return Err(
        fail_active_turn(runtime, ids.assistant_message_id, error, now),
      )
    }
    match known_hook_keys(object, ["messages", "metadata"], "before") {
      Err(error) =>
        return Err(
          fail_active_turn(runtime, ids.assistant_message_id, error, now),
        )
      Ok(_) => ()
    }
    let updated = match object.get("messages") {
      Some(value) =>
        match parse_hook_messages(value, "before.messages") {
          Ok(v) => v
          Err(e) =>
            return Err(
              fail_active_turn(runtime, ids.assistant_message_id, e, now),
            )
        }
      None => {
        let error = @errors.tool_error("before hook omitted messages")
        return Err(
          fail_active_turn(runtime, ids.assistant_message_id, error, now),
        )
      }
    }
    metadata = match object.get("metadata") {
      Some(Object(value)) => {
        let json = Json::object(value)
        if json.stringify().length() > 32768 {
          let error = @errors.tool_error("hook metadata is too large")
          return Err(
            fail_active_turn(runtime, ids.assistant_message_id, error, now),
          )
        }
        json
      }
      None => Json::object(Map([]))
      Some(_) => {
        let error = @errors.tool_error("hook metadata must be an object")
        return Err(
          fail_active_turn(runtime, ids.assistant_message_id, error, now),
        )
      }
    }
    messages.clear()
    for message in updated {
      messages.push(message)
    }
    let completed = @llm.HookCompleted("before")
    sink(completed)
    all_events.push(completed)
  }
  lifecycle = lifecycle.advance(Running).unwrap()
  let definitions = tool_definitions(agent)
  let mut round = 0
  let mut tool_count = 0
  let mut continuation_count = 0
  let mut prompt_tokens = 0
  let mut completion_tokens = 0
  let tool_results : Array[NextToolResult] = []
  while round < 8 {
    match turn_control_error(execution, snapshot) {
      Some(error) =>
        return Err(
          fail_active_turn(
            runtime,
            ids.assistant_message_id,
            error,
            @env.now().reinterpret_as_int64(),
          ),
        )
      None => ()
    }
    let request : @llm.ChatRequest = {
      model: connector.model,
      messages: messages.copy(),
      wire_messages: match canonical_wire {
        Some(base) => {
          let wire = base.copy()
          for index = canonical_base_count
              index < messages.length()
              index = index + 1 {
            wire.push(@llm.chat_messages_json([messages[index]])[0])
          }
          Some(wire)
        }
        None => None
      },
      temperature: request_temperature,
      max_tokens: request_max_tokens,
      stream: true,
      tools: definitions,
    }
    let completed = match
      complete(
        client,
        request,
        event => if event != @llm.Started || round == 0 { sink(event) },
        round,
        @async.now() +
        (snapshot.deadline_at - @env.now().reinterpret_as_int64()),
      ) {
      Ok(value) => value
      Err(error) =>
        return Err(
          fail_active_turn(runtime, ids.assistant_message_id, error, now),
        )
    }
    match turn_control_error(execution, snapshot) {
      Some(error) =>
        return Err(
          fail_active_turn(
            runtime,
            ids.assistant_message_id,
            error,
            @env.now().reinterpret_as_int64(),
          ),
        )
      None => ()
    }
    round = round + 1
    let (events, content, usage) = completed
    for event in events {
      all_events.push(event)
    }
    if usage.prompt_tokens >= 0 {
      prompt_tokens = prompt_tokens + usage.prompt_tokens
    }
    if usage.completion_tokens >= 0 {
      completion_tokens = completion_tokens + usage.completion_tokens
    }
    let calls = completed_tool_calls(events)
    if !calls.is_empty() {
      if tool_count + calls.length() > 32 {
        let error = @errors.turn_limit_exceeded("tool-call limit exceeded")
        return Err(
          fail_active_turn(runtime, ids.assistant_message_id, error, now),
        )
      }
      let assistant_json = assistant_tool_message(content, calls)
      match
        @conversation.append_message(
          connection,
          ids.turn_id + "-assistant-" + round.to_string(),
          chat_id,
          ids.turn_id,
          "assistant",
          "tool_calls",
          assistant_json,
          now,
        ) {
        Err(error) =>
          return Err(
            fail_active_turn(runtime, ids.assistant_message_id, error, now),
          )
        Ok(_) => ()
      }
      messages.push({
        role: @llm.Assistant,
        content: assistant_json.stringify(),
      })
      for index = 0; index < calls.length(); index = index + 1 {
        let call = calls[index]
        tool_count = tool_count + 1
        let tool = match find_tool(agent, call.name) {
          Some(value) => value
          None => {
            let error = @errors.tool_error(
              "model requested a tool outside the allowlist",
            )
            return Err(
              fail_active_turn(runtime, ids.assistant_message_id, error, now),
            )
          }
        }
        let started = @llm.ToolStarted(call.id, call.name)
        sink(started)
        all_events.push(started)
        let arguments : Result[Json, @errors.EngineError] = Ok(
          @json.parse(call.arguments_json),
        ) catch {
          _ =>
            Err(
              @errors.invalid_argument(
                "tool arguments are not valid JSON", "$args",
              ),
            )
        }
        let next_arguments = match arguments {
          Ok(value) => value
          Err(_) => Json::null()
        }
        let tool_execution = match arguments {
          Err(error) => Err(error)
          Ok(value) =>
            match validate_arguments(value, tool.input_schema) {
              Err(error) => Err(error)
              Ok(_) =>
                invoke_controlled(
                  execution,
                  snapshot,
                  tool.process,
                  value,
                  invoke,
                  sink,
                )
            }
        }
        match tool_execution {
          Err(error) if is_turn_control_error(error) =>
            return Err(
              fail_active_turn(
                runtime,
                ids.assistant_message_id,
                error,
                @env.now().reinterpret_as_int64(),
              ),
            )
          _ => ()
        }
        let (ok, payload, terminal) = match tool_execution {
          Ok(value) if value.stringify().length() <= 262144 =>
            (true, value, false)
          Ok(_) =>
            (
              false,
              (
                { "code": "tool_error", "message": "tool result is too large" } :
                Json),
              true,
            )
          Err(error) => {
            let safe : Json = {
              "code": error.code.as_string(),
              "message": error.message,
            }
            let fatal = [
              @errors.DatabaseError,
              @errors.InternalError,
              @errors.TurnLimitExceeded,
            ].contains(error.code)
            (false, safe, fatal)
          }
        }
        let result_json = tool_result_message(call, ok, payload)
        tool_results.push({
          tool_call_id: call.id,
          name: call.name,
          arguments: next_arguments,
          result: if ok {
            Some(payload)
          } else {
            None
          },
          error: if ok {
            None
          } else {
            Some(payload)
          },
        })
        match
          @conversation.append_message(
            connection,
            ids.turn_id + "-tool-" + round.to_string() + "-" + index.to_string(),
            chat_id,
            ids.turn_id,
            "tool",
            "tool_result",
            result_json,
            now,
          ) {
          Err(error) =>
            return Err(
              fail_active_turn(runtime, ids.assistant_message_id, error, now),
            )
          Ok(_) => ()
        }
        messages.push(tool_wire_message(call, payload))
        let summary = if payload.stringify().length() > 256 {
          payload.stringify()[:256].to_owned()
        } else {
          payload.stringify()
        }
        let tool_event = @llm.ToolCompleted(call.id, call.name, ok, summary)
        sink(tool_event)
        all_events.push(tool_event)
        if terminal {
          let error = @errors.tool_error(
            "tool execution could not continue safely",
          )
          return Err(
            fail_active_turn(runtime, ids.assistant_message_id, error, now),
          )
        }
      }
      continue
    }
    if content.length() == 0 {
      let error = @errors.llm_error("model returned empty text")
      return Err(
        fail_active_turn(runtime, ids.assistant_message_id, error, now),
      )
    }
    let mut final_content = content
    let total_usage : @llm.Usage = { prompt_tokens, completion_tokens }
    let mut next_data : Json? = None
    if agent.next_process.length() > 0 {
      lifecycle = lifecycle.advance(Next).unwrap()
      match turn_control_error(execution, snapshot) {
        Some(error) =>
          return Err(
            fail_active_turn(
              runtime,
              ids.assistant_message_id,
              error,
              @env.now().reinterpret_as_int64(),
            ),
          )
        None => ()
      }
      let started = @llm.HookStarted("next")
      sink(started)
      all_events.push(started)
      let output = match
        invoke_controlled(
          execution,
          snapshot,
          agent.next_process,
          next_input_json(
            snapshot, canonical_messages, content, total_usage, tool_results,
          ),
          invoke,
          sink,
        ) {
        Ok(value) => value
        Err(error) =>
          return Err(
            fail_active_turn(runtime, ids.assistant_message_id, error, now),
          )
      }
      let decision = match apply_next_decision(output, snapshot) {
        Ok(value) => value
        Err(error) =>
          return Err(
            fail_active_turn(runtime, ids.assistant_message_id, error, now),
          )
      }
      snapshot = decision.context
      runtime = { ..runtime, snapshot, }
      metadata = snapshot.metadata
      next_data = decision.data
      match
        @conversation.save_next_snapshot(
          connection,
          ids.turn_id,
          context_json(snapshot),
          decision.snapshot,
        ) {
        Err(error) =>
          return Err(
            fail_active_turn(runtime, ids.assistant_message_id, error, now),
          )
        Ok(_) => ()
      }
      let completed = @llm.HookCompleted("next")
      sink(completed)
      all_events.push(completed)
    } else if agent.after_process.length() > 0 {
      match turn_control_error(execution, snapshot) {
        Some(error) =>
          return Err(
            fail_active_turn(
              runtime,
              ids.assistant_message_id,
              error,
              @env.now().reinterpret_as_int64(),
            ),
          )
        None => ()
      }
      let started = @llm.HookStarted("after")
      sink(started)
      all_events.push(started)
      let hook_input : Json = {
        "agent_id": agent.id,
        "chat_id": chat_id,
        "turn_id": ids.turn_id,
        "context": context_json(snapshot),
        "completion": { "content": content },
        "metadata": metadata,
      }
      let output = match
        invoke_controlled(
          execution,
          snapshot,
          agent.after_process,
          hook_input,
          invoke,
          sink,
        ) {
        Ok(value) => value
        Err(error) =>
          return Err(
            fail_active_turn(runtime, ids.assistant_message_id, error, now),
          )
      }
      let action = match parse_after(output) {
        Ok(value) => value
        Err(error) =>
          return Err(
            fail_active_turn(runtime, ids.assistant_message_id, error, now),
          )
      }
      let completed = @llm.HookCompleted("after")
      sink(completed)
      all_events.push(completed)
      match action {
        Finish(value) => final_content = value
        Continue(extra) => {
          continuation_count = continuation_count + 1
          if continuation_count > 2 {
            let error = @errors.turn_limit_exceeded(
              "after-hook continuation limit exceeded",
            )
            return Err(
              fail_active_turn(runtime, ids.assistant_message_id, error, now),
            )
          }
          let internal : Json = { "messages": hook_messages_json(extra) }
          match
            @conversation.append_message(
              connection,
              ids.turn_id + "-internal-" + continuation_count.to_string(),
              chat_id,
              ids.turn_id,
              "assistant",
              "internal",
              internal,
              now,
            ) {
            Err(error) =>
              return Err(
                fail_active_turn(runtime, ids.assistant_message_id, error, now),
              )
            Ok(_) => ()
          }
          messages.push({ role: @llm.Assistant, content })
          for message in extra {
            messages.push(message)
          }
          continue
        }
      }
    }
    if agent.next_process.length() == 0 {
      lifecycle = lifecycle.advance(Next).unwrap()
    }
    lifecycle = lifecycle.advance(Finalizing).unwrap()
    match turn_control_error(execution, snapshot) {
      Some(error) =>
        return Err(
          fail_active_turn(
            runtime,
            ids.assistant_message_id,
            error,
            @env.now().reinterpret_as_int64(),
          ),
        )
      None => ()
    }
    match
      finalize_turn(
        runtime,
        ids.assistant_message_id,
        Completed(final_content, total_usage),
        @env.now().reinterpret_as_int64(),
      ) {
      Ok(_) => {
        lifecycle = lifecycle.advance(Terminal).unwrap()
        return Ok({
          chat_id,
          turn_id: ids.turn_id,
          content: final_content,
          next: next_data,
          events: all_events,
          history_truncated: history.truncated,
          usage: total_usage,
        })
      }
      Err(error) => return Err(error)
    }
  }
  let error = @errors.turn_limit_exceeded("LLM round limit exceeded")
  Err(fail_active_turn(runtime, ids.assistant_message_id, error, now))
}
