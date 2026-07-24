import Foundation

// MARK: - Background webhook worker (Wave 2 async drain)
//
// Wave 1 processed webhook events synchronously on the request path
// (receive-API fetch + dispatch, seconds of wall time under Svix's retry
// timer). Wave 2 moves to claim-then-async-drain:
//
//   1. request path: verify the Svix signature, parse, atomically claim
//      the svix-id WITH the raw payload persisted in the same statement
//      (durable-first), respond 200 immediately;
//   2. a background worker owned by the plugin context performs the
//      receive-API fetch + dispatch and marks the claim completed /
//      leaves it `processing` on transient failure;
//   3. startup and every incoming webhook trigger reconciliation: stale
//      `processing` claims (lease expired = crashed or failed worker) are
//      atomically re-claimed and reprocessed from the stored payload.
//
// The wave-1 503-on-transient contract is kept for the ENQUEUE step
// itself: a claim that cannot be durably recorded answers 503 so Svix's
// retry remains the recovery path for the write.
//
// Invariants:
//   * durable-first — the 200 only goes out after the claim+payload row
//     is durable (claim INSERT is atomic; `.claimed` implies persisted);
//   * at-least-once — a transient worker failure leaves the claim
//     `processing`; the lease expires and reconciliation reprocesses it;
//   * no double-processing — Svix retries while a claim is in-lease get
//     200 without enqueueing (the payload is already durably queued);
//     reconciliation re-claims through the same atomic lease-takeover
//     statement, so a concurrent redelivery and a reconciliation pass
//     can never both win the same delivery.

/// Plugin-wide work queue: one serial drain lane (events process in
/// arrival order, matching wave-1's implicit serialization through the
/// request path) plus a control lane for reconciliation, so a slow event
/// can't delay recovery scans. Uses real DispatchQueues rather than
/// Swift-concurrency tasks because the work is blocking (synchronous host
/// HTTP callbacks) and must not starve the cooperative pool.
final class WebhookWorkQueue: @unchecked Sendable {

  /// Test hook: when true, enqueued work runs inline on the caller's
  /// thread. This keeps the production code path identical (claim →
  /// enqueue → process → complete) while letting the existing synchronous
  /// test suites assert right after `handleRoute` returns. Async-drain
  /// regression tests flip this off and use `waitUntilIdle`.
  nonisolated(unsafe) static var executeInlineForTesting = false

  private let drainLane = DispatchQueue(label: "osaurus.resend.webhook-worker.drain")
  private let controlLane = DispatchQueue(label: "osaurus.resend.webhook-worker.control")
  private let group = DispatchGroup()

  /// Enqueues event processing on the serial drain lane (FIFO).
  func enqueue(_ work: @escaping @Sendable () -> Void) {
    if Self.executeInlineForTesting {
      work()
      return
    }
    group.enter()
    drainLane.async { [group] in
      defer { group.leave() }
      work()
    }
  }

  /// Enqueues housekeeping (reconciliation) off the drain lane.
  func enqueueControl(_ work: @escaping @Sendable () -> Void) {
    if Self.executeInlineForTesting {
      work()
      return
    }
    group.enter()
    controlLane.async { [group] in
      defer { group.leave() }
      work()
    }
  }

  /// Blocks until every enqueued unit of work (across both lanes) has
  /// finished, or the timeout passes. Test-only synchronization point.
  @discardableResult
  func waitUntilIdle(timeout: TimeInterval = 15) -> Bool {
    group.wait(timeout: .now() + timeout) == .success
  }
}

// MARK: - Durable payload envelope

/// What the claim row stores alongside the svix-id: the raw (already
/// signature-verified) webhook body plus the routing context the request
/// carried. Everything reprocessing needs, nothing it doesn't.
struct StoredWebhookPayload: Codable {
  let body: String
  let agent_address: String?

  func encoded() -> String? {
    guard let data = try? JSONEncoder().encode(self) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func decode(_ json: String) -> StoredWebhookPayload? {
    parseJSON(json, as: StoredWebhookPayload.self)
  }
}

// MARK: - Claimed-delivery processing (runs on the worker)

/// Drains one claimed delivery from its stored payload. Runs on the drain
/// lane. The caller must already OWN the claim (either the webhook handler
/// that just inserted it, or reconciliation after an atomic lease
/// takeover).
///
/// Completion contract: deterministic outcomes (dispatched, deliberately
/// dropped, unknown event type) complete the claim; transient failures
/// record the error for `/health` and leave the claim `processing` so
/// reconciliation reprocesses it after the lease expires.
func processClaimedDelivery(
  ctx: PluginContext, svixId: String, stored: StoredWebhookPayload
) {
  guard let event = parseJSON(stored.body, as: ResendWebhookEvent.self) else {
    // Can't happen for rows enqueued by the webhook handler (it parsed
    // the body before claiming) but a corrupt stored payload must not
    // wedge reconciliation forever.
    logWarn("worker: stored payload for svix-id=\(svixId) does not parse; completing")
    DatabaseManager.completeSvixId(svixId)
    return
  }

  switch processWebhookEvent(
    ctx: ctx, event: event, body: stored.body, agentAddress: stored.agent_address)
  {
  case .success:
    DatabaseManager.completeSvixId(svixId)
  case .transientFailure(let reason):
    // Leave the claim `processing`: the lease expires in
    // `svixClaimLeaseSeconds` and reconciliation reprocesses the stored
    // payload. Deleting it (the wave-1 release) would depend on Svix
    // redelivering an event we already acked with 200.
    ctx.recordProcessingError("svix-id \(svixId): \(reason)")
    logWarn(
      "worker: transient failure for svix-id=\(svixId) (\(reason)); "
        + "claim left for reconciliation after lease expiry")
  }
}

// MARK: - Reconciliation

/// Schedules a reconciliation pass on the control lane. Called from plugin
/// init and from every incoming webhook, so stalled claims recover as long
/// as the endpoint sees any traffic — no timer loop.
func triggerSvixReconciliation(ctx: PluginContext) {
  ctx.webhookWorker.enqueueControl {
    reconcileStaleSvixClaims(ctx: ctx)
  }
}

/// Re-drives stale `processing` claims (lease expired, payload available).
/// The re-claim happens ON the drain lane through the same atomic
/// lease-takeover statement the webhook path uses, so a concurrent Svix
/// redelivery and this pass can never both process the delivery.
func reconcileStaleSvixClaims(ctx: PluginContext) {
  let stale = DatabaseManager.staleIncompleteSvixClaims()
  guard !stale.isEmpty else { return }
  logInfo("reconcile: \(stale.count) stale svix claim(s) eligible for reprocessing")

  for row in stale {
    guard let stored = StoredWebhookPayload.decode(row.payload) else {
      logWarn("reconcile: unparseable payload for svix-id=\(row.svixId); completing")
      DatabaseManager.completeSvixId(row.svixId)
      continue
    }
    ctx.webhookWorker.enqueue {
      // Atomic takeover: only proceeds if the claim is STILL stale at
      // execution time (a concurrent redelivery may have re-claimed and
      // processed it while this closure sat in the lane).
      guard DatabaseManager.claimSvixId(row.svixId) == .claimed else { return }
      processClaimedDelivery(ctx: ctx, svixId: row.svixId, stored: stored)
    }
  }
}
