import Foundation
import Testing

@testable import osaurus_resend

@Suite("Task Event Handling", .serialized)
struct TaskEventTests {

  @Test("Completed task auto-replies when agent didn't reply")
  func completedAutoReplies() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    mockConfig["api_key"] = "re_test"
    mockConfig["from_email"] = "agent@d.com"

    let taskId = "task-auto"
    let threadId = "t-auto"

    DatabaseManager.createThread(
      threadId: threadId, subject: "Auto-reply test",
      participants: ["alice@a.com"], messageId: "<msg-auto>", refs: "<msg-auto>"
    )
    DatabaseManager.updateThread(threadId: threadId, taskId: taskId)
    DatabaseManager.insertMessage(
      threadId: threadId, emailId: "e-in", direction: "in",
      fromAddress: "alice@a.com", toAddress: ["agent@d.com"],
      ccAddress: [], bccAddress: [],
      subject: "Auto-reply test", bodyText: "Help me", bodyHtml: nil,
      messageId: "<msg-auto>", inReplyTo: nil, hasAttachments: false
    )

    MockHost.pushSendEmailResponse(emailId: "email-auto-reply")

    let ctx = PluginContext()
    ctx.taskDispatchTimestamps[taskId] = Int(Date().timeIntervalSince1970) - 60

    let eventJSON = "{\"success\":true,\"output\":\"<p>Here is your answer</p>\"}"
    handleTaskEvent(ctx: ctx, taskId: taskId, eventType: 4, eventJSON: eventJSON)

    let messages = DatabaseManager.getMessages(threadId: threadId, limit: 10)
    let outbound = messages.filter { $0.direction == "out" }
    #expect(outbound.count == 1)

