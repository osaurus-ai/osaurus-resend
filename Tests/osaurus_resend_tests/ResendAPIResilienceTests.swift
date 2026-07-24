import Foundation
import OsaurusPluginABI
import Testing

@testable import osaurus_resend

extension AllResendTests {
@Suite("Resend API Resilience", .serialized)
struct ResendAPIResilienceTests {

  // MARK: - Helpers

  private func parsedRequests() -> [(method: String, path: String)] {
    mockHTTPRequests.compactMap { raw -> (String, String)? in
      guard let data = raw.data(using: .utf8),
        let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let method = dict["method"] as? String,
        let url = dict["url"] as? String
      else { return nil }
      return (method, url.replacingOccurrences(of: "https://api.resend.com", with: ""))
    }
  }

  // MARK: - Tests

  @Test("429 with Retry-After is retried then succeeds")
  func retriesOn429() {
    MockHost.setUp()
    MockHost.pushHTTPResponse(
      status: 429, body: ["message": "rate limited"],
      headers: ["Retry-After": 0])
    MockHost.pushHTTPResponse(status: 200, body: ["id": "ok-1"])

    let (ok, data) = resendRequest(
      apiKey: "re_test", method: "POST", path: "/emails", body: ["x": 1])
    #expect(ok == true)
    #expect(data?["id"] as? String == "ok-1")
    #expect(parsedRequests().count == 2, "Should retry once, total = 2")
  }

  @Test("502 retries until success or cap")
  func retriesOn5xx() {
    MockHost.setUp()
    MockHost.pushHTTPResponse(status: 502, body: ["message": "bad gateway"])
    MockHost.pushHTTPResponse(status: 502, body: ["message": "bad gateway"])
    MockHost.pushHTTPResponse(status: 200, body: ["id": "eventually-ok"])

    let (ok, data) = resendRequest(apiKey: "re_test", method: "GET", path: "/emails/123")
    #expect(ok == true)
    #expect(data?["id"] as? String == "eventually-ok")
    #expect(parsedRequests().count == 3)
  }

  @Test("Persistent 5xx exhausts retries and surfaces failure")
  func exhaustsRetriesOn5xx() {
    MockHost.setUp()
    // Push 4 failures: initial + 3 retries.
    for _ in 0..<5 {
      MockHost.pushHTTPResponse(status: 503, body: ["message": "service unavailable"])
    }
    let (ok, _) = resendRequest(apiKey: "re_test", method: "POST", path: "/emails")
    #expect(ok == false)
    // 1 initial + 3 retries = 4 calls.
    #expect(parsedRequests().count == 4)
  }

  @Test("4xx (non-429) is NOT retried")
  func doesNotRetryValidationErrors() {
    MockHost.setUp()
    MockHost.pushHTTPResponse(
      status: 422, body: ["name": "validation_error", "message": "to is required"])
    let (ok, _) = resendRequest(apiKey: "re_test", method: "POST", path: "/emails")
    #expect(ok == false)
    #expect(parsedRequests().count == 1, "422 should not retry")
  }

  @Test("Error log surfaces name + message + body snippet")
  func logsFullErrorContext() {
    MockHost.setUp()
    MockHost.pushHTTPResponse(
      status: 500, body: ["name": "internal_error", "message": "Something went wrong"])

    _ = resendRequest(apiKey: "re_test", method: "POST", path: "/webhooks")

    // Find the warning log for the failed request.
    let warning = mockLogMessages.first { entry in
      entry.0 == OsrLogLevel.warn && entry.1.contains("HTTP 500")
    }
    #expect(warning != nil)
    if let w = warning {
      #expect(w.1.contains("internal_error"))
      #expect(w.1.contains("Something went wrong"))
    }
  }

  @Test("Success returns parsed body without retry")
  func successPath() {
    MockHost.setUp()
    MockHost.pushHTTPResponse(status: 200, body: ["id": "abc", "object": "email"])
    let (ok, data) = resendRequest(apiKey: "re_test", method: "POST", path: "/emails")
    #expect(ok == true)
    #expect(data?["id"] as? String == "abc")
    #expect(parsedRequests().count == 1)
  }

  @Test("Retried POST /emails reuses one Idempotency-Key across all attempts")
  func idempotencyKeyStableAcrossRetries() {
    MockHost.setUp()
    MockHost.pushHTTPResponse(status: 429, body: ["message": "rate limited"])
    MockHost.pushHTTPResponse(status: 502, body: ["message": "bad gateway"])
    MockHost.pushHTTPResponse(status: 200, body: ["id": "sent-1"])

    let params = SendEmailParams(
      from: "agent@d.com", to: ["bob@b.com"], subject: "Hi", html: "<p>x</p>",
      text: nil, cc: nil, bcc: nil, replyTo: nil, headers: nil, attachments: nil)
    let (emailId, error) = resendSendEmail(apiKey: "re_test", params: params)
    #expect(emailId == "sent-1")
    #expect(error == nil)

    let keys = idempotencyKeys()
    #expect(keys.count == 3, "every attempt must carry an Idempotency-Key")
    #expect(Set(keys).count == 1, "all attempts must reuse the same key")
    #expect(!(keys.first ?? "").isEmpty)
  }

  @Test("Separate logical sends use distinct Idempotency-Keys")
  func distinctSendsUseDistinctKeys() {
    MockHost.setUp()
    MockHost.pushHTTPResponse(status: 200, body: ["id": "s1"])
    MockHost.pushHTTPResponse(status: 200, body: ["id": "s2"])

    let params = SendEmailParams(
      from: "agent@d.com", to: ["bob@b.com"], subject: "Hi", html: "<p>x</p>",
      text: nil, cc: nil, bcc: nil, replyTo: nil, headers: nil, attachments: nil)
    _ = resendSendEmail(apiKey: "re_test", params: params)
    _ = resendSendEmail(apiKey: "re_test", params: params)

    let keys = idempotencyKeys()
    #expect(keys.count == 2)
    #expect(Set(keys).count == 2, "each logical send gets its own key")
  }

  private func idempotencyKeys() -> [String] {
    mockHTTPRequests.compactMap { raw in
      guard let data = raw.data(using: .utf8),
        let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let headers = dict["headers"] as? [String: Any]
      else { return nil }
      return headers["Idempotency-Key"] as? String
    }
  }

  @Test("Client-side throttle spaces consecutive requests so we don't burst past 5/s")
  func throttleSpacesRequests() {
    MockHost.setUp()
    // Use a small but non-zero interval so the test is fast yet measurable.
    resendThrottleIntervalOverrideMs = 50
    defer { resendThrottleIntervalOverrideMs = 0 }

    for _ in 0..<6 {
      MockHost.pushHTTPResponse(status: 200, body: ["ok": true])
    }

    let started = Date()
    for _ in 0..<6 {
      _ = resendRequest(apiKey: "re_test", method: "DELETE", path: "/webhooks/x")
    }
    let elapsedMs = Date().timeIntervalSince(started) * 1000

    // 6 calls @ 50ms minimum spacing = ~250ms minimum. Allow generous slack.
    #expect(elapsedMs >= 200, "throttle should impose ~5*50ms of spacing, got \(elapsedMs)ms")
    #expect(parsedRequests().count == 6)
  }
}
}
