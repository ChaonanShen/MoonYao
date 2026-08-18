///|
fn usage_error() -> Unit {
  println(
    "{\"error\":{\"code\":\"invalid_argument\",\"message\":\"usage: moonyao check <app-dir>\",\"path\":\"$\"}}",
  )
  @sys.exit(2)
}

///|
fn main {
  match @env.args() {
    [_, "check", app_dir] =>
      match @app.load(app_dir) {
        Ok(application) =>
          println(
            "checked application '\{application.name}' with \{application.models.length()} model(s)",
          )
        Err(error) => {
          println(error.to_json().stringify())
          @sys.exit(1)
        }
      }
    [_, "bootstrap"] => println(@moonyao.bootstrap_message())
    _ => usage_error()
  }
}
