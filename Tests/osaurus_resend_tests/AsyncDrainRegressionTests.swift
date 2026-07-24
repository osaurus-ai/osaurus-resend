import Foundation
import Testing

@testable import osaurus_resend

extension AllResendTests {
  /// Wave 2 regression coverage for the claim-then-async-drain conversion:
  ///   * durable-first: the payload is persisted atomically with the claim
  ///     BEFORE the 200 goes out, and a store failure yields 503,
  ///   * enqueue-then-drain ordering: the webhook answers 200 before the
  ///     worker processes; the drain lane is FIFO,
  ///   * worker crash simulation: a `processing` claim whose lease expired
  ///     is reprocessed from the stored payload by reconciliation,
  ///   * no double-dispatch under concurrent webhook redelivery +
  ///     reconciliation racing for the same stale claim,
  ///   * `/health` reports queue depth, oldest pending claim age, last
  ///     processing error, and webhook registration status.
  ///
  /// Unlike the synchronous suites, most of these tests run the worker for
  /// real (`executeInlineForTesting = false`) and synchronize via
  /// `ctx.webhookWorker.waitUntilIdle()`.
  @Suite("Async Drain", .serialized)
  struct AsyncDrainRegressionTests {

    private func setUpConfiguredHost() {
      MockHost.setUp()
      DatabaseManager.initSchema()
      mockConfig["sender_policy"] = "open"
      mockConfig["api_key"] = "re_test"
      mockConfig["from_email"] = "agent@d.com"
      SignedWebhook.installSecret()
    }

    private func ageClaim(_ svixId: String, extraSeconds: Int = 10) {
      mockStateLock.lock()
      if let entry = mockSvixIds[svixId] {
        mockSvixIds[svixId] = (
          status: entry.status,
          createdAt: Int(Date().timeIntervalSince1970)
            - DatabaseManager.svixClaimLeaseSeconds - extraSeconds,
          payload: entry.payload
        )
      }
      mockStateLock.unlock()
    }

    private func receivedBody(emailId: String) -> String {
      "{\"type\":\"email.received\",\"data\":{\"email_id\":\"\(emailId)\","
        + "\"from\":\"a@a.com\",\"to\":[\"agent@d.com\"],\"message_id\":\"<\(emailId)>\"}}"
    }

    private func deliveredBody(emailId: String) -> String {
      "{\"type\":\"email.delivered\",\"data\":{\"email_id\":\"\(emailId)\"}}"
    }

    // MARK: - Durable-first

    @Test("payload is durable (with routing context) before the worker runs")
    func payloadIsDurableBeforeTheWorkerRuns() {
      setUpConfiguredHost()
      WebhookWorkQueue.executeInlineForTesting = false
      defer { WebhookWorkQueue.executeInlineForTesting = true }
      let ctx = PluginContext()

      // Freeze the drain lane so the enqueue happens but the drain can't:
      // whatever the mock DB holds after `handleRoute` returns is exactly
      // what a crash immediately after the 200 would leave behind.
      let gate = DispatchSemaphore(value: 0)
      ctx.webhookWorker.enqueue { gate.wait() }

      let result = SignedWebhook.send(
        ctx: ctx, body: deliveredBody(emailId: "e-durable"), svixId: "msg_durable")
      #expect(result.status == 200)
      #expect(mockEmailEvents.isEmpty, "the worker is gated; nothing may have processed yet")

      mockStateLock.lock()
      let row = mockSvixIds["msg_durable"]
      mockStateLock.unlock()
      #expect(row?.status == "processing")
      let stored = row?.payload.flatMap(StoredWebhookPayload.decode)
      #expect(
        stored?.body.contains("e-durable") == true,
        "the raw signed body must be persisted with the claim")

      gate.signal()
      #expect(ctx.webhookWorker.waitUntilIdle())
    }

