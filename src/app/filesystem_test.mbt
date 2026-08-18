///|
test "native file system reads a tracked UTF-8 source file" {
  let source = read_dsl_source("moon.mod")
  assert_true(source.contains("ChaonanShen/MoonYao"))
}
