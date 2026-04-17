import Foundation

// MARK: - JSON Helpers

func makeJSONString(_ dict: [String: Any]) -> String? {
  guard let data = try? JSONSerialization.data(withJSONObject: dict),
    let str = String(data: data, encoding: .utf8)
  else { return nil }
  return str
}

func parseJSON<T: Decodable>(_ json: String, as type: T.Type) -> T? {
  guard let data = json.data(using: .utf8) else { return nil }
  return try? JSONDecoder().decode(type, from: data)
}

func serializeParams(_ values: [Any]) -> String {
  guard let data = try? JSONSerialization.data(withJSONObject: values),
    let str = String(data: data, encoding: .utf8)
  else { return "[]" }
  return str
}

func escapeJSON(_ s: String) -> String {
  let data = try? JSONSerialization.data(withJSONObject: [s])
  guard let data,
    let arr = String(data: data, encoding: .utf8)
  else { return s }
  return String(arr.dropFirst(2).dropLast(2))
}

// MARK: - Logging

func logDebug(_ message: String) {
  hostAPI?.pointee.log?(0, makeCString(message))
}

func logInfo(_ message: String) {
  hostAPI?.pointee.log?(1, makeCString(message))
}

func logWarn(_ message: String) {
  hostAPI?.pointee.log?(2, makeCString(message))
}

func logError(_ message: String) {
  hostAPI?.pointee.log?(3, makeCString(message))
}

// MARK: - Config

func configGet(_ key: String) -> String? {
  guard let getValue = hostAPI?.pointee.config_get else { return nil }
  let result = key.withCString { ptr in getValue(ptr) }
  guard let result else { return nil }
  return String(cString: result)
}

func configSet(_ key: String, _ value: String) {
  guard let setValue = hostAPI?.pointee.config_set else { return }
  key.withCString { k in
    value.withCString { v in
      setValue(k, v)
    }
  }
}

func configDelete(_ key: String) {
  guard let deleteValue = hostAPI?.pointee.config_delete else { return }
  key.withCString { ptr in deleteValue(ptr) }
}

// MARK: - Host File Reading

struct HostFileResult {
  let data: Data
  let mimeType: String
}

struct FileReadError: Error {
  let message: String
}

func readHostFile(path: String) -> Result<HostFileResult, FileReadError> {
  guard let fileRead = hostAPI?.pointee.file_read else {
    return .failure(FileReadError(message: "file_read not available"))
  }
  let resultStr: String? = path.withCString { ptr in
    guard let resultPtr = fileRead(ptr) else { return nil }
    return String(cString: resultPtr)
  }
  guard let resultStr else {
    return .failure(FileReadError(message: "file_read returned nil for \(path)"))
  }
  guard let resultData = resultStr.data(using: .utf8),
    let json = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any]
  else {
    return .failure(FileReadError(message: "Failed to parse file_read response"))
  }
  if let error = json["error"] as? String {
    return .failure(FileReadError(message: error))
  }
  guard let content = json["content"] as? String else {
    return .failure(FileReadError(message: "No content in file_read response"))
  }
  let encoding = json["encoding"] as? String ?? "utf8"
  let mimeType = json["mime_type"] as? String ?? "application/octet-stream"

  let fileData: Data
  if encoding == "base64" {
    guard let decoded = Data(base64Encoded: content) else {
      return .failure(FileReadError(message: "Failed to decode base64 content"))
    }
    fileData = decoded
  } else {
    guard let d = content.data(using: .utf8) else {
      return .failure(FileReadError(message: "Failed to encode content as UTF-8"))
    }
    fileData = d
  }
  return .success(HostFileResult(data: fileData, mimeType: mimeType))
}
