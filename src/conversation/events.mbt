///|
pub(all) struct TurnEvent {
  turn_id : String
  sequence : Int
  event : String
  data : Json
  created_at : Int64
} derive(Eq, Debug)

///|
fn terminal_event_name(event : String) -> Bool {
  [
    "turn.completed", "turn.failed", "turn.cancelled", "turn.timed_out", "turn.interrupted",
  ].contains(event)
}

///|
fn internal_event_name(event : String) -> Bool {
  terminal_event_name(event) ||
  ["turn.started", "message.completed"].contains(event)
}

///|
fn public_event_name(event : String) -> Bool {
  [
    "hook.started", "hook.completed", "provider.retrying", "message.delta", "tool.started",
    "tool.completed", "turn.cancellation_pending_process", "usage",
  ].contains(event)
}

///|
fn turn_event_data(turn : Turn) -> Json {
  let data : Map[String, Json] = {
    "id": Json::string(turn.id),
    "chat_id": Json::string(turn.chat_id),
    "status": Json::string(turn.status),
    "retry_of_turn_id": Json::string(turn.retry_of_turn_id),
    "attempt": Json::number(turn.attempt.to_double()),
    "prompt_tokens": Json::number(turn.prompt_tokens.to_double()),
    "completion_tokens": Json::number(turn.completion_tokens.to_double()),
    "cancel_requested_at": Json::number(turn.cancel_requested_at.to_double()),
    "deadline_at": Json::number(turn.deadline_at.to_double()),
    "started_at": Json::number(turn.started_at.to_double()),
    "finished_at": Json::number(turn.finished_at.to_double()),
  }
  if turn.error_code.length() > 0 {
    data.set("error", { "code": turn.error_code, "message": turn.error_message })
  }
  Json::object(data)
}

///|
fn terminal_event_data(turn : Turn, next? : Json = Json::null()) -> Json {
  let data : Map[String, Json] = {
    "chat_id": Json::string(turn.chat_id),
    "turn": turn_event_data(turn),
    "usage": {
      "prompt_tokens": turn.prompt_tokens,
      "completion_tokens": turn.completion_tokens,
    },
    "next": next,
  }
  if turn.error_code.length() > 0 {
    data.set("error", { "code": turn.error_code, "message": turn.error_message })
  }
  Json::object(data)
}

///|
fn append_event_row(
  connection : @sqlite3.Connection,
  turn_id : String,
  event : String,
  data : Json,
  now : Int64,
) -> Result[TurnEvent, @errors.EngineError] {
  if !(internal_event_name(event) || public_event_name(event)) {
    return Err(@errors.invalid_argument("unsupported turn event", "event"))
  }
  guard data is Object(source) else {
    return Err(
      @errors.invalid_argument("event data must be an object", "event.data"),
    )
  }
  let sequence_statement = connection.prepare(
    "SELECT COALESCE(MAX(sequence), 0) + 1 FROM _moonyao_turn_events WHERE turn_id = ?",
  ) catch {
    _ =>
      return Err(
        @errors.database_error("could not allocate event sequence", "event"),
      )
  }
  let sequence = try {
    sequence_statement.bind(index=1, turn_id)
    ignore(sequence_statement.step())
    let value : Int = sequence_statement.column(index=0)
    sequence_statement.finalize()
    value
  } catch {
    _ => {
      sequence_statement.finalize() catch {
        _ => ()
      }
      return Err(
        @errors.database_error("could not allocate event sequence", "event"),
      )
    }
  }
  let payload : Map[String, Json] = Map([])
  for key in source.keys() {
    if key != "sequence" {
      payload.set(key, source.get(key).unwrap())
    }
  }
  payload.set("sequence", Json::number(sequence.to_double()))
  payload.set("turn_id", Json::string(turn_id))
  let encoded = Json::object(payload)
  let data_source = encoded.stringify()
  if data_source.length() > 262144 {
    return Err(
      @errors.invalid_argument("event data is too large", "event.data"),
    )
  }
  let statement = connection.prepare(
    "INSERT INTO _moonyao_turn_events(turn_id, sequence, event, data_json, created_at) VALUES (?, ?, ?, ?, ?)",
  ) catch {
    _ =>
      return Err(
        @errors.database_error("could not prepare turn event", "event"),
      )
  }
  try {
    statement.bind(index=1, turn_id)
    statement.bind(index=2, sequence)
    statement.bind(index=3, event)
    statement.bind(index=4, data_source)
    statement.bind(index=5, now)
    statement.step_once()
    statement.finalize()
    Ok({ turn_id, sequence, event, data: encoded, created_at: now })
  } catch {
    _ => {
      statement.finalize() catch {
        _ => ()
      }
      Err(@errors.database_error("could not save turn event", "event"))
    }
  }
}

///|
pub fn append_event(
  connection : @sqlite3.Connection,
  turn_id : String,
  event : String,
  data : Json,
  now : Int64,
) -> Result[TurnEvent, @errors.EngineError] {
  if !public_event_name(event) {
    return Err(
      @errors.invalid_argument(
        "event must be written by its lifecycle transaction", "event",
      ),
    )
  }
  match exec(connection, "BEGIN IMMEDIATE", "event.append") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let turn = match get_turn(connection, turn_id) {
    Ok(value) => value
    Err(error) => {
      rollback(connection)
      return Err(error)
    }
  }
  if turn.status != "active" {
    rollback(connection)
    return Err(@errors.turn_conflict())
  }
  let saved = match append_event_row(connection, turn_id, event, data, now) {
    Ok(value) => value
    Err(error) => {
      rollback(connection)
      return Err(error)
    }
  }
  match exec(connection, "COMMIT", "event.append") {
    Ok(_) => Ok(saved)
    Err(error) => {
      rollback(connection)
      Err(error)
    }
  }
}

///|
pub fn list_events(
  connection : @sqlite3.Connection,
  turn_id : String,
  after : Int,
  limit : Int,
) -> Result[Array[TurnEvent], @errors.EngineError] {
  if after < 0 || limit < 1 || limit > 1000 {
    return Err(@errors.invalid_argument("invalid event cursor", "events"))
  }
  match get_turn(connection, turn_id) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let statement = connection.prepare(
    "SELECT turn_id, sequence, event, data_json, created_at FROM _moonyao_turn_events WHERE turn_id = ? AND sequence > ? ORDER BY sequence LIMIT ?",
  ) catch {
    _ =>
      return Err(
        @errors.database_error("could not prepare event replay", "event"),
      )
  }
  let events : Array[TurnEvent] = []
  try {
    statement.bind(index=1, turn_id)
    statement.bind(index=2, after)
    statement.bind(index=3, limit)
    while statement.step() {
      let source : String = statement.column(index=3)
      let data = @json.parse(source) catch {
        _ => {
          statement.finalize()
          return Err(
            @errors.database_error("stored event data is invalid", "event"),
          )
        }
      }
      events.push({
        turn_id: statement.column(index=0),
        sequence: statement.column(index=1),
        event: statement.column(index=2),
        data,
        created_at: statement.column(index=4),
      })
    }
    statement.finalize()
    Ok(events)
  } catch {
    _ => {
      statement.finalize() catch {
        _ => ()
      }
      Err(@errors.database_error("could not replay turn events", "event"))
    }
  }
}
