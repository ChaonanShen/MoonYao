///|
pub fn migrate_v4(
  connection : @sqlite3.Connection,
) -> Result[Unit, @errors.EngineError] {
  match migration_present(connection, 4) {
    Ok(true) => return Ok(())
    Ok(false) => ()
    Err(error) => return Err(error)
  }
  match exec(connection, "BEGIN IMMEDIATE", "conversation.migrate.v4") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let statements = [
    "CREATE TABLE _moonyao_turn_lifecycle (turn_id TEXT PRIMARY KEY REFERENCES _moonyao_turns(id) ON DELETE CASCADE, context_json TEXT NOT NULL, create_json TEXT NOT NULL DEFAULT 'null', next_json TEXT NOT NULL DEFAULT 'null')",
    "INSERT INTO _moonyao_migrations(version) VALUES (4)",
  ]
  for statement in statements {
    match exec(connection, statement, "conversation.migrate.v4") {
      Ok(_) => ()
      Err(error) => {
        rollback(connection)
        return Err(error)
      }
    }
  }
  match exec(connection, "COMMIT", "conversation.migrate.v4") {
    Ok(_) => Ok(())
    Err(error) => {
      rollback(connection)
      Err(error)
    }
  }
}
