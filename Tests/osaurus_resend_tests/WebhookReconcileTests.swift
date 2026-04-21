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
  private func pushListResponse(
    _ webhooks: [(id: String, endpoint: String)], hasMore: Bool = false
  ) {
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
      status: 200, body: ["object": "list", "has_more": hasMore, "data": data])
  }

  /// Pushes the standard create-webhook 200 response.
  private func pushCreateOkResponse(id: String = "wh-new", secret: String = "whsec_test") {
    MockHost.pushHTTPResponse(status: 200, body: ["id": id, "signing_secret": secret])
  }

  /// Pushes a 200 OK delete response.
  private func pushDeleteOkResponse() {
    MockHost.pushHTTPResponse(status: 200, body: [:])
  }

  /// Returns the parsed (method, path) for each recorded HTTP request.
  /// Path includes any query string so callers can assert on pagination params.
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

  @Test("Creates a fresh webhook when account has no existing osaurus webhook")
  func createsWhenNoMatches() {
    MockHost.setUp()
    mockConfig["api_key"] = "re_test"

    pushListResponse([])
    pushCreateOkResponse(id: "new-webhook-1", secret: "whsec_abc")

    triggerReconcile(tunnelURL: "https://tunnel.example.com")

    let calls = parsedRequests()
    #expect(calls.count == 2)
    #expect(calls[0].method == "GET" && calls[0].path.hasPrefix("/webhooks"))
    #expect(calls[1].method == "POST" && calls[1].path == "/webhooks")
    #expect(mockConfig["webhook_id"] == "new-webhook-1")
    #expect(mockConfig["signing_secret"] == "whsec_abc")
    #expect(mockConfig["webhook_registered"] == "true")
  }

  @Test("Always wipes existing matching webhooks then creates a single fresh one")
  func wipesAndRecreatesEvenOnMatch() {
    MockHost.setUp()
    mockConfig["api_key"] = "re_test"

    let desiredURL = "https://tunnel.example.com/plugins/osaurus.resend/webhook"
    pushListResponse([(id: "existing-1", endpoint: desiredURL)])
    pushDeleteOkResponse()
    pushCreateOkResponse(id: "wh-new", secret: "whsec_new")

    triggerReconcile(tunnelURL: "https://tunnel.example.com")

    let methodPaths = parsedRequests().map { "\($0.method) \($0.path)" }
    #expect(methodPaths.contains(where: { $0.hasPrefix("GET /webhooks") }))
    #expect(methodPaths.contains("DELETE /webhooks/existing-1"))
    #expect(methodPaths.contains("POST /webhooks"))
    #expect(mockConfig["webhook_id"] == "wh-new")
    #expect(mockConfig["signing_secret"] == "whsec_new")
    #expect(mockConfig["webhook_registered"] == "true")
  }

  @Test("Deletes every matching webhook before creating one")
  func deletesAllDuplicates() {
    MockHost.setUp()
    mockConfig["api_key"] = "re_test"

    let desiredURL = "https://tunnel.example.com/plugins/osaurus.resend/webhook"
    let staleURL = "https://old-tunnel.example.com/plugins/osaurus.resend/webhook"

    pushListResponse([
      (id: "wh-stale-1", endpoint: staleURL),
      (id: "wh-existing", endpoint: desiredURL),
      (id: "wh-stale-2", endpoint: staleURL),
    ])
    pushDeleteOkResponse()
    pushDeleteOkResponse()
    pushDeleteOkResponse()
    pushCreateOkResponse(id: "wh-final")

    triggerReconcile(tunnelURL: "https://tunnel.example.com")

    let methodPaths = parsedRequests().map { "\($0.method) \($0.path)" }
    #expect(methodPaths.contains("DELETE /webhooks/wh-stale-1"))
    #expect(methodPaths.contains("DELETE /webhooks/wh-existing"))
    #expect(methodPaths.contains("DELETE /webhooks/wh-stale-2"))
    #expect(methodPaths.filter { $0.hasPrefix("POST") }.count == 1)
    #expect(mockConfig["webhook_id"] == "wh-final")
  }

  @Test("Does NOT touch webhooks belonging to other plugins/apps")
  func ignoresOtherWebhooks() {
    MockHost.setUp()
    mockConfig["api_key"] = "re_test"

    pushListResponse([
      (id: "other-1", endpoint: "https://example.com/some/other/handler"),
      (id: "other-2", endpoint: "https://example.com/plugins/different.plugin/webhook"),
    ])
    pushCreateOkResponse(id: "new-webhook")

    triggerReconcile(tunnelURL: "https://tunnel.example.com")

    let methodPaths = parsedRequests().map { "\($0.method) \($0.path)" }
    #expect(!methodPaths.contains(where: { $0.hasPrefix("DELETE") }))
    #expect(methodPaths.contains("POST /webhooks"))
    #expect(mockConfig["webhook_id"] == "new-webhook")
  }

  @Test("Aborts and clears registration flag when listing fails")
  func abortsOnListFailure() {
    MockHost.setUp()
    mockConfig["api_key"] = "re_test"

    // Use 422 so the retry loop doesn't kick in (5xx would retry up to 3 more times).
    MockHost.pushHTTPResponse(status: 422, body: ["message": "invalid"])

    triggerReconcile(tunnelURL: "https://tunnel.example.com")

    let calls = parsedRequests()
    #expect(calls.count == 1, "Should not proceed past the failed list call")
    #expect(calls[0].method == "GET")
    #expect(mockConfig["webhook_id"] == nil)
    #expect(mockConfig["webhook_registered"] == nil)
  }

  @Test("Subscribes to the full lifecycle event set on create")
  func subscribesToLifecycleEvents() {
    MockHost.setUp()
    mockConfig["api_key"] = "re_test"

    pushListResponse([])
    pushCreateOkResponse(id: "wh-events")

    triggerReconcile(tunnelURL: "https://tunnel.example.com")

    // Find the POST and inspect its body.
    let postBody = mockHTTPRequests.compactMap { raw -> [String: Any]? in
      guard let data = raw.data(using: .utf8),
        let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        (dict["method"] as? String) == "POST",
        let bodyStr = dict["body"] as? String,
        let bodyData = bodyStr.data(using: .utf8),
        let body = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
      else { return nil }
      return body
    }.first

    let events = postBody?["events"] as? [String] ?? []
    #expect(events.contains("email.received"))
    #expect(events.contains("email.bounced"))
    #expect(events.contains("email.complained"))
    #expect(events.contains("email.failed"))
    #expect(events.contains("email.delivered"))
  }

  @Test("Pagination: combines results across multiple pages")
  func paginatesList() {
    MockHost.setUp()
    mockConfig["api_key"] = "re_test"

    // First page: 100 unrelated webhooks (signals more pages exist).
    var page1: [(id: String, endpoint: String)] = []
    for i in 0..<100 {
      page1.append(
        (id: "unrelated-\(i)", endpoint: "https://other.example.com/handler/\(i)"))
    }
    pushListResponse(page1, hasMore: true)

    // Second page: contains our match.
    let oursURL = "https://tunnel.example.com/plugins/osaurus.resend/webhook"
    pushListResponse([(id: "our-page2", endpoint: oursURL)], hasMore: false)

    pushDeleteOkResponse()
    pushCreateOkResponse(id: "wh-fresh")

    triggerReconcile(tunnelURL: "https://tunnel.example.com")

    let methodPaths = parsedRequests().map { "\($0.method) \($0.path)" }
    // Both pages must have been fetched.
    #expect(methodPaths.contains(where: { $0.contains("offset=0") }))
    #expect(methodPaths.contains(where: { $0.contains("offset=100") }))
    // The match found on page 2 must have been deleted, and we must NOT have
    // touched the unrelated webhooks from page 1.
    #expect(methodPaths.contains("DELETE /webhooks/our-page2"))
    #expect(!methodPaths.contains(where: { $0.hasPrefix("DELETE /webhooks/unrelated-") }))
    #expect(mockConfig["webhook_id"] == "wh-fresh")
  }

  @Test("Tunnel URL change re-runs nuke-and-create cleanly")
  func tunnelChangeDoesNotLeak() {
    MockHost.setUp()
    mockConfig["api_key"] = "re_test"

    let tunnel1 = "https://t1.example.com"
    let url1 = "\(tunnel1)/plugins/osaurus.resend/webhook"
    let tunnel2 = "https://t2.example.com"

    // First setup: nothing exists, create.
    pushListResponse([])
    pushCreateOkResponse(id: "wh-001", secret: "whsec_1")

    // Second setup (tunnel URL changed): list returns the existing one,
    // delete it, then create a fresh one with a fresh secret.
    pushListResponse([(id: "wh-001", endpoint: url1)])
    pushDeleteOkResponse()
    pushCreateOkResponse(id: "wh-002", secret: "whsec_2")

    let ctx = PluginContext()
    triggerReconcile(tunnelURL: tunnel1, ctx: ctx)
    triggerReconcile(tunnelURL: tunnel2, ctx: ctx)

    let methodPaths = parsedRequests().map { "\($0.method) \($0.path)" }
    #expect(methodPaths.contains("DELETE /webhooks/wh-001"))
    #expect(methodPaths.filter { $0.hasPrefix("POST") }.count == 2)
    #expect(mockConfig["webhook_id"] == "wh-002")
    #expect(mockConfig["signing_secret"] == "whsec_2")
  }

  @Test("initPlugin auto-reconciles when api_key + tunnel_url are already configured")
  func initAutoReconciles() {
    MockHost.setUp()
    // Persisted config from a previous run.
    mockConfig["api_key"] = "re_test"
    mockConfig["tunnel_url"] = "https://tunnel.example.com"
    mockConfig["webhook_id"] = "wh-leftover"
    mockConfig["signing_secret"] = "whsec_old"
    mockConfig["webhook_registered"] = "true"

    // Resend currently has two stale webhooks of ours. Init must wipe both
    // before creating a single fresh one, regardless of any local config.
    let oursURL = "https://tunnel.example.com/plugins/osaurus.resend/webhook"
    pushListResponse([
      (id: "wh-leftover", endpoint: oursURL),
      (id: "wh-other-stale", endpoint: oursURL),
    ])
    pushDeleteOkResponse()
    pushDeleteOkResponse()
    pushCreateOkResponse(id: "wh-init-fresh", secret: "whsec_init_fresh")

    initPlugin(PluginContext())

    let methodPaths = parsedRequests().map { "\($0.method) \($0.path)" }
    #expect(methodPaths.contains("DELETE /webhooks/wh-leftover"))
    #expect(methodPaths.contains("DELETE /webhooks/wh-other-stale"))
    #expect(methodPaths.filter { $0.hasPrefix("POST") }.count == 1)
    #expect(mockConfig["webhook_id"] == "wh-init-fresh")
    #expect(mockConfig["signing_secret"] == "whsec_init_fresh")
    #expect(mockConfig["webhook_registered"] == "true")
  }

  @Test("initPlugin is a no-op when api_key or tunnel_url is missing")
  func initNoopWhenIncomplete() {
    MockHost.setUp()
    mockConfig["api_key"] = "re_test"
    // No tunnel_url.

    initPlugin(PluginContext())

    #expect(parsedRequests().isEmpty, "Should not call Resend without tunnel_url")
    #expect(mockConfig["webhook_registered"] == nil)
  }

  @Test("Create failure leaves webhook_registered cleared")
  func createFailureClearsFlags() {
    MockHost.setUp()
    mockConfig["api_key"] = "re_test"

    pushListResponse([])
    // 422 = not retryable, so we burn one POST and stop.
    MockHost.pushHTTPResponse(status: 422, body: ["message": "validation error"])

    triggerReconcile(tunnelURL: "https://tunnel.example.com")

    #expect(mockConfig["webhook_id"] == nil)
    #expect(mockConfig["signing_secret"] == nil)
    #expect(mockConfig["webhook_registered"] == nil)
  }
}
