///|
async test "turn task cancellation stops child work" {
  let finished = Ref(false)
  @async.with_task_group() <| group => {
    let task = group.spawn(() => {
      @async.sleep(500)
      finished.val = true
    })
    @async.sleep(10)
    task.cancel()
    @async.sleep(10)
  }
  assert_false(finished.val)
}

///|
async test "turn deadline cancels the protected operation" {
  let timed_out = Ref(false)
  @async.with_task_group() <| _ => {
    @async.with_timeout(10, () => @async.sleep(500)) catch {
      @async.TimeoutError => timed_out.val = true
      error => raise error
    }
  }
  assert_true(timed_out.val)
}

///|
async test "cancellation during retry backoff does not wait for the full delay" {
  let started = Ref(false)
  let completed = Ref(false)
  @async.with_task_group() <| group => {
    let task = group.spawn(() => {
      started.val = true
      @async.sleep(1000)
      completed.val = true
    })
    while !started.val {
      @async.sleep(1)
    }
    @async.sleep(10)
    task.cancel()
  }
  assert_false(completed.val)
}
