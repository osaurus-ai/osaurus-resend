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

  @Test("In-flight claim WITHOUT a stored payload returns 503 (provider retry is the only recovery)")
  func inFlightClaimWithoutPayloadAsksForRetry() {
    setUpConfiguredHost()
    // Claim without payload = pre-Wave-2 row (or a claim made outside the
    // webhook path). Reconciliation can't reprocess it, so the retry must
    // not be acked.
    #expect(DatabaseManager.claimSvixId("msg_inflight") == .claimed)

    let body =
      "{\"type\":\"email.received\",\"data\":{\"email_id\":\"e-if\",\"from\":\"a@a.com\",\"to\":[\"agent@d.com\"]}}"
    let result = SignedWebhook.send(ctx: PluginContext(), body: body, svixId: "msg_inflight")
    #expect(result.status == 503)
    #expect(mockDispatchCalls.isEmpty)
  }

  @Test("In-flight claim WITH a stored payload is acked 200 without double-processing")
  func inFlightClaimWithPayloadAcksWithoutProcessing() {
    setUpConfiguredHost()
    // Wave-2 claim: the payload rode along, so the delivery is durably
    // enqueued and a provider retry must be acked without re-enqueueing.
    let stored = StoredWebhookPayload(
      body: "{\"type\":\"email.received\",\"data\":{\"email_id\":\"e-if2\"}}",
      agent_address: nil)
    #expect(
      DatabaseManager.claimSvixId("msg_inflight2", payload: stored.encoded()) == .claimed)

    let body =
      "{\"type\":\"email.received\",\"data\":{\"email_id\":\"e-if2\",\"from\":\"a@a.com\",\"to\":[\"agent@d.com\"]}}"
    let result = SignedWebhook.send(ctx: PluginContext(), body: body, svixId: "msg_inflight2")
    #expect(result.status == 200)
    #expect(mockDispatchCalls.isEmpty, "an in-lease retry must not double-process")
  }

  @Test("Stale in-flight claim (lease expired) is taken over by a redelivery")
  func staleClaimTakeover() {
    setUpConfiguredHost()
    #expect(DatabaseManager.claimSvixId("msg_stale") == .claimed)
    // Age the claim past the lease.
    mockStateLock.lock()
    mockSvixIds["msg_stale"] = (
      status: "processing",
      createdAt: Int(Date().timeIntervalSince1970) - DatabaseManager.svixClaimLeaseSeconds - 10,
      payload: nil
    )
    mockStateLock.unlock()

    #expect(DatabaseManager.claimSvixId("msg_stale") == .claimed)
  }

  // MARK: - Claim completed only after successful processing

  @Test("Transient processing failure leaves the claim resumable; lease takeover reprocesses")
  func transientFailureLeavesClaimResumable() {
    setUpConfiguredHost()
    let ctx = PluginContext()

    let body =
      "{\"type\":\"email.received\",\"data\":{\"email_id\":\"e-retry\",\"from\":\"a@a.com\",\"to\":[\"agent@d.com\"],\"message_id\":\"<m-retry>\"}}"

    // First delivery: the receive-API fetch fails (no queued response -> 500).
    // Wave 2 contract: the 200 already reflects the durable enqueue; the
    // worker's failure leaves the claim `processing` (payload intact) so
    // reconciliation reprocesses it after the lease expires.
    let first = SignedWebhook.send(ctx: ctx, body: body, svixId: "msg_retry_001")
    #expect(first.status == 200, "the durably enqueued delivery must be acked")
    #expect(mockDispatchCalls.isEmpty, "the fetch failed, nothing may dispatch")
    #expect(ctx.lastProcessingError() != nil, "worker failure must be recorded for /health")

    // Redelivery while the failed claim is inside its lease: acked without
    // re-processing (the payload is already durably queued).
    let inLease = SignedWebhook.send(ctx: ctx, body: body, svixId: "msg_retry_001")
    #expect(inLease.status == 200)
    #expect(mockDispatchCalls.isEmpty, "an in-lease retry must not re-enqueue")

    // Age the claim past the lease (crashed worker) and let a redelivery
    // take it over: fetch succeeds now, processing completes.
    mockStateLock.lock()
    if let entry = mockSvixIds["msg_retry_001"] {
      mockSvixIds["msg_retry_001"] = (
        status: entry.status,
        createdAt: Int(Date().timeIntervalSince1970) - DatabaseManager.svixClaimLeaseSeconds - 10,
        payload: entry.payload
      )
    }
    mockStateLock.unlock()
    MockHost.pushReceivedEmailResponse(
      emailId: "e-retry", from: "a@a.com", to: ["agent@d.com"],
      subject: "retry", text: "hello", html: nil, messageId: "<m-retry>")
    let second = SignedWebhook.send(ctx: ctx, body: body, svixId: "msg_retry_001")
    #expect(second.status == 200)
    #expect(mockDispatchCalls.count == 1, "lease takeover must re-process the delivery")

    // Third delivery is a true duplicate of the completed one.
    let third = SignedWebhook.send(ctx: ctx, body: body, svixId: "msg_retry_001")
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
