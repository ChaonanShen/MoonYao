///|
pub fn migrate_v6(
  connection : @sqlite3.Connection,
) -> Result[Unit, @errors.EngineError] {
  match migration_present(connection, 6) {
    Ok(true) => return Ok(())
    Ok(false) => ()
    Err(error) => return Err(error)
  }
  match exec(connection, "BEGIN IMMEDIATE", "conversation.migrate.v6") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let statements = [
    "ALTER TABLE _moonyao_turns ADD COLUMN retry_of_turn_id TEXT NOT NULL DEFAULT ''",
    "ALTER TABLE _moonyao_turns ADD COLUMN attempt INTEGER NOT NULL DEFAULT 1 CHECK(attempt >= 1)",
    "ALTER TABLE _moonyao_turns ADD COLUMN idempotency_key TEXT NOT NULL DEFAULT ''",
    "ALTER TABLE _moonyao_turns ADD COLUMN request_hash TEXT NOT NULL DEFAULT ''",
    "CREATE UNIQUE INDEX _moonyao_turns_idempotency ON _moonyao_turns(chat_id, idempotency_key) WHERE idempotency_key != ''",
    "CREATE UNIQUE INDEX _moonyao_turns_retry ON _moonyao_turns(retry_of_turn_id, attempt) WHERE retry_of_turn_id != ''",
    "CREATE TABLE _moonyao_turn_events (turn_id TEXT NOT NULL REFERENCES _moonyao_turns(id) ON DELETE CASCADE, sequence INTEGER NOT NULL CHECK(sequence >= 1), event TEXT NOT NULL, data_json TEXT NOT NULL, created_at INTEGER NOT NULL, PRIMARY KEY(turn_id, sequence))",
    "CREATE UNIQUE INDEX _moonyao_turn_terminal_event ON _moonyao_turn_events(turn_id) WHERE event IN ('turn.completed','turn.failed','turn.cancelled','turn.timed_out','turn.interrupted')",
    "INSERT INTO _moonyao_migrations(version) VALUES (6)",
  ]
  for statement in statements {
    match exec(connection, statement, "conversation.migrate.v6") {
      Ok(_) => ()
      Err(error) => {
        rollback(connection)
        return Err(error)
      }
    }
  }
  match exec(connection, "COMMIT", "conversation.migrate.v6") {
    Ok(_) => Ok(())
    Err(error) => {
      rollback(connection)
      Err(error)
    }
  }
}