    @Test("store failure yields 503, not an ack (wave-1 contract for the enqueue step)")
    func storeUnavailableYields503NotAck() {
      setUpConfiguredHost()
      let ctx = PluginContext()
      mockStateLock.lock()
      mockFailSvixInserts = true
      mockStateLock.unlock()
      defer {
        mockStateLock.lock()
        mockFailSvixInserts = false
        mockStateLock.unlock()
      }

      let result = SignedWebhook.send(
        ctx: ctx, body: deliveredBody(emailId: "e-nostore"), svixId: "msg_nostore")
      #expect(
        result.status == 503,
        "a delivery that could not be durably enqueued must not be acked")
      #expect(mockEmailEvents.isEmpty)
    }

    // MARK: - Enqueue-then-drain ordering

    @Test("webhook acks before the worker processes; the drain completes the claim")
    func webhookAcksBeforeWorkerProcesses() {
      setUpConfiguredHost()
      WebhookWorkQueue.executeInlineForTesting = false
      defer { WebhookWorkQueue.executeInlineForTesting = true }
      let ctx = PluginContext()

      let gate = DispatchSemaphore(value: 0)
      ctx.webhookWorker.enqueue { gate.wait() }

      let result = SignedWebhook.send(
        ctx: ctx, body: deliveredBody(emailId: "e-order"), svixId: "msg_order")
      #expect(result.status == 200)
      #expect(mockEmailEvents.isEmpty, "200 must be returned before processing, not after")

      gate.signal()
      #expect(ctx.webhookWorker.waitUntilIdle())
      #expect(mockEmailEvents.map(\.emailId) == ["e-order"])
      mockStateLock.lock()
      let status = mockSvixIds["msg_order"]?.status
      mockStateLock.unlock()
      #expect(status == "completed", "the drained claim must be marked completed")
    }

    @Test("the drain lane processes deliveries in FIFO order")
    func drainLaneIsFIFO() {
      setUpConfiguredHost()
      WebhookWorkQueue.executeInlineForTesting = false
      defer { WebhookWorkQueue.executeInlineForTesting = true }
      let ctx = PluginContext()

      let gate = DispatchSemaphore(value: 0)
      ctx.webhookWorker.enqueue { gate.wait() }

      for id in ["e-fifo-1", "e-fifo-2", "e-fifo-3"] {
        let result = SignedWebhook.send(ctx: ctx, body: deliveredBody(emailId: id))
        #expect(result.status == 200)
      }
      gate.signal()
      #expect(ctx.webhookWorker.waitUntilIdle())
      #expect(
        mockEmailEvents.map(\.emailId) == ["e-fifo-1", "e-fifo-2", "e-fifo-3"],
        "the drain lane must preserve arrival order")
    }

    // MARK: - Worker crash simulation → reconciliation reprocesses

    @Test("reconciliation reprocesses an expired processing claim from its stored payload")
    func reconciliationReprocessesExpiredClaim() {
      setUpConfiguredHost()
      WebhookWorkQueue.executeInlineForTesting = false
      defer { WebhookWorkQueue.executeInlineForTesting = true }
      let ctx = PluginContext()

      // A claim with a stored payload whose worker "crashed": still
      // `processing`, lease expired.
      let stored = StoredWebhookPayload(
        body: deliveredBody(emailId: "e-crash"), agent_address: nil)
      #expect(DatabaseManager.claimSvixId("msg_crash", payload: stored.encoded()) == .claimed)
      ageClaim("msg_crash")

      triggerSvixReconciliation(ctx: ctx)
      #expect(ctx.webhookWorker.waitUntilIdle())

      #expect(
        mockEmailEvents.map(\.emailId) == ["e-crash"],
        "reconciliation must reprocess the stored payload")
      mockStateLock.lock()
      let status = mockSvixIds["msg_crash"]?.status
      mockStateLock.unlock()
      #expect(status == "completed")
    }

    @Test("reconciliation skips in-lease and completed claims")
    func reconciliationSkipsInLeaseAndCompleted() {
      setUpConfiguredHost()
      WebhookWorkQueue.executeInlineForTesting = false
      defer { WebhookWorkQueue.executeInlineForTesting = true }
      let ctx = PluginContext()

      let storedA = StoredWebhookPayload(
        body: deliveredBody(emailId: "e-busy"), agent_address: nil)
      #expect(DatabaseManager.claimSvixId("msg_busy", payload: storedA.encoded()) == .claimed)

      let storedB = StoredWebhookPayload(
        body: deliveredBody(emailId: "e-done"), agent_address: nil)
      #expect(DatabaseManager.claimSvixId("msg_done", payload: storedB.encoded()) == .claimed)
      DatabaseManager.completeSvixId("msg_done")

      triggerSvixReconciliation(ctx: ctx)
      #expect(ctx.webhookWorker.waitUntilIdle())
      #expect(
        mockEmailEvents.isEmpty,
        "neither in-lease nor completed claims may be reprocessed")
    }

    // MARK: - No double-dispatch: concurrent webhook + reconciliation

    @Test("concurrent redelivery and reconciliation dispatch a stale claim exactly once")
    func concurrentRedeliveryAndReconciliationDispatchOnce() {
      setUpConfiguredHost()
      WebhookWorkQueue.executeInlineForTesting = false
      defer { WebhookWorkQueue.executeInlineForTesting = true }
      let ctx = PluginContext()

      let body = receivedBody(emailId: "e-race")
      let stored = StoredWebhookPayload(body: body, agent_address: nil)
      #expect(DatabaseManager.claimSvixId("msg_race", payload: stored.encoded()) == .claimed)
      ageClaim("msg_race")

      // The winner performs one receive-API fetch + dispatch.
      MockHost.pushReceivedEmailResponse(
        emailId: "e-race", from: "a@a.com", to: ["agent@d.com"],
        subject: "race", text: "hello", html: nil, messageId: "<e-race>")

      let requestJSON = SignedWebhook.requestJSON(body: body, svixId: "msg_race")
      DispatchQueue.concurrentPerform(iterations: 16) { i in
        if i % 2 == 0 {
          _ = handleRoute(ctx: ctx, requestJSON: requestJSON)
        } else {
          reconcileStaleSvixClaims(ctx: ctx)
        }
      }
      #expect(ctx.webhookWorker.waitUntilIdle())

      #expect(
        mockDispatchCalls.count == 1,
        "exactly one of the racing paths may win the stale claim")
      mockStateLock.lock()
      let status = mockSvixIds["msg_race"]?.status
      mockStateLock.unlock()
      #expect(status == "completed")
    }

    // MARK: - /health

    @Test("/health reports queue depth, oldest claim age, last error, and registration")
    func healthReportsAsyncDrainState() throws {
      setUpConfiguredHost()
      let ctx = PluginContext()
      mockConfig["webhook_registered"] = "true"

      // Two pending claims, one well past the lease; plus a recorded
      // worker failure.
      let stored = StoredWebhookPayload(
        body: deliveredBody(emailId: "e-h1"), agent_address: nil)
      #expect(DatabaseManager.claimSvixId("msg_h1", payload: stored.encoded()) == .claimed)
      #expect(DatabaseManager.claimSvixId("msg_h2", payload: stored.encoded()) == .claimed)
      ageClaim("msg_h1", extraSeconds: 100)
      ctx.recordProcessingError("svix-id msg_h1: dispatch failed")

      let req: [String: Any] = ["route_id": "health", "method": "GET", "path": "/health"]
      let response = handleRoute(ctx: ctx, requestJSON: makeJSONString(req) ?? "{}")
      let outer = try #require(
        try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
      #expect(outer["status"] as? Int == 200)
      let payload = try #require(
        try JSONSerialization.jsonObject(
          with: Data((outer["body"] as? String ?? "{}").utf8)) as? [String: Any])

      #expect(payload["webhook_registered"] as? Bool == true)
      #expect(payload["queue_depth"] as? Int == 2)
      let age = try #require(payload["oldest_pending_claim_age_seconds"] as? Int)
      #expect(age >= DatabaseManager.svixClaimLeaseSeconds + 100)
      #expect(payload["last_processing_error"] as? String == "svix-id msg_h1: dispatch failed")
      #expect(payload["last_processing_error_at"] as? Int != nil)
      #expect(
        payload["ok"] as? Bool == false,
        "a lease-expired pending claim means processing is stuck; ok must be false")

      // A healthy install: registered, empty queue, no errors.
      mockStateLock.lock()
      mockSvixIds = [:]
      mockStateLock.unlock()
      let healthyCtx = PluginContext()
      let response2 = handleRoute(ctx: healthyCtx, requestJSON: makeJSONString(req) ?? "{}")
      let outer2 = try #require(
        try JSONSerialization.jsonObject(with: Data(response2.utf8)) as? [String: Any])
      let payload2 = try #require(
        try JSONSerialization.jsonObject(
          with: Data((outer2["body"] as? String ?? "{}").utf8)) as? [String: Any])
      #expect(payload2["ok"] as? Bool == true)
      #expect(payload2["queue_depth"] as? Int == 0)
      #expect(payload2["last_processing_error"] is NSNull)
    }
  }
}