    let thread = DatabaseManager.getThread(threadId: threadId)
    #expect(thread?.taskId == nil)
    #expect(ctx.taskDispatchTimestamps[taskId] == nil)
  }

  @Test("Completed task skips auto-reply when agent already replied")
  func completedSkipsWhenAlreadyReplied() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    mockConfig["api_key"] = "re_test"
    mockConfig["from_email"] = "agent@d.com"

    let taskId = "task-skip"
    let threadId = "t-skip"
    let dispatchTime = Int(Date().timeIntervalSince1970) - 60

    DatabaseManager.createThread(
      threadId: threadId, subject: "Skip test",
      participants: ["bob@b.com"], messageId: "<msg-skip>", refs: "<msg-skip>"
    )
    DatabaseManager.updateThread(threadId: threadId, taskId: taskId)

    // Agent already replied during the task
    mockMessages.append([
      "id": 99, "thread_id": threadId, "email_id": "e-agent",
      "direction": "out", "from_address": "agent@d.com",
      "to_address": "[\"bob@b.com\"]",
      "cc_address": "[]", "bcc_address": "[]",
      "subject": "Re: Skip test", "body_text": "Already replied",
      "body_html": NSNull(), "message_id": NSNull(),
      "in_reply_to": NSNull(), "has_attachments": 0,
      "created_at": Int(Date().timeIntervalSince1970),
    ])

    let ctx = PluginContext()
    ctx.taskDispatchTimestamps[taskId] = dispatchTime

    let eventJSON = "{\"success\":true,\"output\":\"Some output\"}"
    handleTaskEvent(ctx: ctx, taskId: taskId, eventType: 4, eventJSON: eventJSON)

    // No HTTP call should have been made (mock queue is still empty, no send)
    let thread = DatabaseManager.getThread(threadId: threadId)
    #expect(thread?.taskId == nil)
    #expect(ctx.taskDispatchTimestamps[taskId] == nil)
  }

  @Test("Completed task with empty summary skips auto-reply")
  func completedEmptySummarySkips() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    mockConfig["api_key"] = "re_test"
    mockConfig["from_email"] = "agent@d.com"

    let taskId = "task-empty"
    let threadId = "t-empty"

    DatabaseManager.createThread(
      threadId: threadId, subject: "Empty test",
      participants: ["c@c.com"], messageId: nil, refs: nil
    )
    DatabaseManager.updateThread(threadId: threadId, taskId: taskId)

    let ctx = PluginContext()
    ctx.taskDispatchTimestamps[taskId] = Int(Date().timeIntervalSince1970) - 60

    let eventJSON = "{\"success\":true}"
    handleTaskEvent(ctx: ctx, taskId: taskId, eventType: 4, eventJSON: eventJSON)

    let thread = DatabaseManager.getThread(threadId: threadId)
    #expect(thread?.taskId == nil)
    #expect(ctx.taskDispatchTimestamps[taskId] == nil)
  }

  @Test("Failed task cleans up without sending email")
  func failedTaskCleansUp() {
    MockHost.setUp()
    DatabaseManager.initSchema()

    let taskId = "task-fail"
    let threadId = "t-fail"

    DatabaseManager.createThread(
      threadId: threadId, subject: "Fail test",
      participants: ["d@d.com"], messageId: nil, refs: nil
    )
    DatabaseManager.updateThread(threadId: threadId, taskId: taskId)

    let ctx = PluginContext()
    ctx.taskDispatchTimestamps[taskId] = Int(Date().timeIntervalSince1970) - 30
    ctx.taskArtifacts[taskId] = [
      CollectedArtifact(filename: "orphan.txt", data: Data("data".utf8), mimeType: "text/plain")
    ]

    let eventJSON = "{\"success\":false,\"summary\":\"Something broke\"}"
    handleTaskEvent(ctx: ctx, taskId: taskId, eventType: 5, eventJSON: eventJSON)

    let thread = DatabaseManager.getThread(threadId: threadId)
    #expect(thread?.taskId == nil)
    #expect(ctx.taskArtifacts[taskId] == nil)
    #expect(ctx.taskDispatchTimestamps[taskId] == nil)
  }

  @Test("Cancelled task cleans up without sending email")
  func cancelledTaskCleansUp() {
    MockHost.setUp()
    DatabaseManager.initSchema()

    let taskId = "task-cancel"
    let threadId = "t-cancel"

    DatabaseManager.createThread(
      threadId: threadId, subject: "Cancel test",
      participants: ["e@e.com"], messageId: nil, refs: nil
    )
    DatabaseManager.updateThread(threadId: threadId, taskId: taskId)

    let ctx = PluginContext()
    ctx.taskDispatchTimestamps[taskId] = Int(Date().timeIntervalSince1970)

    handleTaskEvent(ctx: ctx, taskId: taskId, eventType: 6, eventJSON: "{}")

    let thread = DatabaseManager.getThread(threadId: threadId)
    #expect(thread?.taskId == nil)
    #expect(ctx.taskDispatchTimestamps[taskId] == nil)
  }

  @Test("Completed task attaches collected artifacts to auto-reply")
  func completedWithArtifacts() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    mockConfig["api_key"] = "re_test"
    mockConfig["from_email"] = "agent@d.com"

    let taskId = "task-artifacts"
    let threadId = "t-artifacts"

    DatabaseManager.createThread(
      threadId: threadId, subject: "Artifact test",
      participants: ["frank@f.com"], messageId: "<msg-art>", refs: "<msg-art>"
    )
    DatabaseManager.updateThread(threadId: threadId, taskId: taskId)
    DatabaseManager.insertMessage(
      threadId: threadId, emailId: "e-art-in", direction: "in",
      fromAddress: "frank@f.com", toAddress: ["agent@d.com"],
      ccAddress: [], bccAddress: [],
      subject: "Artifact test", bodyText: "Generate report", bodyHtml: nil,
      messageId: "<msg-art>", inReplyTo: nil, hasAttachments: false
    )

    MockHost.pushSendEmailResponse(emailId: "email-with-attachments")

    let ctx = PluginContext()
    ctx.taskDispatchTimestamps[taskId] = Int(Date().timeIntervalSince1970) - 60
    ctx.taskArtifacts[taskId] = [
      CollectedArtifact(
        filename: "report.pdf", data: Data("pdf".utf8), mimeType: "application/pdf"),
      CollectedArtifact(filename: "data.csv", data: Data("csv".utf8), mimeType: "text/csv"),
    ]

    let eventJSON = "{\"success\":true,\"output\":\"<p>Report attached</p>\"}"
    handleTaskEvent(ctx: ctx, taskId: taskId, eventType: 4, eventJSON: eventJSON)

    let messages = DatabaseManager.getMessages(threadId: threadId, limit: 10)
    let outbound = messages.filter { $0.direction == "out" }
    #expect(outbound.count == 1)
    #expect(outbound.first?.hasAttachments == true)

    #expect(ctx.taskArtifacts[taskId] == nil)
  }

  @Test("Completed task with no thread silently cleans up")
  func completedNoThread() {
    MockHost.setUp()
    DatabaseManager.initSchema()

    let ctx = PluginContext()
    let taskId = "orphan-task"
    ctx.taskDispatchTimestamps[taskId] = Int(Date().timeIntervalSince1970)
    ctx.taskArtifacts[taskId] = []

    handleTaskEvent(
      ctx: ctx, taskId: taskId, eventType: 4, eventJSON: "{\"success\":true,\"output\":\"data\"}")

    #expect(ctx.taskDispatchTimestamps[taskId] == nil)
    #expect(ctx.taskArtifacts[taskId] == nil)
  }

  // MARK: - CLARIFICATION (type 3) forwarding

  @Test("Clarification with options renders numbered choices to email")
  func clarificationWithOptionsForwarded() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    mockConfig["api_key"] = "re_test"
    mockConfig["from_email"] = "agent@d.com"

    let taskId = "task-clarify"
    let threadId = "t-clarify"

    DatabaseManager.createThread(
      threadId: threadId, subject: "Booking",
      participants: ["alice@a.com"], messageId: "<msg-clarify>", refs: "<msg-clarify>"
    )
    DatabaseManager.updateThread(threadId: threadId, taskId: taskId)
    DatabaseManager.insertMessage(
      threadId: threadId, emailId: "e-in", direction: "in",
      fromAddress: "alice@a.com", toAddress: ["agent@d.com"],
      ccAddress: [], bccAddress: [],
      subject: "Booking", bodyText: "Book me a flight", bodyHtml: nil,
      messageId: "<msg-clarify>", inReplyTo: nil, hasAttachments: false
    )

    MockHost.pushSendEmailResponse(emailId: "email-clarify-out")

    let ctx = PluginContext()
    let eventJSON = """
      {"question":"Window or aisle?","options":["Window","Aisle"],"allow_multiple":false}
      """
    handleTaskEvent(ctx: ctx, taskId: taskId, eventType: 3, eventJSON: eventJSON)

    // The question email is sent and recorded as outbound so the COMPLETED
    // safety net stays disarmed across the pause.
    let messages = DatabaseManager.getMessages(threadId: threadId, limit: 10)
    let outbound = messages.filter { $0.direction == "out" }
    #expect(outbound.count == 1)
    #expect(outbound.first?.bodyHtml?.contains("Window or aisle?") == true)
    #expect(outbound.first?.bodyHtml?.contains("1. Window") == true)
    #expect(outbound.first?.bodyHtml?.contains("2. Aisle") == true)

    // task_id MUST survive the pause — the same task resumes when the user
    // replies and the new email's webhook arrives.
    let thread = DatabaseManager.getThread(threadId: threadId)
    #expect(thread?.taskId == taskId)
  }

  @Test("Clarification without options renders free-form question")
  func clarificationFreeformForwarded() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    mockConfig["api_key"] = "re_test"
    mockConfig["from_email"] = "agent@d.com"

    let taskId = "task-clarify-free"
    let threadId = "t-clarify-free"

    DatabaseManager.createThread(
      threadId: threadId, subject: "Question",
      participants: ["bob@b.com"], messageId: nil, refs: nil
    )
    DatabaseManager.updateThread(threadId: threadId, taskId: taskId)
    DatabaseManager.insertMessage(
      threadId: threadId, emailId: "e-in-free", direction: "in",
      fromAddress: "bob@b.com", toAddress: ["agent@d.com"],
      ccAddress: [], bccAddress: [],
      subject: "Question", bodyText: "...", bodyHtml: nil,
      messageId: nil, inReplyTo: nil, hasAttachments: false
    )

    MockHost.pushSendEmailResponse(emailId: "email-free-out")

    let ctx = PluginContext()
    let eventJSON = """
      {"question":"What is the budget?","allow_multiple":false}
      """
    handleTaskEvent(ctx: ctx, taskId: taskId, eventType: 3, eventJSON: eventJSON)

    let outbound = DatabaseManager.getMessages(threadId: threadId, limit: 10)
      .filter { $0.direction == "out" }
    #expect(outbound.count == 1)
    #expect(outbound.first?.bodyHtml == "What is the budget?")
  }

  @Test("Clarification with empty question is a no-op")
  func clarificationEmptyQuestionIgnored() {
    MockHost.setUp()
    DatabaseManager.initSchema()

    let ctx = PluginContext()
    handleTaskEvent(ctx: ctx, taskId: "any-task", eventType: 3, eventJSON: "{}")

    #expect(mockHTTPRequests.isEmpty)
  }

  @Test("Clarification preserves task_id (subsequent COMPLETED safety net stays disarmed)")
  func clarificationKeepsTaskIdForResume() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    mockConfig["api_key"] = "re_test"
    mockConfig["from_email"] = "agent@d.com"

    let taskId = "task-clarify-survive"
    let threadId = "t-clarify-survive"

    DatabaseManager.createThread(
      threadId: threadId, subject: "Survive",
      participants: ["carla@c.com"], messageId: nil, refs: nil
    )
    DatabaseManager.updateThread(threadId: threadId, taskId: taskId)
    DatabaseManager.insertMessage(
      threadId: threadId, emailId: "e-in-survive", direction: "in",
      fromAddress: "carla@c.com", toAddress: ["agent@d.com"],
      ccAddress: [], bccAddress: [],
      subject: "Survive", bodyText: "Help", bodyHtml: nil,
      messageId: nil, inReplyTo: nil, hasAttachments: false
    )

    MockHost.pushSendEmailResponse(emailId: "email-survive-q")

    let ctx = PluginContext()
    ctx.taskDispatchTimestamps[taskId] = Int(Date().timeIntervalSince1970) - 30

    handleTaskEvent(
      ctx: ctx, taskId: taskId, eventType: 3,
      eventJSON: "{\"question\":\"Need more info?\"}"
    )

    // Now COMPLETED arrives for the same task. The safety net must NOT
    // fire because the clarify email was recorded as outbound.
    handleTaskEvent(
      ctx: ctx, taskId: taskId, eventType: 4,
      eventJSON: "{\"success\":true,\"output\":\"<p>final answer</p>\"}"
    )

    // The clarify email and the (now-deferred) safety net should not result
    // in a second outbound — only the clarify email landed.
    let outbound = DatabaseManager.getMessages(threadId: threadId, limit: 10)
      .filter { $0.direction == "out" }
    #expect(outbound.count == 1)
  }
}

