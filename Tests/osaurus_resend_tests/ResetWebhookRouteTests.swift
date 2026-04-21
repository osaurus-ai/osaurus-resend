import Foundation
import Testing

@testable import osaurus_resend

@Suite("Reset Webhook Route", .serialized)
struct ResetWebhookRouteTests {

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

  private func sendReset(ctx: PluginContext) -> (status: Int, body: String) {
    let routeReq: [String: Any] = [
      "route_id": "reset_webhook",
      "method": "POST",
      "path": "/reset_webhook",
    ]
    guard let reqJSON = makeJSONString(routeReq) else { return (0, "") }
    let result = handleRoute(ctx: ctx, requestJSON: reqJSON)
    guard let data = result.data(using: .utf8),
      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return (0, "") }
    let status = dict["status"] as? Int ?? 0
    let body = dict["body"] as? String ?? ""
    return (status, body)
  }

  // MARK: - Tests

  @Test("Reset wipes existing webhooks and registers a fresh one")
  func resetWipesAndReregisters() {
    MockHost.setUp()
    mockConfig["api_key"] = "re_test"
    mockConfig["tunnel_url"] = "https://tunnel.example.com"
    mockConfig["webhook_id"] = "wh-old"
    mockConfig["signing_secret"] = "whsec_old"
    mockConfig["webhook_registered"] = "true"

    let ctx = PluginContext()
    ctx.tunnelURL = "https://tunnel.example.com"

    // List returns one matching webhook + one unrelated; we should only delete ours.
    let oursURL = "https://tunnel.example.com/plugins/osaurus.resend/webhook"
    let listBody: [String: Any] = [
      "object": "list",
      "has_more": false,
      "data": [
        ["id": "wh-existing", "endpoint": oursURL, "events": ["email.received"]],
        [
          "id": "wh-unrelated", "endpoint": "https://example.com/other",
          "events": ["email.sent"],
        ],
      ],
    ]
    MockHost.pushHTTPResponse(status: 200, body: listBody)
    MockHost.pushHTTPResponse(status: 200, body: [:])  // delete
    MockHost.pushHTTPResponse(
      status: 200, body: ["id": "wh-new", "signing_secret": "whsec_new"])

    let response = sendReset(ctx: ctx)
    #expect(response.status == 200)
    #expect(response.body.contains("wh-new"))

    let methodPaths = parsedRequests().map { "\($0.method) \($0.path)" }
    #expect(methodPaths.contains("DELETE /webhooks/wh-existing"))
    #expect(!methodPaths.contains("DELETE /webhooks/wh-unrelated"))
    #expect(methodPaths.contains("POST /webhooks"))
    #expect(mockConfig["webhook_id"] == "wh-new")
    #expect(mockConfig["signing_secret"] == "whsec_new")
    #expect(mockConfig["webhook_registered"] == "true")
  }

  @Test("Reset returns error when api_key is missing")
  func resetWithoutApiKey() {
    MockHost.setUp()
    mockConfig["tunnel_url"] = "https://tunnel.example.com"
    let ctx = PluginContext()
    ctx.tunnelURL = "https://tunnel.example.com"

    let response = sendReset(ctx: ctx)
    #expect(response.status == 500)
    #expect(response.body.contains("api_key"))
    #expect(parsedRequests().isEmpty)
  }

  @Test("Reset returns error when tunnel_url is missing")
  func resetWithoutTunnelURL() {
    MockHost.setUp()
    mockConfig["api_key"] = "re_test"
    let ctx = PluginContext()  // No tunnelURL set.

    let response = sendReset(ctx: ctx)
    #expect(response.status == 500)
    #expect(response.body.contains("tunnel_url"))
    #expect(parsedRequests().isEmpty)
  }

  @Test("Reset propagates create failure to the response body")
  func resetReportsCreateFailure() {
    MockHost.setUp()
    mockConfig["api_key"] = "re_test"
    mockConfig["tunnel_url"] = "https://tunnel.example.com"
    let ctx = PluginContext()
    ctx.tunnelURL = "https://tunnel.example.com"

    // List ok, then non-retryable 422 on create.
    MockHost.pushHTTPResponse(
      status: 200, body: ["object": "list", "has_more": false, "data": []])
    MockHost.pushHTTPResponse(
      status: 422, body: ["name": "validation_error", "message": "endpoint invalid"])

    let response = sendReset(ctx: ctx)
    #expect(response.status == 500)
    #expect(response.body.contains("ok"))
    #expect(mockConfig["webhook_id"] == nil)
    #expect(mockConfig["webhook_registered"] == nil)
  }
}
