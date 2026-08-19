///|
fn starts_with(data : Bytes, expected : Array[Int]) -> Bool {
  if data.length() < expected.length() {
    return false
  }
  for index = 0; index < expected.length(); index = index + 1 {
    if data[index].to_int() != expected[index] {
      return false
    }
  }
  true
}

///|
fn is_webp(data : Bytes) -> Bool {
  data.length() >= 12 &&
  starts_with(data, [0x52, 0x49, 0x46, 0x46]) &&
  data[8].to_int() == 0x57 &&
  data[9].to_int() == 0x45 &&
  data[10].to_int() == 0x42 &&
  data[11].to_int() == 0x50
}

///|
fn is_utf8_text(data : Bytes) -> Bool {
  ignore(@encoding.decoder(@encoding.UTF8).decode(data)) catch {
    _ => return false
  }
  for byte in data {
    if byte.to_int() == 0 {
      return false
    }
  }
  true
}

///|
pub fn classify(
  data : Bytes,
  media_type : String,
) -> Result[Kind, @errors.EngineError] {
  let image = match media_type {
    "image/png" =>
      starts_with(data, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    "image/jpeg" => starts_with(data, [0xff, 0xd8, 0xff])
    "image/gif" => starts_with(data, [0x47, 0x49, 0x46, 0x38])
    "image/webp" => is_webp(data)
    _ => false
  }
  if image {
    if data.length() > max_image_bytes {
      return Err(@errors.invalid_argument("image is too large", "attachment"))
    }
    return Ok(Image)
  }
  if ["text/plain", "text/markdown", "text/csv", "application/json"].contains(
      media_type,
    ) {
    if data.length() > max_text_bytes {
      return Err(
        @errors.invalid_argument("text attachment is too large", "attachment"),
      )
    }
    if !is_utf8_text(data) {
      return Err(
        @errors.invalid_argument(
          "text attachment must be valid UTF-8 without NUL", "attachment",
        ),
      )
    }
    return Ok(Text)
  }
  Err(
    @errors.invalid_argument(
      "unsupported or mismatched attachment media type", "attachment.media_type",
    ),
  )
}

///|
pub fn digest(data : Bytes) -> String {
  @crypto.bytes_to_hex_string(@crypto.sha256(data))
}

///|
pub fn storage_key(id : String) -> Result[String, @errors.EngineError] {
  if !valid_id(id) {
    return Err(
      @errors.invalid_argument("invalid attachment id", "attachment.id"),
    )
  }
  Ok(id[4:6].to_owned() + "/" + id)
}

///|
/// Write immutable content below a caller-owned storage root.
pub fn write_local(
  root : String,
  attachment : Attachment,
  data : Bytes,
) -> Result[Unit, @errors.EngineError] {
  if !valid_id(attachment.id) ||
    attachment.storage_key != storage_key(attachment.id).unwrap() {
    return Err(
      @errors.invalid_argument("invalid attachment storage key", "attachment"),
    )
  }
  let prefix = root + "/" + attachment.id[4:6].to_owned()
  if !@fs.path_exists(prefix) {
    @fs.create_dir(prefix) catch {
      _ =>
        return Err(
          @errors.internal_error(
            "could not create attachment directory", "attachment",
          ),
        )
    }
  }
  let target = root + "/" + attachment.storage_key
  if @fs.path_exists(target) {
    return Err(
      @errors.invalid_argument("attachment already exists", "attachment.id"),
    )
  }
  @fs.write_bytes_to_file(target, data) catch {
    _ =>
      return Err(
        @errors.internal_error("could not write attachment", "attachment"),
      )
  }
  Ok(())
}

///|
pub fn read_local(
  root : String,
  attachment : Attachment,
) -> Result[Bytes, @errors.EngineError] {
  if !valid_id(attachment.id) ||
    attachment.storage_key != storage_key(attachment.id).unwrap() {
    return Err(
      @errors.invalid_argument("invalid attachment storage key", "attachment"),
    )
  }
  let data = @fs.read_file_to_bytes(root + "/" + attachment.storage_key) catch {
    _ =>
      return Err(
        @errors.invalid_argument(
          "attachment content was not found", "attachment",
        ),
      )
  }
  if data.length() != attachment.byte_size || digest(data) != attachment.sha256 {
    return Err(
      @errors.internal_error("attachment integrity check failed", "attachment"),
    )
  }
  Ok(data)
}
