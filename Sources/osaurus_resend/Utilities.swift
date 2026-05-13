import CryptoKit
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

// MARK: - Host String Ownership

/// Frees a `const char*` returned by any host callback. Host strings are
/// `strdup`'d; failing to free leaks one allocation per call. v6+ hosts route
/// through `host->free_string`; older hosts use libc `free` directly, which
/// is what the host's own implementation does internally.
///
/// Never call the plugin's own `free_string` on host pointers — that slot is
/// the reverse direction (host → plugin) and routing host pointers through it
/// can corrupt the heap.
func freeHostString(_ ptr: UnsafePointer<CChar>?) {
  guard let ptr else { return }
  if let f = hostAPI?.pointee.free_string {
    f(ptr)
  } else {
    free(UnsafeMutableRawPointer(mutating: ptr))
  }
}

/// Calls a host function that takes one C string and returns a host-allocated
/// C string, copying the result into a Swift `String` and freeing the host's
/// allocation. Returns `nil` if the host returned `nil`.
func callHostString(
  _ input: String,
  via fn: @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
) -> String? {
  input.withCString { ptr -> String? in
    guard let p = fn(ptr) else { return nil }
    defer { freeHostString(p) }
    return String(cString: p)
  }
}

/// Two-argument variant of `callHostString` used by the DB callbacks.
func callHostString(
  _ a: String, _ b: String,
  via fn: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
) -> String? {
  a.withCString { aPtr in
    b.withCString { bPtr -> String? in
      guard let p = fn(aPtr, bPtr) else { return nil }
      defer { freeHostString(p) }
      return String(cString: p)
    }
  }
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
  return callHostString(key, via: getValue)
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

// MARK: - Route Helpers

/// Builds the JSON envelope the host expects when a route handler returns.
func makeRouteResponse(status: Int, body: String, contentType: String = "text/plain") -> String {
  let resp: [String: Any] = [
    "status": status,
    "headers": ["Content-Type": contentType],
    "body": body,
  ]
  return makeJSONString(resp) ?? "{\"status\":500}"
}

// MARK: - Session Id Derivation

/// Stable namespace UUID for this plugin. Used to derive Osaurus `session_id`s
/// from thread ids so every email on the same thread reattaches to the same
/// session and the agent sees one continuous transcript instead of starting
/// fresh on each inbound message.
private let resendSessionNamespace = UUID(uuidString: "8d6fa5e8-2c4e-4e9b-9f7d-6a1f8b2c3d4e")!

/// Deterministic Osaurus `session_id` for a Resend thread. Same thread always
/// resolves to the same UUID; reattach is naturally agent-scoped on the host
/// side, so a session belonging to a different agent silently misses and a
/// fresh one is created.
func sessionId(forThreadId threadId: String) -> String {
  UUID.v5(namespace: resendSessionNamespace, name: "resend:thread:\(threadId)").uuidString
}

extension UUID {
  /// Build a v5 UUID per RFC 4122 §4.3 (namespace + SHA-1(name)). Deterministic:
  /// same `(namespace, name)` always yields the same UUID.
  static func v5(namespace: UUID, name: String) -> UUID {
    let ns = namespace.uuid
    var input = Data(capacity: 16 + name.utf8.count)
    input.append(contentsOf: [
      ns.0, ns.1, ns.2, ns.3, ns.4, ns.5, ns.6, ns.7,
      ns.8, ns.9, ns.10, ns.11, ns.12, ns.13, ns.14, ns.15,
    ])
    input.append(contentsOf: Array(name.utf8))

    let digest = Insecure.SHA1.hash(data: input)
    var out = Array(digest.prefix(16))
    out[6] = (out[6] & 0x0F) | 0x50
    out[8] = (out[8] & 0x3F) | 0x80
    return UUID(uuid: (
      out[0], out[1], out[2], out[3], out[4], out[5], out[6], out[7],
      out[8], out[9], out[10], out[11], out[12], out[13], out[14], out[15]
    ))
  }
}

// MARK: - Email Address Helpers

/// Extracts the bare email address from a value that may be either a plain
/// `user@host` string or an RFC 5322 `Display Name <user@host>` form.
func extractEmailAddress(_ raw: String) -> String {
  if let start = raw.firstIndex(of: "<"),
    let end = raw.firstIndex(of: ">"),
    start < end
  {
    return String(raw[raw.index(after: start)..<end])
  }
  return raw.trimmingCharacters(in: .whitespaces)
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
  guard let resultStr = callHostString(path, via: fileRead) else {
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
