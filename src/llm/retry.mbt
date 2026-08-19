///|
pub(all) enum ProviderFailureKind {
  Transport
  HttpStatus(Int)
  Protocol
  TruncatedStream
  Timeout
  Cancelled
} derive(Eq, Debug)

///|
pub(all) struct ProviderFailure {
  kind : ProviderFailureKind
  visible_output : Bool
  retry_after_ms : Int?
} derive(Eq, Debug)

///|
pub(all) struct RetryPolicy {
  max_attempts : Int
  initial_backoff_ms : Int
  max_backoff_ms : Int
  deadline_at : Int64
} derive(Eq, Debug)

///|
pub fn default_retry_policy(deadline_at : Int64) -> RetryPolicy {
  {
    max_attempts: 3,
    initial_backoff_ms: 100,
    max_backoff_ms: 1000,
    deadline_at,
  }
}

///|
pub fn provider_failure_reason(failure : ProviderFailure) -> String {
  match failure.kind {
    Transport => "transport"
    HttpStatus(429) => "rate_limit"
    HttpStatus(_) => "server_error"
    Protocol => "protocol"
    TruncatedStream => "truncated_stream"
    Timeout => "timeout"
    Cancelled => "cancelled"
  }
}

///|
pub fn provider_failure_retryable(failure : ProviderFailure) -> Bool {
  if failure.visible_output {
    return false
  }
  match failure.kind {
    Transport | TruncatedStream => true
    HttpStatus(status) =>
      status == 429 ||
      status == 500 ||
      status == 502 ||
      status == 503 ||
      status == 504
    Protocol | Timeout | Cancelled => false
  }
}

///|
pub fn provider_retry_delay(
  failure : ProviderFailure,
  failed_attempt : Int,
  policy : RetryPolicy,
) -> Int {
  match failure.retry_after_ms {
    Some(value) => {
      let non_negative = if value < 0 { 0 } else { value }
      if non_negative > policy.max_backoff_ms {
        policy.max_backoff_ms
      } else {
        non_negative
      }
    }
    None => {
      let mut delay = policy.initial_backoff_ms
      for index = 1; index < failed_attempt; index = index + 1 {
        let doubled = delay * 2
        delay = if doubled > policy.max_backoff_ms {
          policy.max_backoff_ms
        } else {
          doubled
        }
      }
      delay
    }
  }
}

///|
pub fn provider_failure_error(
  failure : ProviderFailure,
  attempts : Int,
) -> @errors.EngineError {
  let suffix = if attempts > 1 {
    " after " + attempts.to_string() + " attempts"
  } else {
    ""
  }
  match failure.kind {
    HttpStatus(status) =>
      @errors.llm_error("provider returned HTTP " + status.to_string() + suffix)
    Protocol => @errors.llm_error("provider returned malformed data" + suffix)
    TruncatedStream =>
      @errors.llm_error("provider stream ended before [DONE]" + suffix)
    Timeout => @errors.llm_error("provider request timed out")
    Cancelled => @errors.llm_error("provider request was cancelled")
    Transport => @errors.llm_error("provider request failed" + suffix)
  }
}
