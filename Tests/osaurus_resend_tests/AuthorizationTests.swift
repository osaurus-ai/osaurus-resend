import Testing
import Foundation
@testable import osaurus_resend

@Suite("Authorization", .serialized)
struct AuthorizationTests {

    @Test("Open policy authorizes any sender")
    func openPolicyAuthorizesAll() {
        MockHost.setUp()
        mockConfig["sender_policy"] = "open"
        #expect(isAuthorized(sender: "random@stranger.com") == true)
        #expect(isAuthorized(sender: "anyone@anywhere.org") == true)
    }

    @Test("Known policy with exact email match in allowed_senders")
    func allowedSenderExactMatch() {
        MockHost.setUp()
        mockConfig["sender_policy"] = "known"
        mockConfig["allowed_senders"] = "alice@example.com, bob@test.com"
        #expect(isAuthorized(sender: "alice@example.com") == true)
        #expect(isAuthorized(sender: "bob@test.com") == true)
        #expect(isAuthorized(sender: "Alice@Example.com") == true) // case insensitive
    }

    @Test("Known policy with domain match in allowed_senders")
    func allowedSenderDomainMatch() {
        MockHost.setUp()
        mockConfig["sender_policy"] = "known"
        mockConfig["allowed_senders"] = "@company.com"
        #expect(isAuthorized(sender: "anyone@company.com") == true)
        #expect(isAuthorized(sender: "ceo@company.com") == true)
        #expect(isAuthorized(sender: "someone@other.com") == false)
    }

    @Test("Known policy authorizes via outbound message history")
    func authorizedViaOutboundHistory() {
        MockHost.setUp()
        mockConfig["sender_policy"] = "known"
        // Simulate the agent having previously sent to bob@reply.com
        mockMessages.append([
            "id": 1, "thread_id": "t1", "email_id": "e1",
            "direction": "out", "from_address": "agent@domain.com",
            "to_address": "[\"bob@reply.com\"]",
            "cc_address": "[]", "bcc_address": "[]",
            "subject": "Hi", "body_text": "Hello",
            "body_html": NSNull(), "message_id": NSNull(),
            "in_reply_to": NSNull(), "has_attachments": 0,
            "created_at": Int(Date().timeIntervalSince1970),
        ])
        #expect(isAuthorized(sender: "bob@reply.com") == true)
    }

    @Test("Known policy authorizes via thread participation")
    func authorizedViaThreadParticipation() {
        MockHost.setUp()
        mockConfig["sender_policy"] = "known"
        // Bob is a participant in an existing thread (e.g., was CC'd)
        mockThreads.append([
            "thread_id": "t1", "subject": "Meeting",
            "participants": "[\"alice@example.com\",\"bob@cc.com\"]",
            "last_message_id": NSNull(), "refs": NSNull(),
            "task_id": NSNull(), "labels": "[]",
            "created_at": Int(Date().timeIntervalSince1970),
            "updated_at": Int(Date().timeIntervalSince1970),
        ])
        #expect(isAuthorized(sender: "bob@cc.com") == true)
    }

    @Test("Known policy rejects unauthorized sender")
    func unauthorizedSenderRejected() {
        MockHost.setUp()
        mockConfig["sender_policy"] = "known"
        mockConfig["allowed_senders"] = "alice@example.com"
        #expect(isAuthorized(sender: "stranger@evil.com") == false)
    }

    @Test("Default policy is known when not configured")
    func defaultPolicyIsKnown() {
        MockHost.setUp()
        // No sender_policy set -- defaults to "known"
        #expect(isAuthorized(sender: "stranger@evil.com") == false)
        mockConfig["allowed_senders"] = "stranger@evil.com"
        #expect(isAuthorized(sender: "stranger@evil.com") == true)
    }

    @Test("Mixed allowed_senders with emails and domains")
    func mixedAllowedSenders() {
        MockHost.setUp()
        mockConfig["sender_policy"] = "known"
        mockConfig["allowed_senders"] = "specific@person.com, @trusted.org"
        #expect(isAuthorized(sender: "specific@person.com") == true)
        #expect(isAuthorized(sender: "anyone@trusted.org") == true)
        #expect(isAuthorized(sender: "other@untrusted.com") == false)
    }
}
