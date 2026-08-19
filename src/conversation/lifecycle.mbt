///|
pub fn save_create_snapshot(
  connection : @sqlite3.Connection,
  turn_id : String,
  context : Json,
  decision : Json,
) -> Result[Unit, @errors.EngineError] {
  let context_source = context.stringify()
  let decision_source = decision.stringify()
  if context_source.length() > 32768 {
    return Err(
      @errors.invalid_argument("turn context is too large", "turn.context"),
    )
  }
  if decision_source.length() > 262144 {
    return Err(
      @errors.invalid_argument("Create snapshot is too large", "turn.create"),
    )
  }
  let statement = connection.prepare(
    "INSERT INTO _moonyao_turn_lifecycle(turn_id, context_json, create_json, next_json) VALUES (?, ?, ?, 'null') ON CONFLICT(turn_id) DO UPDATE SET context_json = excluded.context_json, create_json = excluded.create_json",
  ) catch {
    _ =>
      return Err(
        @errors.database_error(
          "could not prepare lifecycle snapshot", "turn.lifecycle",
        ),
      )
  }
  try {
    statement.bind(index=1, turn_id)
    statement.bind(index=2, context_source)
    statement.bind(index=3, decision_source)
    statement.step_once()
    statement.finalize()
    Ok(())
  } catch {
    _ => {
      statement.finalize() catch {
        _ => ()
      }
      Err(
        @errors.database_error(
          "could not save lifecycle snapshot", "turn.lifecycle",
        ),
      )
    }
  }
}

///|
pub fn create_snapshot(
  connection : @sqlite3.Connection,
  turn_id : String,
) -> Result[(Json, Json), @errors.EngineError] {
  let statement = connection.prepare(
    "SELECT context_json, create_json FROM _moonyao_turn_lifecycle WHERE turn_id = ?",
  ) catch {
    _ =>
      return Err(
        @errors.database_error(
          "could not prepare lifecycle read", "turn.lifecycle",
        ),
      )
  }
  try {
    statement.bind(index=1, turn_id)
    if !statement.step() {
      statement.finalize()
      return Err(
        @errors.invalid_argument(
          "turn lifecycle was not found", "turn.lifecycle",
        ),
      )
    }
    let context_source : String = statement.column(index=0)
    let create_source : String = statement.column(index=1)
    statement.finalize()
    let context = @json.parse(context_source) catch {
      _ =>
        return Err(
          @errors.database_error(
            "turn lifecycle context is invalid", "turn.lifecycle",
          ),
        )
    }
    let create = @json.parse(create_source) catch {
      _ =>
        return Err(
          @errors.database_error(
            "turn Create snapshot is invalid", "turn.lifecycle",
          ),
        )
    }
    Ok((context, create))
  } catch {
    _ => {
      statement.finalize() catch {
        _ => ()
      }
      Err(
        @errors.database_error(
          "could not read lifecycle snapshot", "turn.lifecycle",
        ),
      )
    }
  }
}
