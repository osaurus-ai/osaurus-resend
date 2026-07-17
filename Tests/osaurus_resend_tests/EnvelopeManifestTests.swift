import Foundation
import Testing

@testable import osaurus_resend

extension AllResendTests {
@Suite("Manifest")
struct ManifestTests {

  /// Parses the plugin manifest and asserts the host contract: plugin_id is
  /// `osaurus.resend` and every advertised tool carries a non-empty `id` and
  /// `description`.
  @Test("manifest parses and every tool has non-empty id + description")
  func manifestToolsHaveIdAndDescription() throws {
    let data = try #require(resendManifestJSON.data(using: .utf8))
    let root = try #require(
      try JSONSerialization.jsonObject(with: data) as? [String: Any],
      "manifest must be a JSON object")

    #expect(root["plugin_id"] as? String == "osaurus.resend")

    let capabilities = try #require(root["capabilities"] as? [String: Any])
    let tools = try #require(capabilities["tools"] as? [[String: Any]])
    #expect(!tools.isEmpty)

    let expectedIds: Set<String> = [
      "resend_send", "resend_reply", "resend_list_threads",
      "resend_get_thread", "resend_label_thread",
    ]
    var seenIds: Set<String> = []

    for tool in tools {
      let id = tool["id"] as? String
      #expect(id != nil && !(id ?? "").isEmpty, "every tool must have a non-empty id")
      let description = tool["description"] as? String
      #expect(
        description != nil && !(description ?? "").isEmpty,
        "every tool must have a non-empty description")
      if let id { seenIds.insert(id) }
    }

    #expect(seenIds == expectedIds, "manifest must advertise exactly the five known tools")
  }
}

@Suite("Envelope")
struct EnvelopeTests {

  /// `Envelope.failure` must round-trip into the canonical failure shape:
  /// `{"ok":false,"kind":"<kind>","message":"...","retryable":<bool>}`.
  @Test("failure round-trips into canonical shape")
  func failureRoundTrip() throws {
    let json = Envelope.failure(.invalidArgs, "bad input")
    let data = try #require(json.data(using: .utf8))
    let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(obj["ok"] as? Bool == false)
    #expect(obj["kind"] as? String == "invalid_args")
    #expect(obj["message"] as? String == "bad input")
    // invalid_args is deterministic and defaults to retryable == false.
    #expect(obj["retryable"] as? Bool == false)
  }

  @Test("default retryable per kind")
  func defaultRetryable() throws {
    func retryable(_ kind: Envelope.Kind) throws -> Bool {
      let data = try #require(Envelope.failure(kind, "m").data(using: .utf8))
      let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
      return try #require(obj["retryable"] as? Bool)
    }
    #expect(try retryable(.invalidArgs) == false)
    #expect(try retryable(.executionError) == true)
    #expect(try retryable(.unavailable) == true)
    #expect(try retryable(.notFound) == false)
  }

  @Test("explicit retryable overrides the default")
  func explicitRetryableOverride() throws {
    let json = Envelope.failure(.unavailable, "no key", retryable: false)
    let data = try #require(json.data(using: .utf8))
    let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(obj["kind"] as? String == "unavailable")
    #expect(obj["retryable"] as? Bool == false)
  }

  @Test("message with special characters stays valid JSON")
  func escapesSpecialCharacters() throws {
    let messy = "line1\nline2\t\"quoted\" \\backslash\\ \r end"
    let json = Envelope.failure(.executionError, messy)
    let data = try #require(json.data(using: .utf8))
    let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(obj["message"] as? String == messy)
    #expect(obj["kind"] as? String == "execution_error")
  }
}
}
