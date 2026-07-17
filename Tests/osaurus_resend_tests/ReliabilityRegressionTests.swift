import Foundation
import Testing

@testable import osaurus_resend

extension AllResendTests {
@Suite("Webhook Reliability", .serialized)
struct WebhookReliabilityTests {

  private func parseStatus(_ routeResponse: String) -> Int {
    guard let data = routeResponse.data(using: .utf8),
      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return 0 }
    return dict["status"] as? Int ?? 0
  }

  private func setUpConfiguredHost() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    mockConfig["sender_policy"] = "open"
    mockConfig["api_key"] = "re_test"
    mockConfig["from_email"] = "agent@d.com"
    SignedWebhook.installSecret()
  }

  // MARK: - Atomic claim

  @Test("Concurrent claims of the same svix-id grant exactly one winner")
  func atomicClaimUnderConcurrency() {
    setUpConfiguredHost()

    let claimedCount = ManagedAtomic(0)
    DispatchQueue.concurrentPerform(iterations: 16) { _ in
      if case .claimed = DatabaseManager.claimSvixId("msg_race_001") {
        claimedCount.increment()
      }
    }
    #expect(claimedCount.value == 1, "exactly one concurrent delivery may win the claim")
  }

  @Test("In-flight claim returns 503 so Svix retries instead of double-processing")
  func inFlightClaimAsksForRetry() {
    setUpConfiguredHost()
    #expect(DatabaseManager.claimSvixId("msg_inflight") == .claimed)

    let body =
      "{\"type\":\"email.received\",\"data\":{\"email_id\":\"e-if\",\"from\":\"a@a.com\",\"to\":[\"agent@d.com\"]}}"
    let result = SignedWebhook.send(ctx: PluginContext(), body: body, svixId: "msg_inflight")
    #expect(result.status == 503)
    #expect(mockDispatchCalls.isEmpty)
  }

  @Test("Stale in-flight claim (lease expired) is taken over by a redelivery")
  func staleClaimTakeover() {
    setUpConfiguredHost()
    #expect(DatabaseManager.claimSvixId("msg_stale") == .claimed)
    // Age the claim past the lease.
    mockStateLock.lock()
    mockSvixIds["msg_stale"] = (
      status: "processing",
      createdAt: Int(Date().timeIntervalSince1970) - DatabaseManager.svixClaimLeaseSeconds - 10
    )
    mockStateLock.unlock()

    #expect(DatabaseManager.claimSvixId("msg_stale") == .claimed)
  }

  // MARK: - Claim completed only after successful processing

  @Test("Transient processing failure returns retryable 503 and redelivery succeeds")
  func transientFailureAllowsRedelivery() {
    setUpConfiguredHost()

    let body =
      "{\"type\":\"email.received\",\"data\":{\"email_id\":\"e-retry\",\"from\":\"a@a.com\",\"to\":[\"agent@d.com\"],\"message_id\":\"<m-retry>\"}}"

    // First delivery: the receive-API fetch fails (no queued response -> 500),
    // so the handler must NOT ack with 200 and must NOT burn the svix-id.
    let first = SignedWebhook.send(ctx: PluginContext(), body: body, svixId: "msg_retry_001")
    #expect(first.status == 503, "transient failure must surface as retryable 5xx")
    #expect(mockDispatchCalls.isEmpty)

    // Redelivery with the same svix-id: fetch succeeds now, processing completes.
    MockHost.pushReceivedEmailResponse(
      emailId: "e-retry", from: "a@a.com", to: ["agent@d.com"],
      subject: "retry", text: "hello", html: nil, messageId: "<m-retry>")
    let second = SignedWebhook.send(ctx: PluginContext(), body: body, svixId: "msg_retry_001")
    #expect(second.status == 200)
    #expect(mockDispatchCalls.count == 1, "redelivery after transient failure must process")

    // Third delivery is a true duplicate of the completed one.
    let third = SignedWebhook.send(ctx: PluginContext(), body: body, svixId: "msg_retry_001")
    #expect(third.status == 200)
    #expect(mockDispatchCalls.count == 1, "completed delivery must not re-process")
  }

  // MARK: - Route validation

  private func route(
    _ routeId: String, method: String, body: String? = nil,
    headers: [String: String]? = nil
  ) -> Int {
    var req: [String: Any] = ["route_id": routeId, "method": method, "path": "/\(routeId)"]
    if let body { req["body"] = body }
    if let headers { req["headers"] = headers }
    let result = handleRoute(ctx: PluginContext(), requestJSON: makeJSONString(req) ?? "{}")
    return parseStatus(result)
  }

  @Test("Webhook route rejects non-POST methods with 405")
  func webhookRejectsWrongMethod() {
    setUpConfiguredHost()
    #expect(route("webhook", method: "GET", body: "{}") == 405)
    #expect(route("webhook", method: "DELETE", body: "{}") == 405)
    #expect(mockDispatchCalls.isEmpty)
  }

  @Test("Health rejects POST, reset_webhook rejects GET")
  func ownerRoutesRejectWrongMethod() {
    setUpConfiguredHost()
    #expect(route("health", method: "POST") == 405)
    #expect(route("reset_webhook", method: "GET") == 405)
  }

  @Test("Webhook route rejects non-JSON content type with 415")
  func webhookRejectsWrongContentType() {
    setUpConfiguredHost()
    let status = route(
      "webhook", method: "POST", body: "{\"type\":\"email.received\"}",
      headers: ["content-type": "text/plain"])
    #expect(status == 415)
    #expect(mockDispatchCalls.isEmpty)
  }

  @Test("Webhook route rejects oversized bodies with 413")
  func webhookRejectsOversizedBody() {
    setUpConfiguredHost()
    let huge = String(repeating: "a", count: maxRouteBodyBytes + 1)
    let status = route(
      "webhook", method: "POST", body: huge,
      headers: ["content-type": "application/json"])
    #expect(status == 413)
    #expect(mockDispatchCalls.isEmpty)
  }
}
}

// MARK: - Tiny lock-based atomic counter (avoids an Atomics dependency)

private final class ManagedAtomic: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Int

  init(_ value: Int) { self.storage = value }

  func increment() {
    lock.lock()
    storage += 1
    lock.unlock()
  }

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}