// MARK: - Inbound Follow-up Interrupt

@Suite("Inbound Follow-up Interrupt", .serialized)
struct InboundFollowupTests {

  @Test("Second inbound on the same thread interrupts the in-flight task")
  func followupInterruptsActiveTask() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    mockConfig["sender_policy"] = "open"
    mockConfig["api_key"] = "re_test"
    mockConfig["from_email"] = "agent@d.com"

    // First inbound: thread is fresh, no task yet. Mock the receive fetch
    // and dispatch returns task-001 (default mockDispatchResult).
    MockHost.pushReceivedEmailResponse(
      emailId: "e-1", from: "alice@a.com", to: ["agent@d.com"],
      subject: "Hi", text: "Need a quote", html: nil, messageId: "<m1>"
    )

    let body1 = """
      {"type":"email.received","data":{"email_id":"e-1","from":"alice@a.com","to":["agent@d.com"],"subject":"Hi","message_id":"<m1>"}}
      """
    let req1: [String: Any] = [
      "route_id": "webhook", "method": "POST", "path": "/webhook", "body": body1,
      "headers": ["svix-id": "msg-1"],
    ]
    _ = handleRoute(ctx: PluginContext(), requestJSON: makeJSONString(req1) ?? "{}")

    #expect(mockDispatchCalls.count == 1)
    #expect(mockDispatchInterruptCalls.isEmpty)

