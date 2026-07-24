import CryptoKit
import Foundation
import OsaurusPluginABI

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

/// Frees a `const char*` returned by any host callback via
/// `HostBridge.hostFree` (host `free_string` on v6+ hosts, libc `free()`
/// on older ones). Never call the plugin's own `free_string` on host
/// pointers — that slot is the reverse direction (host → plugin).
func freeHostString(_ ptr: UnsafePointer<CChar>?) {
  HostBridge.shared.hostFree(ptr)
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
//
// Routed through `HostBridge` using the header's canonical `OsrLogLevel`
// scale (0=trace ... 4=error). The pre-SDK code passed a shifted 0..3
// scale (debug logged as trace, error logged as warn); Wave 2 fixed the
// mapping. The bridge also fixes a wave-1 leak: `makeCString` results were
// passed to `log` and never freed.

func logDebug(_ message: String) {
  HostBridge.shared.log(OsrLogLevel.debug, message)
}

func logInfo(_ message: String) {
  HostBridge.shared.log(OsrLogLevel.info, message)
}

func logWarn(_ message: String) {
  HostBridge.shared.log(OsrLogLevel.warn, message)
}

func logError(_ message: String) {
  HostBridge.shared.log(OsrLogLevel.error, message)
}

// MARK: - Config

func configGet(_ key: String) -> String? {
  HostBridge.shared.configGet(key)
}

func configSet(_ key: String, _ value: String) {
  HostBridge.shared.configSet(key, value)
}

func configDelete(_ key: String) {
  HostBridge.shared.configDelete(key)
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
