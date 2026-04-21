import Foundation
import Testing

@testable import osaurus_resend

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
      entry.0 == 2 && entry.1.contains("HTTP 500")
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
