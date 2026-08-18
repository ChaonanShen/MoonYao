///|
test "bootstrap message identifies the native runtime" {
  assert_eq(
    bootstrap_message(),
    "MoonYao Core bootstrap: Native runtime is ready.",
  )
}
