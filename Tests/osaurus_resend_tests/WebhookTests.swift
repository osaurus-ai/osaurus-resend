import Foundation
import Testing

@testable import osaurus_resend

@Suite("Webhook & Route Handling", .serialized)
struct WebhookTests {

  // MARK: - End-to-end inbound email flow

  @Test("Inbound email with open policy creates thread and dispatches task")
  func inboundEmailFullFlow() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    mockConfig["sender_policy"] = "open"
    mockConfig["api_key"] = "re_test_key"
    mockConfig["from_email"] = "agent@myapp.com"

    MockHost.pushReceivedEmailResponse(
      emailId: "recv-001",
      from: "Alice <alice@example.com>",
      to: ["agent@myapp.com"],
      subject: "Can you help?",
      text: "I need help scheduling a meeting.",
      html: nil,
      messageId: "<msg-001@example.com>"
    )

    let webhookBody = """
      {"type":"email.received","data":{"email_id":"recv-001","from":"Alice <alice@example.com>","to":["agent@myapp.com"],"subject":"Can you help?","message_id":"<msg-001@example.com>"}}
      """
    let ctx = PluginContext()
    let result = sendWebhookRequest(ctx: ctx, body: webhookBody)

    #expect(result.status == 200)
    #expect(mockDispatchCalls.count == 1)

    let dispatchPayload = mockDispatchCalls.first ?? ""
    #expect(dispatchPayload.contains("I need help scheduling a meeting"))
    #expect(dispatchPayload.contains("alice@example.com"))

