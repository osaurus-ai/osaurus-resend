import Foundation

/// Canonical tool-result envelope.
///
/// The host AUTO-WRAPS any non-envelope tool output as a SUCCESS
/// (`{"ok":true,"result":<output>}`). That means a tool that returns a bare
/// `{"error":"..."}` or a plain string on failure is misclassified as a
/// success. Every tool failure path MUST therefore return a canonical failure
/// envelope produced by `Envelope.failure(...)` so the host classifies it
/// correctly. Successful tool output is left as-is and the host wraps it.
enum Envelope {
  enum Kind: String {
    case invalidArgs = "invalid_args"
    case executionError = "execution_error"
    case notFound = "not_found"
    case unavailable = "unavailable"
  }

  /// Builds a canonical failure envelope:
  /// `{"ok":false,"kind":"<kind>","message":"...","retryable":<bool>}`.
  /// `retryable` defaults to the per-kind default when not specified.
  static func failure(_ kind: Kind, _ message: String, retryable: Bool? = nil) -> String {
    let retry = retryable ?? defaultRetryable(for: kind)
    return
      "{\"ok\":false,\"kind\":\"\(kind.rawValue)\",\"message\":\"\(escape(message))\",\"retryable\":\(retry)}"
  }

  /// Wraps an already-serialized JSON payload as a canonical success envelope.
  static func successRaw(_ jsonPayload: String) -> String { "{\"ok\":true,\"result\":\(jsonPayload)}" }

  private static func defaultRetryable(for kind: Kind) -> Bool {
    switch kind {
    case .invalidArgs, .executionError, .unavailable: return true
    case .notFound: return false
    }
  }

  static func escape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count + 2)
    for ch in s {
      switch ch {
      case "\\": out += "\\\\"
      case "\"": out += "\\\""
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      default:
        if let a = ch.asciiValue, a < 0x20 {
          out += String(format: "\\u%04x", a)
        } else {
          out.append(ch)
        }
      }
    }
    return out
  }
}
