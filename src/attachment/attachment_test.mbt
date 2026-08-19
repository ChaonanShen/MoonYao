///|
test "attachment ids and filenames cannot become paths" {
  assert_true(valid_id("att_abcdef12"))
  assert_false(valid_id("att_../secret"))
  assert_eq(safe_filename("../a.txt"), ".._a.txt")
  match storage_key("att_abcdef12") {
    Ok(value) => assert_eq(value, "ab/att_abcdef12")
    Err(error) => fail(error.message)
  }
}

///|
test "attachment classifier verifies signatures and text" {
  match classify(b"\x89PNG\r\n\x1a\nbody", "image/png") {
    Ok(kind) => assert_eq(kind, Image)
    Err(error) => fail(error.message)
  }
  match classify(b"not png", "image/png") {
    Err(error) => assert_eq(error.code, @errors.InvalidArgument)
    Ok(_) => fail("expected signature mismatch")
  }
  match classify(b"hello", "text/plain") {
    Ok(kind) => assert_eq(kind, Text)
    Err(error) => fail(error.message)
  }
  match classify(b"a\x00b", "text/plain") {
    Err(_) => ()
    Ok(_) => fail("expected NUL rejection")
  }
  match classify(b"\xff", "text/plain") {
    Err(_) => ()
    Ok(_) => fail("expected invalid UTF-8 rejection")
  }
}

///|
test "attachment metadata persists without exposing a root path" {
  let connection = @sqlite3.Connection::open(":memory:")
  match migrate(connection) {
    Err(error) => fail(error.message)
    Ok(_) => ()
  }
  let attachment : Attachment = {
    id: "att_abcdef12",
    storage_key: "ab/att_abcdef12",
    filename: "a.txt",
    media_type: "text/plain",
    byte_size: 5,
    sha256: digest(b"hello"),
    kind: Text,
    status: "ready",
    created_at: 1,
    deleted_at: 0,
  }
  match insert(connection, attachment) {
    Err(error) => fail(error.message)
    Ok(_) => ()
  }
  match get(connection, attachment.id) {
    Ok(value) => assert_eq(value, attachment)
    Err(error) => fail(error.message)
  }
  connection.close()
}
