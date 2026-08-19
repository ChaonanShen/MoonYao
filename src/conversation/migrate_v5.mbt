///|
fn restore_foreign_keys(connection : @sqlite3.Connection) -> Unit {
  ignore(
    exec(connection, "PRAGMA foreign_keys = ON", "conversation.migrate.v5"),
  )
}

///|
pub fn migrate_v5(
  connection : @sqlite3.Connection,
) -> Result[Unit, @errors.EngineError] {
  match migration_present(connection, 5) {
    Ok(true) => return Ok(())
    Ok(false) => ()
    Err(error) => return Err(error)
  }
  match
    exec(connection, "PRAGMA foreign_keys = OFF", "conversation.migrate.v5") {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match exec(connection, "BEGIN IMMEDIATE", "conversation.migrate.v5") {
    Err(error) => {
      restore_foreign_keys(connection)
      return Err(error)
    }
    Ok(_) => ()
  }
  let statements = [
    "CREATE TABLE _moonyao_turns_v5 (id TEXT PRIMARY KEY, chat_id TEXT NOT NULL REFERENCES _moonyao_chats(id) ON DELETE CASCADE, status TEXT NOT NULL CHECK(status IN ('active','completed','failed','cancelled','timed_out','interrupted')), error_code TEXT NOT NULL, error_message TEXT NOT NULL, prompt_tokens INTEGER NOT NULL, completion_tokens INTEGER NOT NULL, cancel_requested_at INTEGER NOT NULL DEFAULT 0, deadline_at INTEGER NOT NULL DEFAULT 0, started_at INTEGER NOT NULL, finished_at INTEGER NOT NULL)",
    "INSERT INTO _moonyao_turns_v5(id, chat_id, status, error_code, error_message, prompt_tokens, completion_tokens, cancel_requested_at, deadline_at, started_at, finished_at) SELECT id, chat_id, status, error_code, error_message, prompt_tokens, completion_tokens, 0, 0, started_at, finished_at FROM _moonyao_turns",
    "DROP TABLE _moonyao_turns", "ALTER TABLE _moonyao_turns_v5 RENAME TO _moonyao_turns",
    "CREATE INDEX _moonyao_turns_chat ON _moonyao_turns(chat_id)", "CREATE UNIQUE INDEX _moonyao_one_active_turn ON _moonyao_turns(chat_id) WHERE status = 'active'",
    "INSERT INTO _moonyao_migrations(version) VALUES (5)",
  ]
  for statement in statements {
    match exec(connection, statement, "conversation.migrate.v5") {
      Ok(_) => ()
      Err(error) => {
        rollback(connection)
        restore_foreign_keys(connection)
        return Err(error)
      }
    }
  }
  match exec(connection, "COMMIT", "conversation.migrate.v5") {
    Err(error) => {
      rollback(connection)
      restore_foreign_keys(connection)
      Err(error)
    }
    Ok(_) => {
      restore_foreign_keys(connection)
      Ok(())
    }
  }
}
