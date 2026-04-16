import Foundation
import Testing

@testable import osaurus_resend

@Suite("Tools", .serialized)
struct ToolTests {

  // MARK: - resend_send

  @Test("resend_send creates thread and returns email_id")
  func sendCreatesThread() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    mockConfig["api_key"] = "re_test"
    mockConfig["from_email"] = "agent@domain.com"
    mockConfig["from_name"] = "Agent"
    MockHost.pushSendEmailResponse(emailId: "email-001")

    let ctx = PluginContext()
    let args = "{\"to\":\"bob@example.com\",\"subject\":\"Hello\",\"body\":\"<p>Hi Bob</p>\"}"
    let result = ctx.sendTool.run(args: args, ctx: ctx)

    #expect(result.contains("thread_id"))
    #expect(result.contains("email-001"))

    let threads = DatabaseManager.listThreads()
    #expect(threads.count == 1)
    #expect(threads.first?.participants.contains("bob@example.com") == true)
  }

  @Test("resend_send fails without API key")
  func sendFailsWithoutApiKey() {
    MockHost.setUp()
    let ctx = PluginContext()
    let args = "{\"to\":\"bob@x.com\",\"subject\":\"Hi\",\"body\":\"test\"}"
    let result = ctx.sendTool.run(args: args, ctx: ctx)
    #expect(result.contains("error"))
    #expect(result.contains("API key"))
  }

  @Test("resend_send fails without from_email")
  func sendFailsWithoutFromEmail() {
    MockHost.setUp()
    mockConfig["api_key"] = "re_test"
    let ctx = PluginContext()
    let args = "{\"to\":\"bob@x.com\",\"subject\":\"Hi\",\"body\":\"test\"}"
    let result = ctx.sendTool.run(args: args, ctx: ctx)
    #expect(result.contains("error"))
    #expect(result.contains("from_email"))
  }

  @Test("resend_send with CC adds CC to participants")
  func sendWithCC() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    mockConfig["api_key"] = "re_test"
    mockConfig["from_email"] = "agent@d.com"
    MockHost.pushSendEmailResponse(emailId: "email-cc")

    let ctx = PluginContext()
    let args = "{\"to\":\"bob@x.com\",\"subject\":\"Hi\",\"body\":\"test\",\"cc\":\"carol@x.com\"}"
    let result = ctx.sendTool.run(args: args, ctx: ctx)
    #expect(result.contains("email-cc"))

    let threads = DatabaseManager.listThreads()
    #expect(threads.first?.participants.contains("carol@x.com") == true)
  }

  // MARK: - resend_reply

  @Test("resend_reply replies to existing thread")
  func replyToThread() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    mockConfig["api_key"] = "re_test"
    mockConfig["from_email"] = "agent@d.com"

    DatabaseManager.createThread(
      threadId: "t-reply", subject: "Original",
      participants: ["alice@a.com", "agent@d.com"],
      messageId: "<msg-1>", refs: "<msg-1>"
    )
    DatabaseManager.insertMessage(
      threadId: "t-reply", emailId: "e-in", direction: "in",
      fromAddress: "alice@a.com", toAddress: ["agent@d.com"],
      ccAddress: [], bccAddress: [],
      subject: "Original", bodyText: "Question?", bodyHtml: nil,
      messageId: "<msg-1>", inReplyTo: nil, hasAttachments: false
    )
    MockHost.pushSendEmailResponse(emailId: "email-reply")

    let ctx = PluginContext()
    let args = "{\"thread_id\":\"t-reply\",\"body\":\"<p>Answer</p>\"}"
    let result = ctx.replyTool.run(args: args, ctx: ctx)
    #expect(result.contains("email-reply"))
    #expect(result.contains("t-reply"))
  }

  @Test("resend_reply with explicit to override")
  func replyWithToOverride() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    mockConfig["api_key"] = "re_test"
    mockConfig["from_email"] = "agent@d.com"

    DatabaseManager.createThread(
      threadId: "t-override", subject: "Test",
      participants: ["alice@a.com", "bob@b.com", "agent@d.com"],
      messageId: "<msg-x>", refs: "<msg-x>"
    )
    MockHost.pushSendEmailResponse(emailId: "email-override")

    let ctx = PluginContext()
    let args = "{\"thread_id\":\"t-override\",\"body\":\"Private reply\",\"to\":\"alice@a.com\"}"
    let result = ctx.replyTool.run(args: args, ctx: ctx)
    #expect(result.contains("email-override"))
  }

  @Test("resend_reply fails for nonexistent thread")
  func replyFailsNoThread() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    mockConfig["api_key"] = "re_test"
    mockConfig["from_email"] = "agent@d.com"

    let ctx = PluginContext()
    let args = "{\"thread_id\":\"nonexistent\",\"body\":\"test\"}"
    let result = ctx.replyTool.run(args: args, ctx: ctx)
    #expect(result.contains("error"))
    #expect(result.contains("Thread not found"))
  }

  @Test("resend_reply auto-attaches artifacts")
  func replyAttachesArtifacts() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    mockConfig["api_key"] = "re_test"
    mockConfig["from_email"] = "agent@d.com"

    DatabaseManager.createThread(
      threadId: "t-art", subject: "Artifacts",
      participants: ["alice@a.com", "agent@d.com"],
      messageId: "<msg-a>", refs: "<msg-a>"
    )
    DatabaseManager.updateThread(threadId: "t-art", taskId: "task-art")
    DatabaseManager.insertMessage(
      threadId: "t-art", emailId: "e-in", direction: "in",
      fromAddress: "alice@a.com", toAddress: ["agent@d.com"],
      ccAddress: [], bccAddress: [],
      subject: "Artifacts", bodyText: "Send file", bodyHtml: nil,
      messageId: "<msg-a>", inReplyTo: nil, hasAttachments: false
    )
    MockHost.pushSendEmailResponse(emailId: "email-art")

    let ctx = PluginContext()
    ctx.taskArtifacts["task-art"] = [
      CollectedArtifact(
        filename: "report.pdf", data: Data("pdf-content".utf8), mimeType: "application/pdf")
    ]

    let args = "{\"thread_id\":\"t-art\",\"body\":\"Here is the report\"}"
    let result = ctx.replyTool.run(args: args, ctx: ctx)
    #expect(result.contains("email-art"))
    #expect(ctx.taskArtifacts["task-art"]?.isEmpty == true)
  }

  // MARK: - resend_list_threads

  @Test("resend_list_threads returns all threads")
  func listThreadsAll() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    DatabaseManager.createThread(
      threadId: "t-l1", subject: "Thread 1", participants: ["a@a.com"], messageId: nil, refs: nil)
    DatabaseManager.createThread(
      threadId: "t-l2", subject: "Thread 2", participants: ["b@b.com"], messageId: nil, refs: nil)

    let tool = ResendListThreadsTool()
    let result = tool.run(args: "{}")
    #expect(result.contains("t-l1"))
    #expect(result.contains("t-l2"))
  }

  @Test("resend_list_threads filters by participant")
  func listThreadsByParticipant() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    DatabaseManager.createThread(
      threadId: "t-p1", subject: "Alice", participants: ["alice@a.com"], messageId: nil, refs: nil)
    DatabaseManager.createThread(
      threadId: "t-p2", subject: "Bob", participants: ["bob@b.com"], messageId: nil, refs: nil)

    let tool = ResendListThreadsTool()
    let result = tool.run(args: "{\"participant\":\"alice@a.com\"}")
    #expect(result.contains("t-p1"))
    #expect(!result.contains("t-p2"))
  }

  @Test("resend_list_threads filters by label")
  func listThreadsByLabel() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    DatabaseManager.createThread(
      threadId: "t-lb1", subject: "Urgent", participants: ["a@a.com"], messageId: nil, refs: nil)
    DatabaseManager.updateThread(threadId: "t-lb1", labels: ["urgent"])
    DatabaseManager.createThread(
      threadId: "t-lb2", subject: "Normal", participants: ["b@b.com"], messageId: nil, refs: nil)

    let tool = ResendListThreadsTool()
    let result = tool.run(args: "{\"label\":\"urgent\"}")
    #expect(result.contains("t-lb1"))
    #expect(!result.contains("t-lb2"))
  }

  // MARK: - resend_get_thread

  @Test("resend_get_thread returns full thread with messages")
  func getThreadFull() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    DatabaseManager.createThread(
      threadId: "t-get", subject: "Full thread",
      participants: ["alice@a.com"], messageId: nil, refs: nil
    )
    DatabaseManager.insertMessage(
      threadId: "t-get", emailId: "e-g1", direction: "in",
      fromAddress: "alice@a.com", toAddress: ["agent@d.com"],
      ccAddress: [], bccAddress: [],
      subject: "Full thread", bodyText: "Message body text", bodyHtml: nil,
      messageId: "<g-1>", inReplyTo: nil, hasAttachments: false
    )

    let tool = ResendGetThreadTool()
    let result = tool.run(args: "{\"thread_id\":\"t-get\"}")
    #expect(result.contains("t-get"))
    #expect(result.contains("Full thread"))
    #expect(result.contains("Message body text"))
    #expect(result.contains("alice@a.com"))
  }

  @Test("resend_get_thread fails for nonexistent thread")
  func getThreadNotFound() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    let tool = ResendGetThreadTool()
    let result = tool.run(args: "{\"thread_id\":\"nope\"}")
    #expect(result.contains("error"))
    #expect(result.contains("Thread not found"))
  }

  // MARK: - resend_label_thread

  @Test("resend_label_thread adds labels")
  func labelThreadAdd() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    DatabaseManager.createThread(
      threadId: "t-label", subject: "Label me",
      participants: ["a@a.com"], messageId: nil, refs: nil
    )

    let tool = ResendLabelThreadTool()
    let result = tool.run(args: "{\"thread_id\":\"t-label\",\"add\":[\"urgent\",\"invoices\"]}")
    #expect(result.contains("urgent"))
    #expect(result.contains("invoices"))

    let thread = DatabaseManager.getThread(threadId: "t-label")
    #expect(thread?.labels.contains("urgent") == true)
    #expect(thread?.labels.contains("invoices") == true)
  }

  @Test("resend_label_thread removes labels")
  func labelThreadRemove() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    DatabaseManager.createThread(
      threadId: "t-unlabel", subject: "Unlabel me",
      participants: ["a@a.com"], messageId: nil, refs: nil
    )
    DatabaseManager.updateThread(threadId: "t-unlabel", labels: ["keep", "remove_me"])

    let tool = ResendLabelThreadTool()
    let result = tool.run(args: "{\"thread_id\":\"t-unlabel\",\"remove\":[\"remove_me\"]}")
    #expect(result.contains("keep"))
    #expect(!result.contains("remove_me"))
  }

  @Test("resend_label_thread adds and removes simultaneously")
  func labelThreadAddAndRemove() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    DatabaseManager.createThread(
      threadId: "t-both", subject: "Both ops",
      participants: ["a@a.com"], messageId: nil, refs: nil
    )
    DatabaseManager.updateThread(threadId: "t-both", labels: ["old_label"])

    let tool = ResendLabelThreadTool()
    let result = tool.run(
      args: "{\"thread_id\":\"t-both\",\"add\":[\"new_label\"],\"remove\":[\"old_label\"]}")
    #expect(result.contains("new_label"))
    #expect(!result.contains("old_label"))
  }
}
