import Foundation
import Testing

@testable import osaurus_resend

@Suite("Webhook Reconciliation", .serialized)
struct WebhookReconcileTests {

  // MARK: - Helpers

  /// Triggers the reconcile path by simulating a tunnel_url change after the api_key
  /// is already configured. This goes through onConfigChanged -> setupWebhook.
  private func triggerReconcile(tunnelURL: String, ctx: PluginContext = PluginContext()) {
    onConfigChanged(ctx: ctx, key: "tunnel_url", value: tunnelURL)
  }

  /// Helper to push a `GET /webhooks` list response.
  private func pushListResponse(_ webhooks: [(id: String, endpoint: String)]) {
    let data: [[String: Any]] = webhooks.map { w in
      [
        "id": w.id,
        "endpoint": w.endpoint,
        "events": ["email.received"],
        "status": "enabled",
        "created_at": "2026-01-01T00:00:00.000Z",
      ]
    }
    MockHost.pushHTTPResponse(
      status: 200, body: ["object": "list", "has_more": false, "data": data])
  }

  /// Returns the parsed (method, path) for each recorded HTTP request.
  private func parsedRequests() -> [(method: String, path: String)] {
    mockHTTPRequests.compactMap { raw -> (String, String)? in
      guard let data = raw.data(using: .utf8),
        let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let method = dict["method"] as? String,
        let url = dict["url"] as? String
      else { return nil }
      let path = url.replacingOccurrences(of: "https://api.resend.com", with: "")
      return (method, path)
    }
  }

  // MARK: - Tests

  @Test("Reconcile creates a new webhook when none exist")
  func reconcileCreatesWhenNoMatches() {
    MockHost.setUp()
    mockConfig["api_key"] = "re_test"

    pushListResponse([])
    MockHost.pushHTTPResponse(
      status: 200, body: ["id": "new-webhook-1", "signing_secret": "whsec_abc"])

    triggerReconcile(tunnelURL: "https://tunnel.example.com")

    let calls = parsedRequests()
    #expect(calls.count == 2)
    #expect(calls[0].method == "GET" && calls[0].path == "/webhooks")
    #expect(calls[1].method == "POST" && calls[1].path == "/webhooks")
    #expect(mockConfig["webhook_id"] == "new-webhook-1")
    #expect(mockConfig["signing_secret"] == "whsec_abc")
    #expect(mockConfig["webhook_registered"] == "true")
  }

  @Test("Reconcile keeps existing webhook when endpoint already matches")
  func reconcileKeepsMatchingWebhook() {
    MockHost.setUp()
    mockConfig["api_key"] = "re_test"

    let desiredURL = "https://tunnel.example.com/plugins/osaurus.resend/webhook"
    pushListResponse([(id: "existing-1", endpoint: desiredURL)])

    triggerReconcile(tunnelURL: "https://tunnel.example.com")

    let calls = parsedRequests()
    #expect(calls.count == 1, "Only the list call should be made")
    #expect(calls[0].method == "GET")
    #expect(mockConfig["webhook_id"] == "existing-1")
    #expect(mockConfig["webhook_registered"] == "true")
  }

  @Test("Reconcile patches existing webhook when endpoint differs")
  func reconcilePatchesWhenEndpointDiffers() {
    MockHost.setUp()
    mockConfig["api_key"] = "re_test"

    let oldURL = "https://old-tunnel.example.com/plugins/osaurus.resend/webhook"
    pushListResponse([(id: "existing-1", endpoint: oldURL)])
    MockHost.pushHTTPResponse(status: 200, body: ["id": "existing-1"])

    triggerReconcile(tunnelURL: "https://new-tunnel.example.com")

    let calls = parsedRequests()
    #expect(calls.count == 2)
    #expect(calls[0].method == "GET")
    #expect(calls[1].method == "PATCH" && calls[1].path == "/webhooks/existing-1")
    #expect(mockConfig["webhook_id"] == "existing-1")
    #expect(mockConfig["webhook_registered"] == "true")
  }

