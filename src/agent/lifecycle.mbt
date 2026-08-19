///|
/// Serializable, hook-safe identity and request context for one agent turn.
pub(all) struct TurnContextSnapshot {
  context_id : String
  request_id : String
  chat_id : String
  turn_id : String
  agent_id : String
  connector_id : String
  locale : String
  theme : String
  route : String
  metadata : Json
  started_at : Int64
  deadline_at : Int64
  retry_of_turn_id : String?
  attempt : Int
} derive(Eq, Debug)

///|
/// Runtime-only services must never be encoded into a hook or persisted snapshot.
pub(all) struct TurnRuntimeContext {
  snapshot : TurnContextSnapshot
  connection : @sqlite3.Connection
  invoke : (String, Json) -> Result[Json, @errors.EngineError]
  sink : (@llm.CompletionEvent) -> Unit
}

///|
/// Explicit lifecycle stages shared by the legacy and canonical turn paths.
pub(all) enum TurnPhase {
  Validating
  Begun
  HistoryLoaded
  Creating
  Running
  Next
  Finalizing
  Terminal
} derive(Eq, Debug)

///|
pub(all) struct TurnLifecycle {
  context : TurnContextSnapshot
  phase : TurnPhase
} derive(Eq, Debug)

///|
pub(all) enum TurnOutcome {
  Completed(String, @llm.Usage)
  Failed(@errors.EngineError)
  Cancelled
  TimedOut
  Interrupted
} derive(Debug)

///|
pub fn context_snapshot(
  context_id : String,
  request_id : String,
  chat_id : String,
  turn_id : String,
  agent_id : String,
  connector_id : String,
  metadata : Json,
  started_at : Int64,
  deadline_at : Int64,
  retry_of_turn_id? : String = "",
  attempt? : Int = 1,
) -> Result[TurnContextSnapshot, @errors.EngineError] {
  if context_id.length() == 0 ||
    request_id.length() == 0 ||
    chat_id.length() == 0 ||
    turn_id.length() == 0 ||
    agent_id.length() == 0 ||
    connector_id.length() == 0 {
    return Err(
      @errors.invalid_argument("turn context identity is required", "context"),
    )
  }
  if context_id == chat_id || context_id == turn_id {
    return Err(
      @errors.invalid_argument(
        "context identity must be distinct from chat and turn", "context.id",
      ),
    )
  }
  guard metadata is Object(_) else {
    return Err(
      @errors.invalid_argument(
        "context metadata must be an object", "context.metadata",
      ),
    )
  }
  if metadata.stringify().length() > 32768 {
    return Err(
      @errors.invalid_argument(
        "context metadata is too large", "context.metadata",
      ),
    )
  }
  if started_at < 0 ||
    deadline_at <= started_at ||
    deadline_at - started_at > 300000 {
    return Err(
      @errors.invalid_argument(
        "turn deadline must be within 300000 milliseconds", "context.deadline_at",
      ),
    )
  }
  Ok({
    context_id,
    request_id,
    chat_id,
    turn_id,
    agent_id,
    connector_id,
    locale: "",
    theme: "",
    route: "",
    metadata,
    started_at,
    deadline_at,
    retry_of_turn_id: if retry_of_turn_id.length() > 0 {
      Some(retry_of_turn_id)
    } else {
      None
    },
    attempt,
  })
}

///|
pub fn context_json(context : TurnContextSnapshot) -> Json {
  {
    "context_id": context.context_id,
    "request_id": context.request_id,
    "chat_id": context.chat_id,
    "turn_id": context.turn_id,
    "agent_id": context.agent_id,
    "connector_id": context.connector_id,
    "locale": context.locale,
    "theme": context.theme,
    "route": context.route,
    "metadata": context.metadata,
    "started_at": Json::number(context.started_at.to_double()),
    "deadline_at": Json::number(context.deadline_at.to_double()),
    "retry_of_turn_id": match context.retry_of_turn_id {
      Some(value) => Json::string(value)
      None => Json::null()
    },
    "attempt": context.attempt,
  }
}

///|
pub fn begin_lifecycle(context : TurnContextSnapshot) -> TurnLifecycle {
  { context, phase: Validating }
}

///|
fn legal_transition(current : TurnPhase, next : TurnPhase) -> Bool {
  match (current, next) {
    (Validating, Begun)
    | (Begun, HistoryLoaded)
    | (HistoryLoaded, Creating)
    | (Creating, Running)
    | (Running, Next)
    | (Next, Finalizing)
    | (Finalizing, Terminal) => true
    (Validating, Finalizing)
    | (Begun, Finalizing)
    | (HistoryLoaded, Finalizing)
    | (Creating, Finalizing)
    | (Running, Finalizing) => true
    _ => false
  }
}

///|
pub fn TurnLifecycle::advance(
  self : TurnLifecycle,
  next : TurnPhase,
) -> Result[TurnLifecycle, @errors.EngineError] {
  if !legal_transition(self.phase, next) {
    return Err(
      @errors.internal_error(
        "illegal agent turn phase transition", "turn.phase",
      ),
    )
  }
  Ok({ ..self, phase: next })
}

///|
/// Persist one terminal outcome and emit exactly one terminal runtime event.
pub fn finalize_turn(
  runtime : TurnRuntimeContext,
  assistant_message_id : String,
  outcome : TurnOutcome,
  now : Int64,
) -> Result[Unit, @errors.EngineError] {
  match outcome {
    Completed(content, usage) =>
      match
        @conversation.complete_turn(
          runtime.connection,
          assistant_message_id,
          runtime.snapshot.chat_id,
          runtime.snapshot.turn_id,
          content,
          usage,
          now,
        ) {
        Ok(_) => {
          (runtime.sink)(@llm.Completed)
          Ok(())
        }
        Err(error) =>
          finalize_turn(runtime, assistant_message_id, Failed(error), now)
      }
    Failed(error) =>
      match
        @conversation.fail_turn(
          runtime.connection,
          runtime.snapshot.turn_id,
          error.code.as_string(),
          error.message,
          now,
        ) {
        Ok(_) => {
          (runtime.sink)(@llm.Failed(error.code.as_string()))
          Err(error)
        }
        Err(persist_error) => Err(persist_error)
      }
    Cancelled => {
      let error = @errors.turn_cancelled()
      match
        @conversation.cancel_turn(
          runtime.connection,
          runtime.snapshot.turn_id,
          now,
        ) {
        Ok(true) => {
          (runtime.sink)(@llm.Cancelled)
          Err(error)
        }
        Ok(false) => Err(@errors.turn_conflict())
        Err(persist_error) => Err(persist_error)
      }
    }
    TimedOut => {
      let error = @errors.turn_timed_out()
      match
        @conversation.timeout_turn(
          runtime.connection,
          runtime.snapshot.turn_id,
          now,
        ) {
        Ok(true) => {
          (runtime.sink)(@llm.TimedOut)
          Err(error)
        }
        Ok(false) => Err(@errors.turn_conflict())
        Err(persist_error) => Err(persist_error)
      }
    }
    Interrupted => {
      let error = @errors.turn_interrupted()
      match
        @conversation.interrupt_turn(
          runtime.connection,
          runtime.snapshot.turn_id,
          now,
        ) {
        Ok(true) => {
          (runtime.sink)(@llm.Interrupted)
          Err(error)
        }
        Ok(false) => Err(@errors.turn_conflict())
        Err(persist_error) => Err(persist_error)
      }
    }
  }
}
