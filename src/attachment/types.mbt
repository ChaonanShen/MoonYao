///|
pub(all) enum Kind {
  Image
  Text
} derive(Eq, Debug)

///|
pub(all) struct Attachment {
  id : String
  storage_key : String
  filename : String
  media_type : String
  byte_size : Int
  sha256 : String
  kind : Kind
  status : String
  created_at : Int64
  deleted_at : Int64
} derive(Eq, Debug)

///|
pub let max_image_bytes : Int = 10 * 1024 * 1024

///|
pub let max_text_bytes : Int = 2 * 1024 * 1024

///|
pub fn valid_id(id : String) -> Bool {
  if !id.has_prefix("att_") || id.length() < 8 || id.length() > 68 {
    return false
  }
  for character in id[4:] {
    let alpha = (character >= 'a' && character <= 'z') ||
      (character >= 'A' && character <= 'Z')
    let digit = character >= '0' && character <= '9'
    if !(alpha || digit || character == '_' || character == '-') {
      return false
    }
  }
  true
}

///|
pub fn safe_filename(value : String) -> String {
  let output = StringBuilder::new()
  let mut count = 0
  for character in value {
    if count >= 200 {
      break
    }
    if character == '/' || character == '\\' || character.to_int() < 32 {
      output.write_char('_')
    } else {
      output.write_char(character)
    }
    count = count + 1
  }
  let result = output.to_string()
  if result.length() == 0 || result == "." || result == ".." {
    "attachment"
  } else {
    result
  }
}
