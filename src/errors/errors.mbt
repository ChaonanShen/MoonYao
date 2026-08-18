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
pub fn EngineError::to_json(self : EngineError) -> Json {
  {
    "error": {
      "code": self.code.as_string(),
      "message": self.message,
      "path": self.path,
    },
  }
}