  @Test("Reconcile deletes duplicates and keeps one")
  func reconcileDeletesDuplicates() {
    MockHost.setUp()
    mockConfig["api_key"] = "re_test"

    let desiredURL = "https://tunnel.example.com/plugins/osaurus.resend/webhook"
    let staleURL = "https://old-tunnel.example.com/plugins/osaurus.resend/webhook"

    pushListResponse([
      (id: "wh-stale-1", endpoint: staleURL),
      (id: "wh-keeper", endpoint: desiredURL),
      (id: "wh-stale-2", endpoint: staleURL),
    ])
    MockHost.pushHTTPResponse(status: 200, body: [:])
    MockHost.pushHTTPResponse(status: 200, body: [:])

    triggerReconcile(tunnelURL: "https://tunnel.example.com")

    let calls = parsedRequests()
    let methodPaths = calls.map { "\($0.method) \($0.path)" }
    #expect(calls.count == 3)
    #expect(methodPaths.contains("GET /webhooks"))
    #expect(methodPaths.contains("DELETE /webhooks/wh-stale-1"))
    #expect(methodPaths.contains("DELETE /webhooks/wh-stale-2"))
    #expect(!methodPaths.contains("DELETE /webhooks/wh-keeper"))
    #expect(!methodPaths.contains(where: { $0.hasPrefix("POST") }))
    #expect(!methodPaths.contains(where: { $0.hasPrefix("PATCH") }))
    #expect(mockConfig["webhook_id"] == "wh-keeper")
  }

  @Test("Reconcile ignores webhooks for other plugins/endpoints")
  func reconcileIgnoresOtherWebhooks() {
    MockHost.setUp()
    mockConfig["api_key"] = "re_test"

    pushListResponse([
      (id: "other-1", endpoint: "https://example.com/some/other/handler"),
      (id: "other-2", endpoint: "https://example.com/plugins/different.plugin/webhook"),
    ])
    MockHost.pushHTTPResponse(
      status: 200, body: ["id": "new-webhook", "signing_secret": "whsec_xyz"])

    triggerReconcile(tunnelURL: "https://tunnel.example.com")

    let calls = parsedRequests()
    let methodPaths = calls.map { "\($0.method) \($0.path)" }
    #expect(methodPaths == ["GET /webhooks", "POST /webhooks"])
    #expect(!methodPaths.contains(where: { $0.hasPrefix("DELETE") }))
    #expect(mockConfig["webhook_id"] == "new-webhook")
  }

  @Test("Reconcile aborts cleanly when list fails")
  func reconcileAbortsOnListFailure() {
    MockHost.setUp()
    mockConfig["api_key"] = "re_test"

    MockHost.pushHTTPResponse(status: 500, body: ["message": "internal error"])

    triggerReconcile(tunnelURL: "https://tunnel.example.com")

    let calls = parsedRequests()
    #expect(calls.count == 1, "Should not proceed past the failed list call")
    #expect(calls[0].method == "GET")
    #expect(mockConfig["webhook_id"] == nil)
    #expect(mockConfig["webhook_registered"] == nil)
  }

  @Test("Tunnel URL change reconciles instead of leaking webhooks")
  func tunnelChangeDoesNotLeak() {
    MockHost.setUp()
    mockConfig["api_key"] = "re_test"

    let tunnel1 = "https://t1.example.com"
    let url1 = "\(tunnel1)/plugins/osaurus.resend/webhook"
    let tunnel2 = "https://t2.example.com"

    // First setup: nothing exists, create.
    pushListResponse([])
    MockHost.pushHTTPResponse(
      status: 200, body: ["id": "wh-001", "signing_secret": "whsec_1"])

    // Second setup (tunnel URL changed): list returns our existing one, patch updates.
    pushListResponse([(id: "wh-001", endpoint: url1)])
    MockHost.pushHTTPResponse(status: 200, body: ["id": "wh-001"])

    let ctx = PluginContext()
    triggerReconcile(tunnelURL: tunnel1, ctx: ctx)
    triggerReconcile(tunnelURL: tunnel2, ctx: ctx)

    let calls = parsedRequests()
    let methodPaths = calls.map { "\($0.method) \($0.path)" }
    #expect(
      methodPaths == [
        "GET /webhooks", "POST /webhooks",
        "GET /webhooks", "PATCH /webhooks/wh-001",
      ])
    #expect(mockConfig["webhook_id"] == "wh-001")
  }
}
