///|
/// Stable error codes exposed by the MoonYao Core command and future HTTP API.
pub(all) enum ErrorCode {
  InvalidDsl
  InvalidArgument
  ModelNotFound
  ProcessNotFound
  FlowNotFound
  RouteNotFound
  MethodNotAllowed
  RecordNotFound
  DatabaseError
  ChatNotFound
  TurnConflict
  TurnCancelled
  TurnTimedOut
  TurnInterrupted
  LlmError
  ToolError
  TurnLimitExceeded
  AgentNotFound
  InternalError
} derive(Eq, Debug)

///|
/// A sanitized, machine-readable error. `path` identifies a DSL location and
/// never contains a database statement or driver error message.
pub(all) struct EngineError {
  code : ErrorCode
  message : String
  path : String
} derive(Eq, Debug)

///|
pub fn ErrorCode::as_string(self : ErrorCode) -> String {
  match self {
    InvalidDsl => "invalid_dsl"
    InvalidArgument => "invalid_argument"
    ModelNotFound => "model_not_found"
    ProcessNotFound => "process_not_found"
    FlowNotFound => "flow_not_found"
    RouteNotFound => "route_not_found"
    MethodNotAllowed => "method_not_allowed"
    RecordNotFound => "record_not_found"
    DatabaseError => "database_error"
    ChatNotFound => "chat_not_found"
    TurnConflict => "turn_conflict"
    TurnCancelled => "turn_cancelled"
    TurnTimedOut => "turn_timed_out"
    TurnInterrupted => "turn_interrupted"
    LlmError => "llm_error"
    ToolError => "tool_error"
    TurnLimitExceeded => "turn_limit_exceeded"
    AgentNotFound => "agent_not_found"
    InternalError => "internal_error"
  }
}

///|
pub fn invalid_dsl(message : String, path : String) -> EngineError {
  { code: InvalidDsl, message, path }
}

///|
pub fn invalid_argument(message : String, path : String) -> EngineError {
  { code: InvalidArgument, message, path }
}

///|
pub fn process_not_found(name : String) -> EngineError {
  {
    code: ProcessNotFound,
    message: "process '\{name}' was not found",
    path: "process",
  }
}

///|
pub fn flow_not_found(name : String) -> EngineError {
  { code: FlowNotFound, message: "flow '\{name}' was not found", path: "flow" }
}

///|
pub fn route_not_found(path : String) -> EngineError {
  { code: RouteNotFound, message: "route was not found", path }
}

///|
pub fn method_not_allowed(allow : String) -> EngineError {
  { code: MethodNotAllowed, message: "method not allowed", path: allow }
}

///|
pub fn record_not_found(path : String) -> EngineError {
  { code: RecordNotFound, message: "record was not found", path }
}

///|
pub fn database_error(message : String, path : String) -> EngineError {
  { code: DatabaseError, message, path }
}

///|
pub fn chat_not_found() -> EngineError {
  { code: ChatNotFound, message: "chat was not found", path: "chat" }
}

///|
pub fn turn_conflict() -> EngineError {
  {
    code: TurnConflict,
    message: "chat already has an active turn",
    path: "chat",
  }
}

///|
pub fn turn_retry_conflict(message : String) -> EngineError {
  { code: TurnConflict, message, path: "turn.retry" }
}

///|
pub fn idempotency_conflict() -> EngineError {
  {
    code: TurnConflict,
    message: "Idempotency-Key was already used for a different request",
    path: "headers.idempotency-key",
  }
}

///|
pub fn turn_cancelled() -> EngineError {
  { code: TurnCancelled, message: "turn was cancelled", path: "turn" }
}

///|
pub fn turn_timed_out() -> EngineError {
  { code: TurnTimedOut, message: "turn deadline was exceeded", path: "turn" }
}

///|
pub fn turn_interrupted() -> EngineError {
  { code: TurnInterrupted, message: "turn was interrupted", path: "turn" }
}

///|
pub fn llm_error(message : String) -> EngineError {
  { code: LlmError, message, path: "llm" }
}

///|
pub fn tool_error(message : String) -> EngineError {
  { code: ToolError, message, path: "tool" }
}

///|
pub fn turn_limit_exceeded(message : String) -> EngineError {
  { code: TurnLimitExceeded, message, path: "turn" }
}

///|
pub fn agent_not_found() -> EngineError {
  { code: AgentNotFound, message: "agent was not found", path: "agent" }
}

///|
pub fn internal_error(message : String, path : String) -> EngineError {
  { code: InternalError, message, path }
}

///|
pub fn EngineError::to_json(self : EngineError) -> Json {
  {
    "error": {
      "code": self.code.as_string(),
      "message": self.message,
      "path": self.path,
    },
  }
}
