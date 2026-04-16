import Foundation
import Testing

@testable import osaurus_resend

@Suite("Authorization", .serialized)
struct AuthorizationTests {

  // MARK: - Sender Policy

  @Test("Open policy with value 'open' authorizes any sender")
  func openPolicyAuthorizesAll() {
    MockHost.setUp()
    mockConfig["sender_policy"] = "open"
    #expect(isAuthorized(sender: "random@stranger.com") == true)
    #expect(isAuthorized(sender: "anyone@anywhere.org") == true)
  }

  @Test("Any non-'known' policy value acts as open (host may store label text)")
  func nonKnownPolicyActsAsOpen() {
    MockHost.setUp()
    mockConfig["sender_policy"] = "Accept all emails"
    #expect(isAuthorized(sender: "stranger@evil.com") == true)

    mockConfig["sender_policy"] = "something_else"
    #expect(isAuthorized(sender: "stranger@evil.com") == true)

    mockConfig["sender_policy"] = "1"
    #expect(isAuthorized(sender: "stranger@evil.com") == true)
  }

  @Test("Only exact value 'known' restricts senders")
  func onlyKnownRestricts() {
    MockHost.setUp()
    mockConfig["sender_policy"] = "known"
    #expect(isAuthorized(sender: "stranger@evil.com") == false)
  }

  @Test("Default policy (nil) restricts like 'known'")
  func defaultPolicyIsKnown() {
    MockHost.setUp()
    #expect(isAuthorized(sender: "stranger@evil.com") == false)
    mockConfig["allowed_senders"] = "stranger@evil.com"
    #expect(isAuthorized(sender: "stranger@evil.com") == true)
  }

  // MARK: - Allowed Senders (known policy)

  @Test("Known policy with exact email match in allowed_senders")
  func allowedSenderExactMatch() {
    MockHost.setUp()
    mockConfig["sender_policy"] = "known"
    mockConfig["allowed_senders"] = "alice@example.com, bob@test.com"
    #expect(isAuthorized(sender: "alice@example.com") == true)
    #expect(isAuthorized(sender: "bob@test.com") == true)
    #expect(isAuthorized(sender: "Alice@Example.com") == true)
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

  @Test("Mixed allowed_senders with emails and domains")
  func mixedAllowedSenders() {
    MockHost.setUp()
    mockConfig["sender_policy"] = "known"
    mockConfig["allowed_senders"] = "specific@person.com, @trusted.org"
    #expect(isAuthorized(sender: "specific@person.com") == true)
    #expect(isAuthorized(sender: "anyone@trusted.org") == true)
    #expect(isAuthorized(sender: "other@untrusted.com") == false)
  }

  // MARK: - Data-derived authorization (known policy)

  @Test("Known policy authorizes via outbound message history")
  func authorizedViaOutboundHistory() {
    MockHost.setUp()
    mockConfig["sender_policy"] = "known"
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

  @Test("Known policy rejects sender with no match on any check")
  func unauthorizedSenderRejected() {
    MockHost.setUp()
    mockConfig["sender_policy"] = "known"
    mockConfig["allowed_senders"] = "alice@example.com"
    #expect(isAuthorized(sender: "stranger@evil.com") == false)
  }

  // MARK: - Policy change at runtime

  @Test("Changing policy from known to open at runtime takes effect")
  func policyChangeHonored() {
    MockHost.setUp()
    mockConfig["sender_policy"] = "known"
    #expect(isAuthorized(sender: "stranger@evil.com") == false)

    mockConfig["sender_policy"] = "open"
    #expect(isAuthorized(sender: "stranger@evil.com") == true)

    mockConfig["sender_policy"] = "known"
    #expect(isAuthorized(sender: "stranger@evil.com") == false)
  }

  @Test("Changing allowed_senders at runtime takes effect")
  func allowedSendersChangeHonored() {
    MockHost.setUp()
    mockConfig["sender_policy"] = "known"
    #expect(isAuthorized(sender: "new@person.com") == false)

    mockConfig["allowed_senders"] = "new@person.com"
    #expect(isAuthorized(sender: "new@person.com") == true)

    mockConfig["allowed_senders"] = ""
    #expect(isAuthorized(sender: "new@person.com") == false)
  }
}
