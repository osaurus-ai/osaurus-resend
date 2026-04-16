import Testing
import Foundation
@testable import osaurus_resend

@Suite("Webhook & Route Handling", .serialized)
struct WebhookTests {

    @Test("Routes to webhook handler for route_id 'webhook'")
    func routeToWebhook() {
        MockHost.setUp()
        mockConfig["sender_policy"] = "open"
        mockConfig["api_key"] = "re_test"
        mockConfig["from_email"] = "agent@d.com"

        let webhookBody = """
        {"type":"email.received","data":{"email_id":"abc-123","from":"alice@a.com","to":["agent@d.com"],"subject":"Hello"}}
        """

        let routeReq: [String: Any] = [
            "route_id": "webhook",
            "method": "POST",
            "path": "/webhook",
            "body": webhookBody,
        ]
        guard let reqJSON = makeJSONString(routeReq) else {
            #expect(Bool(false), "Failed to serialize route request")
            return
        }

        let ctx = PluginContext()
        let result = handleRoute(ctx: ctx, requestJSON: reqJSON)

        let parsed = parseRouteResponse(result)
        #expect(parsed.status == 200)
        #expect(parsed.body == "ok")
    }

    @Test("Routes to health handler for route_id 'health'")
    func routeToHealth() {
        MockHost.setUp()
        mockConfig["webhook_registered"] = "true"

        let routeReq: [String: Any] = [
            "route_id": "health",
            "method": "GET",
            "path": "/health",
        ]
        guard let reqJSON = makeJSONString(routeReq) else {
            #expect(Bool(false), "Failed to serialize route request")
            return
        }

        let ctx = PluginContext()
        let result = handleRoute(ctx: ctx, requestJSON: reqJSON)

        let parsed = parseRouteResponse(result)
        #expect(parsed.status == 200)
        #expect(parsed.body.contains("true"))
    }

    @Test("Health endpoint reports webhook not registered")
    func healthNotRegistered() {
        MockHost.setUp()

        let routeReq: [String: Any] = [
            "route_id": "health",
            "method": "GET",
            "path": "/health",
        ]
        guard let reqJSON = makeJSONString(routeReq) else { return }

        let ctx = PluginContext()
        let result = handleRoute(ctx: ctx, requestJSON: reqJSON)

        let parsed = parseRouteResponse(result)
        #expect(parsed.status == 200)
        #expect(parsed.body.contains("false"))
    }

    @Test("Returns 404 for unknown route_id")
    func unknownRouteReturns404() {
        MockHost.setUp()
        let routeReq: [String: Any] = [
            "route_id": "unknown",
            "method": "GET",
            "path": "/unknown",
        ]
        guard let reqJSON = makeJSONString(routeReq) else { return }

        let ctx = PluginContext()
        let result = handleRoute(ctx: ctx, requestJSON: reqJSON)

        let parsed = parseRouteResponse(result)
        #expect(parsed.status == 404)
    }

    @Test("Returns 400 for invalid request JSON")
    func invalidRequestReturns400() {
        MockHost.setUp()
        let ctx = PluginContext()
        let result = handleRoute(ctx: ctx, requestJSON: "not valid json")

        let parsed = parseRouteResponse(result)
        #expect(parsed.status == 400)
    }

    @Test("Webhook ignores non-email.received events")
    func webhookIgnoresOtherEvents() {
        MockHost.setUp()
        let routeReq: [String: Any] = [
            "route_id": "webhook",
            "method": "POST",
            "path": "/webhook",
            "body": "{\"type\":\"email.sent\",\"data\":{\"email_id\":\"xyz\"}}",
        ]
        guard let reqJSON = makeJSONString(routeReq) else { return }

        let ctx = PluginContext()
        let result = handleRoute(ctx: ctx, requestJSON: reqJSON)

        let parsed = parseRouteResponse(result)
        #expect(parsed.status == 200)
    }

    @Test("Webhook handles empty body gracefully")
    func webhookEmptyBody() {
        MockHost.setUp()
        let routeReq: [String: Any] = [
            "route_id": "webhook",
            "method": "POST",
            "path": "/webhook",
        ]
        guard let reqJSON = makeJSONString(routeReq) else { return }

        let ctx = PluginContext()
        let result = handleRoute(ctx: ctx, requestJSON: reqJSON)
        let parsed = parseRouteResponse(result)
        #expect(parsed.status == 200)
    }
}

// MARK: - Helpers

private struct ParsedRouteResponse {
    let status: Int
    let body: String
}

private func parseRouteResponse(_ json: String) -> ParsedRouteResponse {
    guard let data = json.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return ParsedRouteResponse(status: 0, body: "") }
    let status = dict["status"] as? Int ?? 0
    let body = dict["body"] as? String ?? ""
    return ParsedRouteResponse(status: status, body: body)
}
