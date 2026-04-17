import Foundation

// MARK: - Resend API Transport

func resendRequest(
  apiKey: String, method: String, path: String,
  body: [String: Any]? = nil
) -> (ok: Bool, data: [String: Any]?) {
  guard let httpRequest = hostAPI?.pointee.http_request else {
    logError("http_request not available")
    return (false, nil)
  }

  var request: [String: Any] = [
    "method": method,
    "url": "https://api.resend.com\(path)",
    "headers": [
      "Authorization": "Bearer \(apiKey)",
      "Content-Type": "application/json",
      "User-Agent": "osaurus-resend/0.1.0",
    ],
    "timeout_ms": 15000,
  ]

  if let body {
    if let bodyData = try? JSONSerialization.data(withJSONObject: body),
      let bodyStr = String(data: bodyData, encoding: .utf8)
    {
      request["body"] = bodyStr
    }
  }

  guard let requestJSON = makeJSONString(request) else {
    logError("Failed to serialize Resend request for \(path)")
    return (false, nil)
  }

  let responseStr: String? = requestJSON.withCString { ptr in
    guard let responsePtr = httpRequest(ptr) else { return nil }
    return String(cString: responsePtr)
  }
  guard let responseStr else {
    logError("No response from http_request for \(path)")
    return (false, nil)
  }

  guard let responseData = responseStr.data(using: .utf8),
    let httpResponse = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
  else {
    logError("Failed to parse http response for \(path)")
    return (false, nil)
  }

  let httpStatus = httpResponse["status"] as? Int ?? 0
  guard let httpBody = httpResponse["body"] as? String,
    let bodyData = httpBody.data(using: .utf8),
    let parsed = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
  else {
    logError("Resend \(path) returned non-JSON (HTTP \(httpStatus))")
    return (false, nil)
  }

  let ok = httpStatus >= 200 && httpStatus < 300
  if !ok {
    let errorMsg = (parsed["message"] as? String) ?? "unknown error"
    logWarn("Resend \(method) \(path) failed (HTTP \(httpStatus)): \(errorMsg)")
  }

  return (ok, parsed)
}

// MARK: - Send Email

struct SendEmailParams {
  let from: String
  let to: [String]
  let subject: String
  let html: String
  let text: String?
  let cc: [String]?
  let bcc: [String]?
  let replyTo: [String]?
  let headers: [String: String]?
  let attachments: [EmailAttachment]?
}

struct EmailAttachment {
  let filename: String
  let content: String  // base64
  let contentType: String?
}

func resendSendEmail(apiKey: String, params: SendEmailParams) -> (emailId: String?, error: String?)
{
  var body: [String: Any] = [
    "from": params.from,
    "to": params.to,
    "subject": params.subject,
    "html": params.html,
  ]
  if let text = params.text { body["text"] = text }
  if let cc = params.cc, !cc.isEmpty { body["cc"] = cc }
  if let bcc = params.bcc, !bcc.isEmpty { body["bcc"] = bcc }
  if let replyTo = params.replyTo, !replyTo.isEmpty { body["reply_to"] = replyTo }
  if let headers = params.headers, !headers.isEmpty { body["headers"] = headers }

  if let attachments = params.attachments, !attachments.isEmpty {
    let atts: [[String: Any]] = attachments.map { att in
      var d: [String: Any] = [
        "filename": att.filename,
        "content": att.content,
      ]
      if let ct = att.contentType { d["content_type"] = ct }
      return d
    }
    body["attachments"] = atts
  }

  let (ok, data) = resendRequest(apiKey: apiKey, method: "POST", path: "/emails", body: body)
  if ok, let id = data?["id"] as? String {
    logDebug("resendSendEmail: sent \(id)")
    return (id, nil)
  }
  let errorMsg = (data?["message"] as? String) ?? "Failed to send email"
  return (nil, errorMsg)
}

// MARK: - Get Received Email

func resendGetReceivedEmail(apiKey: String, emailId: String) -> ResendReceivedEmail? {
  let (ok, data) = resendRequest(
    apiKey: apiKey, method: "GET", path: "/emails/receiving/\(emailId)")
  guard ok, let data else { return nil }
  guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
    let email = try? JSONDecoder().decode(ResendReceivedEmail.self, from: jsonData)
  else {
    logWarn("resendGetReceivedEmail: failed to decode response")
    return nil
  }
  return email
}

// MARK: - Webhook Management

struct ResendWebhookSummary {
  let id: String
  let endpoint: String
  let events: [String]
}

func resendCreateWebhook(apiKey: String, endpoint: String) -> (
  webhookId: String?, signingSecret: String?
) {
  let body: [String: Any] = [
    "endpoint": endpoint,
    "events": ["email.received"],
  ]
  let (ok, data) = resendRequest(apiKey: apiKey, method: "POST", path: "/webhooks", body: body)
  guard ok, let data else { return (nil, nil) }
  let webhookId = data["id"] as? String
  let signingSecret = data["signing_secret"] as? String
  logDebug("resendCreateWebhook: id=\(webhookId ?? "nil")")
  return (webhookId, signingSecret)
}

func resendDeleteWebhook(apiKey: String, webhookId: String) -> Bool {
  let (ok, _) = resendRequest(apiKey: apiKey, method: "DELETE", path: "/webhooks/\(webhookId)")
  return ok
}

/// Lists all webhooks for the account.
/// Returns `nil` when the API call fails (so callers can distinguish transport failure
/// from "no webhooks").
func resendListWebhooks(apiKey: String) -> [ResendWebhookSummary]? {
  let (ok, data) = resendRequest(apiKey: apiKey, method: "GET", path: "/webhooks")
  guard ok, let data else { return nil }
  guard let rows = data["data"] as? [[String: Any]] else {
    logWarn("resendListWebhooks: response missing 'data' array")
    return []
  }
  return rows.compactMap { row in
    guard let id = row["id"] as? String,
      let endpoint = row["endpoint"] as? String
    else { return nil }
    let events = row["events"] as? [String] ?? []
    return ResendWebhookSummary(id: id, endpoint: endpoint, events: events)
  }
}

func resendUpdateWebhook(apiKey: String, webhookId: String, endpoint: String) -> Bool {
  let body: [String: Any] = [
    "endpoint": endpoint,
    "events": ["email.received"],
    "status": "enabled",
  ]
  let (ok, _) = resendRequest(
    apiKey: apiKey, method: "PATCH", path: "/webhooks/\(webhookId)", body: body)
  return ok
}
