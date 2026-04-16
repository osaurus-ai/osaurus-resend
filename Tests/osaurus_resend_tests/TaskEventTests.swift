import Testing
import Foundation
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
            CollectedArtifact(filename: "orphan.txt", data: Data("data".utf8), mimeType: "text/plain"),
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
            CollectedArtifact(filename: "report.pdf", data: Data("pdf".utf8), mimeType: "application/pdf"),
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

        handleTaskEvent(ctx: ctx, taskId: taskId, eventType: 4, eventJSON: "{\"success\":true,\"output\":\"data\"}")

        #expect(ctx.taskDispatchTimestamps[taskId] == nil)
        #expect(ctx.taskArtifacts[taskId] == nil)
    }
}
