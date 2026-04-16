import Testing
import Foundation
@testable import osaurus_resend

@Suite("Model Decoding", .serialized)
struct ModelTests {

    @Test("Decode ResendWebhookEvent")
    func decodeWebhookEvent() throws {
        let json = """
        {
          "type": "email.received",
          "created_at": "2026-02-22T23:41:12.126Z",
          "data": {
            "email_id": "abc-123",
            "from": "alice@example.com",
            "to": ["agent@domain.com"],
            "cc": ["bob@example.com"],
            "subject": "Hello",
            "message_id": "<msg-001@example.com>",
            "attachments": [
              {
                "id": "att-1",
                "filename": "report.pdf",
                "content_type": "application/pdf"
              }
            ]
          }
        }
        """
        let event = parseJSON(json, as: ResendWebhookEvent.self)
        #expect(event != nil)
        #expect(event?.type == "email.received")
        #expect(event?.data.email_id == "abc-123")
        #expect(event?.data.from == "alice@example.com")
        #expect(event?.data.to == ["agent@domain.com"])
        #expect(event?.data.cc == ["bob@example.com"])
        #expect(event?.data.subject == "Hello")
        #expect(event?.data.message_id == "<msg-001@example.com>")
        #expect(event?.data.attachments?.count == 1)
        #expect(event?.data.attachments?.first?.filename == "report.pdf")
    }

    @Test("Decode ResendWebhookEvent with minimal fields")
    func decodeWebhookEventMinimal() throws {
        let json = """
        {"type":"email.sent","data":{"email_id":"xyz"}}
        """
        let event = parseJSON(json, as: ResendWebhookEvent.self)
        #expect(event != nil)
        #expect(event?.type == "email.sent")
        #expect(event?.data.email_id == "xyz")
        #expect(event?.data.from == nil)
        #expect(event?.data.to == nil)
    }

    @Test("Decode ResendReceivedEmail")
    func decodeReceivedEmail() throws {
        let json = """
        {
          "id": "recv-001",
          "from": "Alice <alice@example.com>",
          "to": ["agent@domain.com"],
          "cc": [],
          "subject": "Meeting",
          "html": "<p>Let's meet</p>",
          "text": "Let's meet",
          "message_id": "<msg-001>",
          "headers": {"in-reply-to": "<prev-msg>"},
          "reply_to": ["alice@example.com"],
          "attachments": []
        }
        """
        let email = parseJSON(json, as: ResendReceivedEmail.self)
        #expect(email != nil)
        #expect(email?.id == "recv-001")
        #expect(email?.from == "Alice <alice@example.com>")
        #expect(email?.html == "<p>Let's meet</p>")
        #expect(email?.text == "Let's meet")
        #expect(email?.message_id == "<msg-001>")
        #expect(email?.headers?["in-reply-to"] == "<prev-msg>")
    }

    @Test("Decode RouteRequest")
    func decodeRouteRequest() throws {
        let json = """
        {
          "route_id": "webhook",
          "method": "POST",
          "path": "/webhook",
          "headers": {"Content-Type": "application/json"},
          "body": "test body",
          "plugin_id": "osaurus.resend",
          "osaurus": {
            "base_url": "https://example.com",
            "plugin_url": "https://example.com/plugins/osaurus.resend",
            "agent_address": "agent-1"
          }
        }
        """
        let req = parseJSON(json, as: RouteRequest.self)
        #expect(req != nil)
        #expect(req?.route_id == "webhook")
        #expect(req?.method == "POST")
        #expect(req?.body == "test body")
        #expect(req?.osaurus?.agent_address == "agent-1")
        #expect(req?.osaurus?.plugin_url == "https://example.com/plugins/osaurus.resend")
    }

    @Test("Decode ArtifactPayload")
    func decodeArtifactPayload() throws {
        let json = """
        {
          "filename": "report.csv",
          "host_path": "/tmp/artifacts/report.csv",
          "mime_type": "text/csv",
          "size": 1024,
          "is_directory": false
        }
        """
        let artifact = parseJSON(json, as: ArtifactPayload.self)
        #expect(artifact != nil)
        #expect(artifact?.filename == "report.csv")
        #expect(artifact?.host_path == "/tmp/artifacts/report.csv")
        #expect(artifact?.mime_type == "text/csv")
        #expect(artifact?.size == 1024)
        #expect(artifact?.is_directory == false)
    }

    @Test("Decode TaskCompletedEvent")
    func decodeTaskCompleted() throws {
        let json = """
        {"success":true,"summary":"Done","output":"<p>Result</p>","session_id":"s1","title":"Email task"}
        """
        let event = parseJSON(json, as: TaskCompletedEvent.self)
        #expect(event != nil)
        #expect(event?.success == true)
        #expect(event?.summary == "Done")
        #expect(event?.output == "<p>Result</p>")
        #expect(event?.session_id == "s1")
    }

    @Test("Decode DispatchResponse")
    func decodeDispatchResponse() throws {
        let json = """
        {"id":"task-abc","status":"running"}
        """
        let resp = parseJSON(json, as: DispatchResponse.self)
        #expect(resp != nil)
        #expect(resp?.id == "task-abc")
        #expect(resp?.status == "running")
    }
}
