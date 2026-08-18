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
  events : Array[@llm.CompletionEvent]
  history_truncated : Bool
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
  OpenAI(@llm.Connector, String)
} derive(Debug)

///|
fn role_of(value : String) -> @llm.Role {
  if value == "user" {
    @llm.User
  } else {
    @llm.Assistant
  }
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
      messages.push({ role: role_of(message.role), content: message.content })
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
    OpenAI(connector, api_key) =>
      @llm.complete_http(connector, request, api_key, sink)
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
pub async fn run_turn(
  connection : @sqlite3.Connection,
  agent : Agent,
  connector : @llm.Connector,
  client : Client,
  existing_chat_id : String?,
  input : String,
  ids : Ids,
  now : Int,
  sink : (@llm.CompletionEvent) -> Unit,
) -> Result[TurnResult, @errors.EngineError] {
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
  match
    @conversation.begin_turn(
      connection,
      ids.turn_id,
      ids.user_message_id,
      chat_id,
      input,
      now,
    ) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let stored = match @conversation.completed_messages(connection, chat_id) {
    Ok(value) => value
    Err(error) => {
      ignore(
        @conversation.fail_turn(
          connection,
          ids.turn_id,
          error.code.as_string(),
          error.message,
          now,
        ),
      )
      sink(@llm.Failed(error.code.as_string()))
      return Err(error)
    }
  }
  let history = match build_history(agent.prompts, stored, input) {
    Ok(value) => value
    Err(error) => {
      ignore(
        @conversation.fail_turn(
          connection,
          ids.turn_id,
          error.code.as_string(),
          error.message,
          now,
        ),
      )
      sink(@llm.Failed(error.code.as_string()))
      return Err(error)
    }
  }
  let request : @llm.ChatRequest = {
    model: connector.model,
    messages: history.messages,
    temperature: agent.options.temperature,
    max_tokens: agent.options.max_tokens,
    stream: true,
  }
  let completed = match complete(client, request, sink) {
    Ok(value) => value
    Err(error) => {
      ignore(
        @conversation.fail_turn(
          connection,
          ids.turn_id,
          error.code.as_string(),
          error.message,
          now,
        ),
      )
      sink(@llm.Failed(error.code.as_string()))
      return Err(error)
    }
  }
  let (events, content, usage) = completed
  match
    @conversation.complete_turn(
      connection,
      ids.assistant_message_id,
      chat_id,
      ids.turn_id,
      content,
      usage,
      now,
    ) {
    Ok(_) => {
      sink(@llm.Completed)
      Ok({
        chat_id,
        turn_id: ids.turn_id,
        content,
        events,
        history_truncated: history.truncated,
      })
    }
    Err(error) => {
      ignore(
        @conversation.fail_turn(
          connection,
          ids.turn_id,
          error.code.as_string(),
          error.message,
          now,
        ),
      )
      sink(@llm.Failed(error.code.as_string()))
      Err(error)
    }
  }
}
