///|
fn retry_test_request() -> ChatRequest {
  {
    model: "fake",
    messages: [{ role: User, content: "retry" }],
    wire_messages: None,
    temperature: 0.0,
    max_tokens: 8,
    stream: true,
    tools: [],
  }
}

///|
fn retry_test_connector(port : Int, path : String) -> Connector {
  {
    id: "default",
    connector_type: "openai_chat",
    base_url: "http://127.0.0.1:\{port}/" + path,
    api_key_env: "TEST_KEY",
    model: "fake",
    timeout_ms: 1000,
  }
}

///|
fn retry_test_policy(
  deadline_at? : Int64 = 10000L,
  initial_backoff_ms? : Int = 10,
  max_backoff_ms? : Int = 500,
) -> RetryPolicy {
  { max_attempts: 3, initial_backoff_ms, max_backoff_ms, deadline_at }
}

///|
test "provider failure taxonomy retries only safe failures before output" {
  for status in [429, 500, 502, 503, 504] {
    assert_true(
      provider_failure_retryable({
        kind: HttpStatus(status),
        visible_output: false,
        retry_after_ms: None,
      }),
    )
  }
  for status in [400, 401, 403, 404, 409] {
    assert_false(
      provider_failure_retryable({
        kind: HttpStatus(status),
        visible_output: false,
        retry_after_ms: None,
      }),
    )
  }
  assert_true(
    provider_failure_retryable({
      kind: Transport,
      visible_output: false,
      retry_after_ms: None,
    }),
  )
  assert_false(
    provider_failure_retryable({
      kind: Transport,
      visible_output: true,
      retry_after_ms: None,
    }),
  )
  assert_false(
    provider_failure_retryable({
      kind: Protocol,
      visible_output: false,
      retry_after_ms: None,
    }),
  )
}