    let threads = DatabaseManager.listThreads()
    #expect(threads.count == 1)
    #expect(threads.first?.participants.contains("alice@example.com") == true)
    #expect(threads.first?.taskId == "task-001")
  }

  @Test("Inbound email with known policy and allowed sender dispatches task")
  func inboundEmailAllowedSender() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    mockConfig["sender_policy"] = "known"
    mockConfig["allowed_senders"] = "bob@trusted.com"
    mockConfig["api_key"] = "re_test_key"
    mockConfig["from_email"] = "agent@myapp.com"

    MockHost.pushReceivedEmailResponse(
      emailId: "recv-002",
      from: "bob@trusted.com",
      to: ["agent@myapp.com"],
      subject: "Invoice attached",
      text: "Please process this invoice.",
      html: nil,
      messageId: "<msg-002>"
    )

    let webhookBody = """
      {"type":"email.received","data":{"email_id":"recv-002","from":"bob@trusted.com","to":["agent@myapp.com"],"subject":"Invoice attached","message_id":"<msg-002>"}}
      """
    let ctx = PluginContext()
    let result = sendWebhookRequest(ctx: ctx, body: webhookBody)

    #expect(result.status == 200)
    #expect(mockDispatchCalls.count == 1)
  }

  @Test("Inbound email with known policy rejects unauthorized sender")
  func inboundEmailUnauthorized() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    mockConfig["sender_policy"] = "known"
    mockConfig["allowed_senders"] = "alice@allowed.com"
    mockConfig["api_key"] = "re_test_key"
    mockConfig["from_email"] = "agent@myapp.com"

    let webhookBody = """
      {"type":"email.received","data":{"email_id":"recv-003","from":"stranger@evil.com","to":["agent@myapp.com"],"subject":"Spam"}}
      """
    let ctx = PluginContext()
    let result = sendWebhookRequest(ctx: ctx, body: webhookBody)

    #expect(result.status == 200)
    #expect(mockDispatchCalls.isEmpty, "Should not dispatch for unauthorized sender")

    let threads = DatabaseManager.listThreads()
    #expect(threads.isEmpty, "Should not create thread for unauthorized sender")
  }

  @Test("Inbound email with domain-based allowed_senders dispatches task")
  func inboundEmailDomainMatch() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    mockConfig["sender_policy"] = "known"
    mockConfig["allowed_senders"] = "@company.com"
    mockConfig["api_key"] = "re_test_key"
    mockConfig["from_email"] = "agent@myapp.com"

    MockHost.pushReceivedEmailResponse(
      emailId: "recv-004",
      from: "anyone@company.com",
      to: ["agent@myapp.com"],
      subject: "Team update",
      text: "Here's the weekly update.",
      html: nil,
      messageId: "<msg-004>"
    )

    let webhookBody = """
      {"type":"email.received","data":{"email_id":"recv-004","from":"anyone@company.com","to":["agent@myapp.com"],"subject":"Team update","message_id":"<msg-004>"}}
      """
    let ctx = PluginContext()
    let result = sendWebhookRequest(ctx: ctx, body: webhookBody)

    #expect(result.status == 200)
    #expect(mockDispatchCalls.count == 1)
  }

  @Test("Config values are read correctly during webhook processing")
  func configReadDuringWebhook() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    mockConfig["sender_policy"] = "open"
    mockConfig["api_key"] = "re_my_key"
    mockConfig["from_email"] = "bot@domain.com"

    MockHost.pushReceivedEmailResponse(
      emailId: "recv-005",
      from: "test@test.com",
      to: ["bot@domain.com"],
      subject: "Config test",
      text: "Testing config",
      html: nil,
      messageId: "<msg-005>"
    )

    let webhookBody = """
      {"type":"email.received","data":{"email_id":"recv-005","from":"test@test.com","to":["bot@domain.com"],"subject":"Config test","message_id":"<msg-005>"}}
      """
    let ctx = PluginContext()
    _ = sendWebhookRequest(ctx: ctx, body: webhookBody)

    #expect(mockDispatchCalls.count == 1, "Should dispatch when config is properly set")

    let threads = DatabaseManager.listThreads()
    #expect(threads.count == 1)
    let participants = threads.first?.participants ?? []
    #expect(
      !participants.contains("bot@domain.com"),
      "Agent's own address should be excluded from participants")
    #expect(participants.contains("test@test.com"))
  }

  // MARK: - Deduplication

  @Test("Duplicate webhook deliveries are skipped")
  func duplicateWebhookSkipped() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    mockConfig["sender_policy"] = "open"
    mockConfig["api_key"] = "re_test"
    mockConfig["from_email"] = "agent@d.com"

    MockHost.pushReceivedEmailResponse(
      emailId: "dup-001", from: "alice@a.com", to: ["agent@d.com"],
      subject: "Hello", text: "First time", html: nil, messageId: "<dup-msg>"
    )

    let webhookBody = """
      {"type":"email.received","data":{"email_id":"dup-001","from":"alice@a.com","to":["agent@d.com"],"subject":"Hello","message_id":"<dup-msg>"}}
      """
    let ctx = PluginContext()

    let result1 = sendWebhookRequest(ctx: ctx, body: webhookBody)
    #expect(result1.status == 200)
    #expect(mockDispatchCalls.count == 1, "First delivery should dispatch")

    let result2 = sendWebhookRequest(ctx: ctx, body: webhookBody)
    #expect(result2.status == 200)
    #expect(mockDispatchCalls.count == 1, "Duplicate should NOT dispatch again")

    let result3 = sendWebhookRequest(ctx: ctx, body: webhookBody)
    #expect(result3.status == 200)
    #expect(mockDispatchCalls.count == 1, "Third duplicate should also be skipped")

    let threads = DatabaseManager.listThreads()
    #expect(threads.count == 1, "Only one thread should exist despite 3 deliveries")
  }

  @Test("Different email_ids are processed independently")
  func differentEmailIdsProcessed() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    mockConfig["sender_policy"] = "open"
    mockConfig["api_key"] = "re_test"
    mockConfig["from_email"] = "agent@d.com"

    MockHost.pushReceivedEmailResponse(
      emailId: "email-A", from: "alice@a.com", to: ["agent@d.com"],
      subject: "First", text: "Message A", html: nil, messageId: "<msg-A>"
    )
    MockHost.pushReceivedEmailResponse(
      emailId: "email-B", from: "bob@b.com", to: ["agent@d.com"],
      subject: "Second", text: "Message B", html: nil, messageId: "<msg-B>"
    )

    let ctx = PluginContext()

    let bodyA = """
      {"type":"email.received","data":{"email_id":"email-A","from":"alice@a.com","to":["agent@d.com"],"subject":"First","message_id":"<msg-A>"}}
      """
    let bodyB = """
      {"type":"email.received","data":{"email_id":"email-B","from":"bob@b.com","to":["agent@d.com"],"subject":"Second","message_id":"<msg-B>"}}
      """

    _ = sendWebhookRequest(ctx: ctx, body: bodyA)
    _ = sendWebhookRequest(ctx: ctx, body: bodyB)

    #expect(mockDispatchCalls.count == 2, "Two different emails should both dispatch")
    #expect(DatabaseManager.listThreads().count == 2, "Two different threads should exist")
  }

  // MARK: - Route dispatch

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
    let webhookBody = "{\"type\":\"email.sent\",\"data\":{\"email_id\":\"xyz\"}}"
    let ctx = PluginContext()
    let result = sendWebhookRequest(ctx: ctx, body: webhookBody)
    #expect(result.status == 200)
    #expect(mockDispatchCalls.isEmpty)
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

private func sendWebhookRequest(ctx: PluginContext, body: String) -> ParsedRouteResponse {
  let routeReq: [String: Any] = [
    "route_id": "webhook",
    "method": "POST",
    "path": "/webhook",
    "body": body,
  ]
  guard let reqJSON = makeJSONString(routeReq) else {
    return ParsedRouteResponse(status: 0, body: "")
  }
  let result = handleRoute(ctx: ctx, requestJSON: reqJSON)
  return parseRouteResponse(result)
}
