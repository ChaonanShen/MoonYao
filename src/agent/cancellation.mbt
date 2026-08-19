///|
pub struct TurnCancellation {
  requested_at : Ref[Int64]
}

///|
pub fn TurnCancellation::new() -> TurnCancellation {
  { requested_at: Ref(0L) }
}

///|
pub fn TurnCancellation::request(self : TurnCancellation, now : Int64) -> Unit {
  if self.requested_at.val == 0L {
    self.requested_at.val = now
  }
}

///|
pub fn TurnCancellation::is_requested(self : TurnCancellation) -> Bool {
  self.requested_at.val > 0L
}

///|
pub fn TurnCancellation::requested_at(self : TurnCancellation) -> Int64 {
  self.requested_at.val
}

///|
pub(all) struct TurnExecutionOptions {
  cancellation : TurnCancellation
  deadline_at : Int64
  metadata : Json
}

///|
pub fn default_turn_execution_options() -> TurnExecutionOptions {
  {
    cancellation: TurnCancellation::new(),
    deadline_at: 0L,
    metadata: Json::object(Map([])),
  }
}

///|
pub struct ActiveTurn {
  cancellation : TurnCancellation
  cancel_task : () -> Unit
  deadline_at : Int64
}

///|
pub struct TurnSupervisor {
  active : Map[String, ActiveTurn]
}

///|
pub fn TurnSupervisor::new() -> TurnSupervisor {
  { active: Map([]) }
}

///|
pub fn TurnSupervisor::register(
  self : TurnSupervisor,
  turn_id : String,
  cancellation : TurnCancellation,
  deadline_at : Int64,
  cancel_task : () -> Unit,
) -> Result[Unit, @errors.EngineError] {
  if turn_id.length() == 0 || self.active.contains(turn_id) {
    return Err(
      @errors.internal_error("turn is already supervised", "turn.supervisor"),
    )
  }
  self.active.set(turn_id, { cancellation, cancel_task, deadline_at })
  Ok(())
}

///|
pub fn TurnSupervisor::request_cancel(
  self : TurnSupervisor,
  turn_id : String,
  now : Int64,
) -> Bool {
  match self.active.get(turn_id) {
    None => false
    Some(active) => {
      active.cancellation.request(now)
      (active.cancel_task)()
      true
    }
  }
}

///|
pub fn TurnSupervisor::remove(self : TurnSupervisor, turn_id : String) -> Unit {
  self.active.remove(turn_id)
}

///|
pub fn TurnSupervisor::contains(
  self : TurnSupervisor,
  turn_id : String,
) -> Bool {
  self.active.contains(turn_id)
}

///|
pub fn TurnSupervisor::deadline_at(
  self : TurnSupervisor,
  turn_id : String,
) -> Int64? {
  self.active.get(turn_id).map(active => active.deadline_at)
}

///|
fn finalize_supervised_control(
  connection : @sqlite3.Connection,
  turn_id : String,
  outcome : TurnOutcome,
  sink : (@llm.CompletionEvent) -> Unit,
  now : Int64,
) -> @errors.EngineError {
  match outcome {
    Cancelled => {
      let error = @errors.turn_cancelled()
      match @conversation.cancel_turn(connection, turn_id, now) {
        Ok(true) => sink(@llm.Cancelled)
        Ok(false) | Err(_) => ()
      }
      error
    }
    TimedOut => {
      let error = @errors.turn_timed_out()
      match @conversation.timeout_turn(connection, turn_id, now) {
        Ok(true) => sink(@llm.TimedOut)
        Ok(false) | Err(_) => ()
      }
      error
    }
    Interrupted => {
      let error = @errors.turn_interrupted()
      match @conversation.interrupt_turn(connection, turn_id, now) {
        Ok(true) => sink(@llm.Interrupted)
        Ok(false) | Err(_) => ()
      }
      error
    }
    Failed(error) => {
      match
        @conversation.fail_turn(
          connection,
          turn_id,
          error.code.as_string(),
          error.message,
          now,
        ) {
        Ok(_) => sink(@llm.Failed(error.code.as_string()))
        Err(_) => ()
      }
      error
    }
    Completed(_, _) =>
      @errors.internal_error("invalid supervised outcome", "turn.supervisor")
  }
}

///|
pub async fn supervise_turn(
  connection : @sqlite3.Connection,
  turn_id : String,
  cancellation : TurnCancellation,
  deadline_at : Int64,
  sink : (@llm.CompletionEvent) -> Unit,
  run : async () -> Result[TurnResult, @errors.EngineError],
) -> Result[TurnResult, @errors.EngineError] {
  let remaining = deadline_at - @env.now().reinterpret_as_int64()
  if remaining <= 0L {
    return Err(
      finalize_supervised_control(
        connection,
        turn_id,
        TimedOut,
        sink,
        @env.now().reinterpret_as_int64(),
      ),
    )
  }
  @async.with_timeout(remaining.to_int(), run) catch {
    @async.TimeoutError =>
      Err(
        finalize_supervised_control(
          connection,
          turn_id,
          TimedOut,
          sink,
          @env.now().reinterpret_as_int64(),
        ),
      )
    error if @async.is_cancellation_error(error) =>
      Err(
        finalize_supervised_control(
          connection,
          turn_id,
          if cancellation.is_requested() {
            Cancelled
          } else {
            Interrupted
          },
          sink,
          @env.now().reinterpret_as_int64(),
        ),
      )
    _ => {
      let error = @errors.internal_error(
        "supervised turn execution failed", "turn.supervisor",
      )
      Err(
        finalize_supervised_control(
          connection,
          turn_id,
          Failed(error),
          sink,
          @env.now().reinterpret_as_int64(),
        ),
      )
    }
  }
}