///|
async test "provider retries 5xx, rate limits, and pre-output EOF only" {
  @async.with_task_group() <| group => {
    let server_attempts = Ref(0)
    let rate_attempts = Ref(0)
    let auth_attempts = Ref(0)
    let malformed_attempts = Ref(0)
    let early_eof_attempts = Ref(0)
    let visible_eof_attempts = Ref(0)
    let tool_eof_attempts = Ref(0)
    let deadline_attempts = Ref(0)
    let reset_attempts = Ref(0)
    let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever(allow_failure=true) <| ((request, body, connection) => {
        ignore(body.read_all())
        if request.path == "/server/chat/completions" {
          server_attempts.val = server_attempts.val + 1
          if server_attempts.val < 3 {
            connection.send_response(
              if server_attempts.val == 1 {
                500
              } else {
                502
              },
              "Retry",
              extra_headers={ "Content-Length": "0" },
            )
            connection.end_response()
          } else {
            connection.send_response(200, "OK", extra_headers={
              "Content-Type": "text/event-stream",
            })
            connection.write_string(
              "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n",
            )
            connection.end_response()
          }
        } else if request.path == "/rate/chat/completions" {
          rate_attempts.val = rate_attempts.val + 1
          if rate_attempts.val == 1 {
            connection.send_response(429, "Retry", extra_headers={
              "Content-Length": "0",
              "Retry-After": "2",
            })
            connection.end_response()
          } else {
            connection.send_response(200, "OK", extra_headers={
              "Content-Type": "text/event-stream",
            })
            connection.write_string(
              "data: {\"choices\":[{\"delta\":{\"content\":\"rate ok\"}}]}\n\ndata: [DONE]\n\n",
            )
            connection.end_response()
          }
        } else if request.path == "/auth/chat/completions" {
          auth_attempts.val = auth_attempts.val + 1
          connection.send_response(401, "Unauthorized", extra_headers={
            "Content-Length": "6",
          })
          connection.write_string("secret")
          connection.end_response()
        } else if request.path == "/malformed/chat/completions" {
          malformed_attempts.val = malformed_attempts.val + 1
          connection.send_response(200, "OK", extra_headers={
            "Content-Type": "text/event-stream",
          })
          connection.write_string("data: {bad}\n\ndata: [DONE]\n\n")
          connection.end_response()
        } else if request.path == "/early/chat/completions" {
          early_eof_attempts.val = early_eof_attempts.val + 1
          connection.send_response(200, "OK", extra_headers={
            "Content-Type": "text/event-stream",
          })
          if early_eof_attempts.val > 1 {
            connection.write_string(
              "data: {\"choices\":[{\"delta\":{\"content\":\"recovered\"}}]}\n\ndata: [DONE]\n\n",
            )
          }
          connection.end_response()
        } else if request.path == "/visible/chat/completions" {
          visible_eof_attempts.val = visible_eof_attempts.val + 1
          connection.send_response(200, "OK", extra_headers={
            "Content-Type": "text/event-stream",
          })
          connection.write_string(
            "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n",
          )
          connection.end_response()
        } else if request.path == "/tool/chat/completions" {
          tool_eof_attempts.val = tool_eof_attempts.val + 1
          connection.send_response(200, "OK", extra_headers={
            "Content-Type": "text/event-stream",
          })
          connection.write_string(
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call-1\",\"function\":{\"name\":\"work\",\"arguments\":\"{}\"}}]}}]}\n\n",
          )
          connection.end_response()
        } else if request.path == "/deadline/chat/completions" {
          deadline_attempts.val = deadline_attempts.val + 1
          connection.send_response(503, "Retry", extra_headers={
            "Content-Length": "0",
          })
          connection.end_response()
        } else {
          reset_attempts.val = reset_attempts.val + 1
          connection.close()
        }
      })
    }
    let request = retry_test_request()
    let clock = Ref(0L)
    let sleeps : Array[Int] = []
    let observed : Array[CompletionEvent] = []
    let sleeper : async (Int) -> Unit = duration => {
      sleeps.push(duration)
      clock.val = clock.val + duration.to_int64()
    }
    match
      complete_http_with_retry(
        retry_test_connector(server.addr.port(), "server"),
        request,
        "key",
        event => observed.push(event),
        retry_test_policy(),
        () => clock.val,
        sleeper,
      ) {
      Ok((events, content, _)) => {
        assert_eq(content, "ok")
        assert_eq(server_attempts.val, 3)
        assert_eq(sleeps, [10, 20])
        assert_eq(events.filter(event => event == Started).length(), 1)
        assert_true(events.contains(ProviderRetrying(2, 3, 10, "server_error")))
      }
      Err(error) => fail(error.message)
    }
    match
      complete_http_with_retry(
        retry_test_connector(server.addr.port(), "rate"),
        request,
        "key",
        _ => (),
        retry_test_policy(),
        () => clock.val,
        sleeper,
      ) {
      Ok((events, content, _)) => {
        assert_eq(content, "rate ok")
        assert_eq(rate_attempts.val, 2)
        assert_true(events.contains(ProviderRetrying(2, 3, 500, "rate_limit")))
      }
      Err(error) => fail(error.message)
    }
    match
      complete_http_with_retry(
        retry_test_connector(server.addr.port(), "auth"),
        request,
        "key",
        _ => (),
        retry_test_policy(),
        () => clock.val,
        sleeper,
      ) {
      Err(error) => {
        assert_true(error.message.contains("HTTP 401"))
        assert_false(error.message.contains("secret"))
      }
      Ok(_) => fail("expected authentication failure")
    }
    assert_eq(auth_attempts.val, 1)
    match
      complete_http_with_retry(
        retry_test_connector(server.addr.port(), "malformed"),
        request,
        "key",
        _ => (),
        retry_test_policy(),
        () => clock.val,
        sleeper,
      ) {
      Err(error) => assert_true(error.message.contains("malformed"))
      Ok(_) => fail("expected protocol failure")
    }
    assert_eq(malformed_attempts.val, 1)
    match
      complete_http_with_retry(
        retry_test_connector(server.addr.port(), "early"),
        request,
        "key",
        _ => (),
        retry_test_policy(),
        () => clock.val,
        sleeper,
      ) {
      Ok((_, content, _)) => assert_eq(content, "recovered")
      Err(error) => fail(error.message)
    }
    assert_eq(early_eof_attempts.val, 2)
    match
      complete_http_with_retry(
        retry_test_connector(server.addr.port(), "visible"),
        request,
        "key",
        _ => (),
        retry_test_policy(),
        () => clock.val,
        sleeper,
      ) {
      Err(error) => assert_true(error.message.contains("[DONE]"))
      Ok(_) => fail("expected visible truncated stream failure")
    }
    assert_eq(visible_eof_attempts.val, 1)
    match
      complete_http_with_retry(
        retry_test_connector(server.addr.port(), "tool"),
        request,
        "key",
        _ => (),
        retry_test_policy(),
        () => clock.val,
        sleeper,
      ) {
      Err(error) => assert_true(error.message.contains("[DONE]"))
      Ok(_) => fail("expected visible tool stream failure")
    }
    assert_eq(tool_eof_attempts.val, 1)
    let deadline_clock = Ref(0L)
    let deadline_slept = Ref(false)
    match
      complete_http_with_retry(
        retry_test_connector(server.addr.port(), "deadline"),
        request,
        "key",
        _ => (),
        retry_test_policy(deadline_at=50L, initial_backoff_ms=100),
        () => deadline_clock.val,
        _ => deadline_slept.val = true,
      ) {
      Err(error) => assert_true(error.message.contains("timed out"))
      Ok(_) => fail("expected retry deadline")
    }
    assert_eq(deadline_attempts.val, 1)
    assert_false(deadline_slept.val)
    let reset_events : Array[CompletionEvent] = []
    match
      complete_http_with_retry(
        retry_test_connector(server.addr.port(), "reset"),
        request,
        "key",
        event => reset_events.push(event),
        retry_test_policy(),
        () => clock.val,
        sleeper,
      ) {
      Err(error) => assert_true(error.message.contains("3 attempts"))
      Ok(_) => fail("expected reset transport failure")
    }
    assert_eq(reset_attempts.val, 3)
    assert_true(reset_events.contains(ProviderRetrying(2, 3, 10, "transport")))
    let closed_server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
    let closed_port = closed_server.addr.port()
    closed_server.close()
    let refused_events : Array[CompletionEvent] = []
    match
      complete_http_with_retry(
        retry_test_connector(closed_port, "refused"),
        request,
        "key",
        event => refused_events.push(event),
        retry_test_policy(),
        () => clock.val,
        sleeper,
      ) {
      Err(error) => assert_true(error.message.contains("3 attempts"))
      Ok(_) => fail("expected refused transport failure")
    }
    assert_true(
      refused_events.contains(ProviderRetrying(3, 3, 20, "transport")),
    )
    server.close()
  }
}

///|
async test "cancelling provider retry stops interruptible backoff" {
  @async.with_task_group() <| group => {
    let attempts = Ref(0)
    let retrying = Ref(false)
    let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever(allow_failure=true) <| ((_, body, connection) => {
        ignore(body.read_all())
        attempts.val = attempts.val + 1
        connection.send_response(503, "Retry", extra_headers={
          "Content-Length": "0",
        })
        connection.end_response()
      })
    }
    let task = group.spawn(() => {
      ignore(
        complete_http_with_retry(
          retry_test_connector(server.addr.port(), "cancel"),
          retry_test_request(),
          "key",
          event => {
            if event is ProviderRetrying(_, _, _, _) {
              retrying.val = true
            }
          },
          retry_test_policy(
            deadline_at=@async.now() + 5000L,
            initial_backoff_ms=1000,
            max_backoff_ms=1000,
          ),
          () => @async.now(),
          duration => @async.sleep(duration),
        ),
      )
    })
    while !retrying.val {
      @async.sleep(1)
    }
    task.cancel()
    @async.sleep(20)
    assert_eq(attempts.val, 1)
    server.close()
  }
}
