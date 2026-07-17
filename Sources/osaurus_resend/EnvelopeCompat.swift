import Foundation
import OsaurusPluginKit

/// Canonical tool-result envelope, rendered by the pinned
/// `osaurus-plugin-sdk` (`OsaurusPluginKit.Envelope`).
///
/// The host AUTO-WRAPS any non-envelope tool output as a SUCCESS
/// (`{"ok":true,"result":<output>}`), so every tool failure path MUST
/// return a canonical failure envelope.
///
/// This thin local shim exists for exactly one wire-shape divergence: this
/// plugin's failure kind set includes `unavailable` (default retryable),
/// which predates the SDK and is asserted by wave-1 tests and consumed by
/// existing agents. The SDK's canonical kind set has no `unavailable`, so
/// the local `Kind` keeps it and delegates every shared kind (and all JSON
/// rendering/escaping) to the SDK builders.
enum Envelope {
  enum Kind: String {
    case invalidArgs = "invalid_args"
    case executionError = "execution_error"
    case notFound = "not_found"
    case unavailable = "unavailable"

    /// SDK equivalent, nil for the plugin-local `unavailable` kind.
    fileprivate var sdkKind: OsaurusPluginKit.Envelope.Kind? {
      switch self {
      case .invalidArgs: return .invalidArgs
      case .executionError: return .executionError
      case .notFound: return .notFound
      case .unavailable: return nil
      }
    }
  }

  /// Builds a canonical failure envelope:
  /// `{"ok":false,"kind":"<kind>","message":"...","retryable":<bool>}`.
  /// `retryable` defaults to the per-kind default when not specified
  /// (`unavailable` defaults to retryable, matching wave-1 behavior).
  static func failure(_ kind: Kind, _ message: String, retryable: Bool? = nil) -> String {
    guard let sdkKind = kind.sdkKind else {
      let retry = retryable ?? true
      return "{\"ok\":false,\"kind\":\"\(kind.rawValue)\",\"message\":\"\(escape(message))\",\"retryable\":\(retry)}"
    }
    return OsaurusPluginKit.Envelope.failure(sdkKind, message, retryable: retryable)
  }

  /// Wraps an already-serialized JSON payload as a canonical success
  /// envelope: `{"ok":true,"result":<raw>}`.
  static func successRaw(_ jsonPayload: String) -> String {
    OsaurusPluginKit.Envelope.success(raw: jsonPayload)
  }

  static func escape(_ s: String) -> String {
    OsaurusPluginKit.Envelope.escape(s)
  }
}
