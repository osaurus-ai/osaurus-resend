import Foundation
import Testing

@testable import osaurus_resend

@Suite("Lifecycle Events", .serialized)
struct LifecycleEventTests {

  // MARK: - Helpers

  private func sendWebhook(body: String) -> Int {
    let routeReq: [String: Any] = [
      "route_id": "webhook",
      "method": "POST",
      "path": "/webhook",
      "body": body,
    ]
    guard let reqJSON = makeJSONString(routeReq) else { return 0 }
    let result = handleRoute(ctx: PluginContext(), requestJSON: reqJSON)
    guard let data = result.data(using: .utf8),
      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let status = dict["status"] as? Int
    else { return 0 }
    return status
  }

  private func seedOutboundMessage(threadId: String, emailId: String, taskId: String?) {
    DatabaseManager.createThread(
      threadId: threadId, subject: "Test", participants: ["bob@example.com"],
      messageId: nil, refs: nil)
    if let taskId {
      DatabaseManager.updateThread(threadId: threadId, taskId: taskId)
    }
    DatabaseManager.insertMessage(
      threadId: threadId, emailId: emailId, direction: "out",
      fromAddress: "agent@d.com", toAddress: ["bob@example.com"],
      ccAddress: [], bccAddress: [],
      subject: "Test", bodyText: "hi", bodyHtml: nil,
      messageId: nil, inReplyTo: nil, hasAttachments: false)
  }

  // MARK: - Tests

  @Test("Bounce event suppresses recipient and records the event")
  func bounceSuppressesRecipient() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    seedOutboundMessage(threadId: "t-1", emailId: "e-bounce", taskId: nil)

    let body = """
      {"type":"email.bounced","data":{"email_id":"e-bounce","to":["bob@example.com"],"bounce":{"message":"recipient address rejected","subType":"Suppressed","type":"Permanent"}}}
      """
    let status = sendWebhook(body: body)
    #expect(status == 200)

    #expect(DatabaseManager.getSuppression(address: "bob@example.com") != nil)
    #expect(mockEmailEvents.contains { $0.type == "bounced" && $0.emailId == "e-bounce" })
  }

  @Test("Complaint event suppresses recipient")
  func complaintSuppresses() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    seedOutboundMessage(threadId: "t-2", emailId: "e-spam", taskId: nil)

    let body = """
      {"type":"email.complained","data":{"email_id":"e-spam","to":["bob@example.com"]}}
      """
    let status = sendWebhook(body: body)
    #expect(status == 200)

    let reason = DatabaseManager.getSuppression(address: "bob@example.com") ?? ""
    #expect(reason.contains("complaint"))
  }

  @Test("resend_send refuses to send to a suppressed address")
  func sendRefusesSuppressed() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    mockConfig["api_key"] = "re_test"
    mockConfig["from_email"] = "agent@d.com"

    DatabaseManager.suppressAddress(
      address: "blocked@bad.com", reason: "bounce: hard", emailId: "prev-e1")

    let tool = ResendSendTool()
    let argsJSON =
      "{\"to\":\"blocked@bad.com\",\"subject\":\"Hi\",\"body\":\"<p>Test</p>\"}"
    let result = tool.run(args: argsJSON, ctx: PluginContext())

    #expect(result.contains("error"))
    #expect(result.contains("blocked@bad.com"))
    #expect(result.contains("suppressed") || result.contains("Suppressed"))
    // Crucially: no Resend API call was made.
    #expect(mockHTTPRequests.isEmpty)
  }

  @Test("Send-failure event surfaces an issue into the running task")
  func failureSurfacesToTask() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    seedOutboundMessage(threadId: "t-3", emailId: "e-fail", taskId: "task-running")

    let body = """
      {"type":"email.failed","data":{"email_id":"e-fail","to":["bob@example.com"],"failed":{"reason":"domain not verified"}}}
      """
    let status = sendWebhook(body: body)
    #expect(status == 200)

    #expect(mockAddIssueCalls.count == 1)
    if let call = mockAddIssueCalls.first {
      #expect(call.taskId == "task-running")
      #expect(call.payload.contains("email_send_problem"))
      #expect(call.payload.contains("domain not verified"))
      #expect(call.payload.contains("e-fail"))
    }
  }

  @Test("Delivered event records but does not surface or suppress")
  func deliveredJustRecords() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    seedOutboundMessage(threadId: "t-4", emailId: "e-delivered", taskId: "task-done")

    let body = """
      {"type":"email.delivered","data":{"email_id":"e-delivered","to":["bob@example.com"]}}
      """
    let status = sendWebhook(body: body)
    #expect(status == 200)

    #expect(mockEmailEvents.contains { $0.type == "delivered" && $0.emailId == "e-delivered" })
    #expect(mockAddIssueCalls.isEmpty)
    #expect(DatabaseManager.getSuppression(address: "bob@example.com") == nil)
  }

  @Test("Same svix-id delivered twice processes only once")
  func svixIdDedupe() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    mockConfig["sender_policy"] = "open"
    mockConfig["api_key"] = "re_test"
    mockConfig["from_email"] = "agent@d.com"

    MockHost.pushReceivedEmailResponse(
      emailId: "dup-e", from: "a@a.com", to: ["agent@d.com"],
      subject: "x", text: "x", html: nil, messageId: "<m>")

    let body =
      "{\"type\":\"email.received\",\"data\":{\"email_id\":\"dup-e\",\"from\":\"a@a.com\",\"to\":[\"agent@d.com\"]}}"
    let routeReq: [String: Any] = [
      "route_id": "webhook",
      "method": "POST",
      "path": "/webhook",
      "body": body,
      "headers": ["svix-id": "msg_dup_001"],
    ]
    guard let reqJSON = makeJSONString(routeReq) else { return }

    let r1 = handleRoute(ctx: PluginContext(), requestJSON: reqJSON)
    let r2 = handleRoute(ctx: PluginContext(), requestJSON: reqJSON)
    let parse: (String) -> Int = { s in
      guard let data = s.data(using: .utf8),
        let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let status = dict["status"] as? Int
      else { return 0 }
      return status
    }
    #expect(parse(r1) == 200)
    #expect(parse(r2) == 200)
    #expect(mockDispatchCalls.count == 1, "Same svix-id must dispatch exactly once")
  }
}
