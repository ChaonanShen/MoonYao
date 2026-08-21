///|
/// Dispatch a provider-neutral request to the configured wire adapter.
pub async fn complete_provider_until(
  connector : Connector,
  request : ChatRequest,
  api_key : String,
  sink : (CompletionEvent) -> Unit,
  deadline_at : Int64,
) -> Result[(Array[CompletionEvent], String, Usage), @errors.EngineError] {
  match connector.connector_type {
    "openai_chat" =>
      complete_http_until(connector, request, api_key, sink, deadline_at)
    "anthropic_messages" =>
      complete_anthropic_until(connector, request, api_key, sink, deadline_at)
    "gemini_generate_content" =>
      complete_gemini_until(connector, request, api_key, sink, deadline_at)
    _ => Err(@errors.llm_error("connector provider is not supported"))
  }
}

///|
fn provider_event_boundary(buffer : Array[Byte]) -> (Int, Int)? {
  for index = 0; index + 1 < buffer.length(); index = index + 1 {
    if buffer[index] == b'\n' && buffer[index + 1] == b'\n' {
      return Some((index, 2))
    }
    if index + 3 < buffer.length() &&
      buffer[index] == b'\r' &&
      buffer[index + 1] == b'\n' &&
      buffer[index + 2] == b'\r' &&
      buffer[index + 3] == b'\n' {
      return Some((index, 4))
    }
  }
  None
}

///|
fn provider_sse_data(block : String) -> String? {
  let output = StringBuilder::new()
  for raw_line in block.split("\n") {
    let line = raw_line.trim()
    if line.has_prefix("data:") {
      if output.to_string().length() > 0 {
        output.write_char('\n')
      }
      output.write_string(line[5:].trim().to_owned())
    }
  }
  let value = output.to_string()
  if value.length() > 0 {
    Some(value)
  } else {
    None
  }
}
