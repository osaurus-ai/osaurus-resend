import Foundation

// MARK: - Resend Webhook Event

struct ResendWebhookEvent: Decodable {
  let type: String
  let created_at: String?
  let data: ResendEmailEventData
}

struct ResendEmailEventData: Decodable {
  let email_id: String
  let created_at: String?
  let from: String?
  let to: [String]?
  let cc: [String]?
  let bcc: [String]?
  let subject: String?
  let message_id: String?
  let attachments: [ResendAttachmentMeta]?
  let bounce: ResendBounceInfo?

  /// Convenience accessor for the bounce message (if this event is a bounce).
  var bounce_message: String? { bounce?.message }
}

struct ResendBounceInfo: Decodable {
  let message: String?
  let subType: String?
  let type: String?
}

struct ResendAttachmentMeta: Decodable {
  let id: String
  let filename: String?
  let content_type: String?
  let content_disposition: String?
  let content_id: String?
}

// MARK: - Resend Received Email Response

struct ResendReceivedEmail: Decodable {
  let id: String?
  let from: String?
  let to: [String]?
  let cc: [String]?
  let bcc: [String]?
  let subject: String?
  let html: String?
  let text: String?
  let headers: [String: String]?
  let message_id: String?
  let reply_to: [String]?
  let attachments: [ResendAttachmentMeta]?
}

// MARK: - Route Request / Response

struct OsaurusRequestContext: Decodable {
  let base_url: String?
  let plugin_url: String?
  let agent_address: String?
}

struct RouteRequest: Decodable {
  let route_id: String
  let method: String
  let path: String
  let query: [String: String]?
  let headers: [String: String]?
  let body: String?
  let plugin_id: String?
  let osaurus: OsaurusRequestContext?
}

// MARK: - Dispatch Response

struct DispatchResponse: Decodable {
  let id: String?
  let status: String?
}

// MARK: - Task Event Payloads

struct TaskCompletedEvent: Decodable {
  let success: Bool?
  let summary: String?
  let output: String?
  let session_id: String?
  let title: String?
}

// MARK: - Artifact Payload

struct ArtifactPayload: Decodable {
  let filename: String
  let host_path: String
  let mime_type: String?
  let size: Int?
  let is_directory: Bool?
}

// MARK: - DB Row Types

struct ThreadRow {
  let threadId: String
  let subject: String?
  let participants: [String]
  let lastMessageId: String?
  let refs: String?
  let taskId: String?
  let labels: [String]
  let createdAt: Int?
  let updatedAt: Int?
}

struct MessageRow {
  let id: Int?
  let threadId: String
  let emailId: String?
  let direction: String
  let fromAddress: String?
  let toAddress: [String]
  let ccAddress: [String]
  let bccAddress: [String]
  let subject: String?
  let bodyText: String?
  let bodyHtml: String?
  let messageId: String?
  let inReplyTo: String?
  let hasAttachments: Bool
  let createdAt: Int?
}

// MARK: - Collected Artifact

struct CollectedArtifact {
  let filename: String
  let data: Data
  let mimeType: String
}
