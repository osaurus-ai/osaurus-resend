import Foundation
import Testing

@testable import osaurus_resend

@Suite("Database Operations", .serialized)
struct DatabaseTests {

  @Test("Create and retrieve a thread")
  func createAndGetThread() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    DatabaseManager.createThread(
      threadId: "t-100", subject: "Test Subject",
      participants: ["alice@a.com", "bob@b.com"],
      messageId: "<msg-1>", refs: "<msg-1>"
    )
    let thread = DatabaseManager.getThread(threadId: "t-100")
    #expect(thread != nil)
    #expect(thread?.threadId == "t-100")
    #expect(thread?.subject == "Test Subject")
    #expect(thread?.participants.contains("alice@a.com") == true)
    #expect(thread?.participants.contains("bob@b.com") == true)
    #expect(thread?.lastMessageId == "<msg-1>")
  }

  @Test("Update thread fields")
  func updateThread() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    DatabaseManager.createThread(
      threadId: "t-200", subject: "Original",
      participants: ["alice@a.com"], messageId: nil, refs: nil
    )
    DatabaseManager.updateThread(
      threadId: "t-200",
      lastMessageId: "<msg-2>",
      refs: "<msg-1> <msg-2>",
      taskId: "task-abc",
      labels: ["urgent", "scheduling"]
    )
    let thread = DatabaseManager.getThread(threadId: "t-200")
    #expect(thread != nil)
    #expect(thread?.taskId == "task-abc")
    #expect(thread?.labels.contains("urgent") == true)
    #expect(thread?.labels.contains("scheduling") == true)
  }

  @Test("Clear task ID on thread")
  func clearTaskId() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    DatabaseManager.createThread(
      threadId: "t-300", subject: "Task test",
      participants: ["a@a.com"], messageId: nil, refs: nil
    )
    DatabaseManager.updateThread(threadId: "t-300", taskId: "task-xyz")
    let before = DatabaseManager.getThread(threadId: "t-300")
    #expect(before?.taskId == "task-xyz")

    DatabaseManager.clearTaskId(threadId: "t-300")
    let after = DatabaseManager.getThread(threadId: "t-300")
    #expect(after?.taskId == nil)
  }

  @Test("Get thread by task ID")
  func getThreadByTaskId() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    DatabaseManager.createThread(
      threadId: "t-400", subject: "By task",
      participants: ["a@a.com"], messageId: nil, refs: nil
    )
    DatabaseManager.updateThread(threadId: "t-400", taskId: "task-find-me")
    let thread = DatabaseManager.getThreadByTaskId("task-find-me")
    #expect(thread != nil)
    #expect(thread?.threadId == "t-400")
  }

  @Test("Insert and retrieve messages")
  func insertAndGetMessages() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    DatabaseManager.createThread(
      threadId: "t-500", subject: "Messages test",
      participants: ["a@a.com"], messageId: nil, refs: nil
    )
    DatabaseManager.insertMessage(
      threadId: "t-500", emailId: "e-1", direction: "in",
      fromAddress: "sender@a.com", toAddress: ["agent@b.com"],
      ccAddress: [], bccAddress: [],
      subject: "Hello", bodyText: "Hi there", bodyHtml: nil,
      messageId: "<msg-in-1>", inReplyTo: nil, hasAttachments: false
    )
    DatabaseManager.insertMessage(
      threadId: "t-500", emailId: "e-2", direction: "out",
      fromAddress: "agent@b.com", toAddress: ["sender@a.com"],
      ccAddress: [], bccAddress: [],
      subject: "Re: Hello", bodyText: "Got it", bodyHtml: nil,
      messageId: "<msg-out-1>", inReplyTo: "<msg-in-1>", hasAttachments: false
    )
    let messages = DatabaseManager.getMessages(threadId: "t-500", limit: 10)
    #expect(messages.count == 2)
  }

  @Test("Get last inbound message")
  func getLastInboundMessage() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    DatabaseManager.createThread(
      threadId: "t-600", subject: "Inbound test",
      participants: ["a@a.com"], messageId: nil, refs: nil
    )
    DatabaseManager.insertMessage(
      threadId: "t-600", emailId: "e-in", direction: "in",
      fromAddress: "sender@x.com", toAddress: ["agent@y.com"],
      ccAddress: [], bccAddress: [],
      subject: "Question", bodyText: "What time?", bodyHtml: nil,
      messageId: "<in-1>", inReplyTo: nil, hasAttachments: false
    )
    DatabaseManager.insertMessage(
      threadId: "t-600", emailId: "e-out", direction: "out",
      fromAddress: "agent@y.com", toAddress: ["sender@x.com"],
      ccAddress: [], bccAddress: [],
      subject: "Re: Question", bodyText: "3pm", bodyHtml: nil,
      messageId: "<out-1>", inReplyTo: "<in-1>", hasAttachments: false
    )
    let lastIn = DatabaseManager.getLastInboundMessage(threadId: "t-600")
    #expect(lastIn != nil)
    #expect(lastIn?.direction == "in")
    #expect(lastIn?.fromAddress == "sender@x.com")
  }

  @Test("List threads with participant filter")
  func listThreadsByParticipant() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    DatabaseManager.createThread(
      threadId: "t-700", subject: "Alice thread",
      participants: ["alice@a.com", "bob@b.com"],
      messageId: nil, refs: nil
    )
    DatabaseManager.createThread(
      threadId: "t-701", subject: "Charlie thread",
      participants: ["charlie@c.com"],
      messageId: nil, refs: nil
    )
    let aliceThreads = DatabaseManager.listThreads(participant: "alice@a.com")
    #expect(aliceThreads.count == 1)
    #expect(aliceThreads.first?.threadId == "t-700")

    let allThreads = DatabaseManager.listThreads()
    #expect(allThreads.count == 2)
  }

  @Test("List threads with label filter")
  func listThreadsByLabel() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    DatabaseManager.createThread(
      threadId: "t-800", subject: "Invoices",
      participants: ["a@a.com"], messageId: nil, refs: nil
    )
    DatabaseManager.updateThread(threadId: "t-800", labels: ["invoices", "urgent"])
    DatabaseManager.createThread(
      threadId: "t-801", subject: "Casual",
      participants: ["b@b.com"], messageId: nil, refs: nil
    )
    let invoiceThreads = DatabaseManager.listThreads(label: "invoices")
    #expect(invoiceThreads.count == 1)
    #expect(invoiceThreads.first?.threadId == "t-800")
  }

  @Test("hasEmailId detects existing email")
  func hasEmailIdCheck() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    #expect(DatabaseManager.hasEmailId("e-missing") == false)

    DatabaseManager.createThread(
      threadId: "t-eid", subject: "Dedup",
      participants: ["a@a.com"], messageId: nil, refs: nil
    )
    DatabaseManager.insertMessage(
      threadId: "t-eid", emailId: "e-exists", direction: "in",
      fromAddress: "a@a.com", toAddress: ["agent@d.com"],
      ccAddress: [], bccAddress: [],
      subject: "Dedup", bodyText: "test", bodyHtml: nil,
      messageId: nil, inReplyTo: nil, hasAttachments: false
    )

    #expect(DatabaseManager.hasEmailId("e-exists") == true)
    #expect(DatabaseManager.hasEmailId("e-other") == false)
  }

  @Test("hasSentTo returns true when outbound message exists")
  func hasSentToPositive() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    mockMessages.append([
      "id": 1, "thread_id": "t1", "email_id": "e1",
      "direction": "out", "from_address": "agent@d.com",
      "to_address": "[\"target@x.com\"]",
      "cc_address": "[]", "bcc_address": "[]",
      "subject": "Hi", "body_text": "Hello",
      "body_html": NSNull(), "message_id": NSNull(),
      "in_reply_to": NSNull(), "has_attachments": 0,
      "created_at": Int(Date().timeIntervalSince1970),
    ])
    #expect(DatabaseManager.hasSentTo(address: "target@x.com") == true)
    #expect(DatabaseManager.hasSentTo(address: "nobody@x.com") == false)
  }

  @Test("isParticipantInAnyThread returns true when participant exists")
  func isParticipantPositive() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    DatabaseManager.createThread(
      threadId: "t-900", subject: "Participants",
      participants: ["member@team.com", "other@team.com"],
      messageId: nil, refs: nil
    )
    #expect(DatabaseManager.isParticipantInAnyThread(address: "member@team.com") == true)
    #expect(DatabaseManager.isParticipantInAnyThread(address: "stranger@x.com") == false)
  }

  @Test("Get thread by message ID")
  func getThreadByMessageId() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    DatabaseManager.createThread(
      threadId: "t-1000", subject: "By msg id",
      participants: ["a@a.com"], messageId: "<orig-msg>", refs: "<orig-msg>"
    )
    DatabaseManager.insertMessage(
      threadId: "t-1000", emailId: "e-x", direction: "in",
      fromAddress: "a@a.com", toAddress: ["agent@b.com"],
      ccAddress: [], bccAddress: [],
      subject: "By msg id", bodyText: "body", bodyHtml: nil,
      messageId: "<orig-msg>", inReplyTo: nil, hasAttachments: false
    )
    let thread = DatabaseManager.getThreadByMessageId("<orig-msg>")
    #expect(thread != nil)
    #expect(thread?.threadId == "t-1000")
  }

  @Test("hasOutboundMessageSince checks timestamp")
  func hasOutboundMessageSince() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    let now = Int(Date().timeIntervalSince1970)
    mockMessages.append([
      "id": 1, "thread_id": "t-ts", "email_id": "e1",
      "direction": "out", "from_address": "agent@d.com",
      "to_address": "[\"bob@x.com\"]",
      "cc_address": "[]", "bcc_address": "[]",
      "subject": "Reply", "body_text": "Done",
      "body_html": NSNull(), "message_id": NSNull(),
      "in_reply_to": NSNull(), "has_attachments": 0,
      "created_at": now,
    ])
    #expect(
      DatabaseManager.hasOutboundMessageSince(threadId: "t-ts", sinceTimestamp: now - 10) == true)
    #expect(
      DatabaseManager.hasOutboundMessageSince(threadId: "t-ts", sinceTimestamp: now + 10) == false)
  }
}