    // Second inbound on the same thread (joins via In-Reply-To). Should
    // interrupt the still-running task-001 with the new body and dispatch
    // a fresh task with the same session_id.
    mockDispatchResult = "{\"id\":\"task-002\",\"status\":\"running\"}"
    MockHost.pushReceivedEmailResponse(
      emailId: "e-2", from: "alice@a.com", to: ["agent@d.com"],
      subject: "Re: Hi", text: "Actually wait, let me clarify", html: nil,
      messageId: "<m2>",
      headers: ["in-reply-to": "<m1>"]
    )

    let body2 = """
      {"type":"email.received","data":{"email_id":"e-2","from":"alice@a.com","to":["agent@d.com"],"subject":"Re: Hi","message_id":"<m2>"}}
      """
    let req2: [String: Any] = [
      "route_id": "webhook", "method": "POST", "path": "/webhook", "body": body2,
      "headers": ["svix-id": "msg-2"],
    ]
    _ = handleRoute(ctx: PluginContext(), requestJSON: makeJSONString(req2) ?? "{}")

    #expect(mockDispatchInterruptCalls.count == 1)
    if let call = mockDispatchInterruptCalls.first {
      #expect(call.taskId == "task-001")
      #expect(call.message.contains("follow-up email arrived"))
      #expect(call.message.contains("Actually wait"))
    }
    #expect(mockDispatchCalls.count == 2)
  }

  @Test("Dispatch payload uses session_id (UUID5) and pins reply tools")
  func dispatchPayloadShape() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    mockConfig["sender_policy"] = "open"
    mockConfig["api_key"] = "re_test"
    mockConfig["from_email"] = "agent@d.com"

    MockHost.pushReceivedEmailResponse(
      emailId: "e-shape", from: "x@x.com", to: ["agent@d.com"],
      subject: "Shape", text: "body", html: nil, messageId: "<m-shape>"
    )

    let body = """
      {"type":"email.received","data":{"email_id":"e-shape","from":"x@x.com","to":["agent@d.com"],"subject":"Shape","message_id":"<m-shape>"}}
      """
    let req: [String: Any] = [
      "route_id": "webhook", "method": "POST", "path": "/webhook", "body": body,
      "headers": ["svix-id": "msg-shape"],
    ]
    _ = handleRoute(ctx: PluginContext(), requestJSON: makeJSONString(req) ?? "{}")

    #expect(mockDispatchCalls.count == 1)
    guard let dispatchJSON = mockDispatchCalls.first,
      let data = dispatchJSON.data(using: .utf8),
      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      Issue.record("Could not parse dispatch payload")
      return
    }

    // session_id must be a valid UUID, not the legacy external_session_key
    #expect(payload["external_session_key"] == nil)
    let sessionIdValue = payload["session_id"] as? String ?? ""
    #expect(UUID(uuidString: sessionIdValue) != nil)

    let tools = payload["tools"] as? [String] ?? []
    #expect(tools.contains("resend_reply"))
  }

  @Test("Same thread always derives the same session_id")
  func sessionIdDeterministic() {
    let a = sessionId(forThreadId: "thread-abc")
    let b = sessionId(forThreadId: "thread-abc")
    let c = sessionId(forThreadId: "thread-xyz")
    #expect(a == b)
    #expect(a != c)
    #expect(UUID(uuidString: a) != nil)
  }
}
