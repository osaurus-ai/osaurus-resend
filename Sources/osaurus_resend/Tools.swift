import Foundation

// MARK: - resend_send

struct ResendSendTool {
  let name = "resend_send"

  struct Args: Decodable {
    let to: String
    let subject: String
    let body: String
    let cc: String?
    let bcc: String?
  }

  func run(args: String, ctx: PluginContext) -> String {
    logDebug("resend_send: args=\(String(args.prefix(200)))")
    guard let input = parseJSON(args, as: Args.self) else {
      return "{\"error\":\"Invalid arguments\"}"
    }

    guard let apiKey = configGet("api_key"), !apiKey.isEmpty else {
      return "{\"error\":\"API key not configured\"}"
    }
    guard let fromEmail = configGet("from_email"), !fromEmail.isEmpty else {
      return "{\"error\":\"from_email not configured\"}"
    }

    let fromName = configGet("from_name") ?? ""
    let from = fromName.isEmpty ? fromEmail : "\(fromName) <\(fromEmail)>"
    let toList = [input.to]
    let ccList = input.cc.map { [$0] }
    let bccList = input.bcc.map { [$0] }

    let params = SendEmailParams(
      from: from, to: toList, subject: input.subject,
      html: input.body, text: nil,
      cc: ccList, bcc: bccList, replyTo: [fromEmail],
      headers: nil, attachments: nil
    )

    let (emailId, error) = resendSendEmail(apiKey: apiKey, params: params)
    guard let emailId else {
      return "{\"error\":\"\(escapeJSON(error ?? "Send failed"))\"}"
    }

    let threadId = UUID().uuidString
    var allParticipants = Set([fromEmail.lowercased(), input.to.lowercased()])
    if let cc = input.cc { allParticipants.insert(cc.lowercased()) }

    DatabaseManager.createThread(
      threadId: threadId, subject: input.subject,
      participants: Array(allParticipants),
      messageId: nil, refs: nil
    )

    DatabaseManager.insertMessage(
      threadId: threadId, emailId: emailId, direction: "out",
      fromAddress: fromEmail, toAddress: toList,
      ccAddress: ccList ?? [], bccAddress: bccList ?? [],
      subject: input.subject, bodyText: nil, bodyHtml: input.body,
      messageId: nil, inReplyTo: nil, hasAttachments: false
    )

    logInfo("resend_send: sent to \(input.to), thread=\(threadId)")
    return "{\"thread_id\":\"\(threadId)\",\"email_id\":\"\(emailId)\"}"
  }
}

// MARK: - resend_reply

struct ResendReplyTool {
  let name = "resend_reply"

  struct Args: Decodable {
    let thread_id: String
    let body: String
    let to: String?
  }

  func run(args: String, ctx: PluginContext) -> String {
    logDebug("resend_reply: args=\(String(args.prefix(200)))")
    guard let input = parseJSON(args, as: Args.self) else {
      return "{\"error\":\"Invalid arguments\"}"
    }

    guard let apiKey = configGet("api_key"), !apiKey.isEmpty else {
      return "{\"error\":\"API key not configured\"}"
    }
    guard let fromEmail = configGet("from_email"), !fromEmail.isEmpty else {
      return "{\"error\":\"from_email not configured\"}"
    }

    guard let thread = DatabaseManager.getThread(threadId: input.thread_id) else {
      return "{\"error\":\"Thread not found\"}"
    }

    let fromName = configGet("from_name") ?? ""
    let from = fromName.isEmpty ? fromEmail : "\(fromName) <\(fromEmail)>"
    let fromLower = fromEmail.lowercased()

    let toList: [String]
    var ccList: [String] = []

    if let explicitTo = input.to {
      toList = [explicitTo]
    } else {
      let lastInbound = DatabaseManager.getLastInboundMessage(threadId: input.thread_id)
      if let lastFrom = lastInbound?.fromAddress {
        let replyTo = extractEmailAddress(lastFrom)
        toList = [replyTo]
        ccList = thread.participants.filter {
          $0.lowercased() != fromLower && $0.lowercased() != replyTo.lowercased()
        }
      } else {
        toList = thread.participants.filter { $0.lowercased() != fromLower }
        if toList.isEmpty {
          return "{\"error\":\"No recipients found in thread\"}"
        }
      }
    }

    let subject =
      thread.subject.map { sub in
        sub.hasPrefix("Re:") ? sub : "Re: \(sub)"
      } ?? "Re:"

    var headers: [String: String] = [:]
    if let lastMsgId = thread.lastMessageId {
      headers["In-Reply-To"] = lastMsgId
    }
    if let refs = thread.refs {
      if let lastMsgId = thread.lastMessageId, !refs.contains(lastMsgId) {
        headers["References"] = "\(refs) \(lastMsgId)"
      } else {
        headers["References"] = refs
      }
    } else if let lastMsgId = thread.lastMessageId {
      headers["References"] = lastMsgId
    }

    var attachments: [EmailAttachment] = []
    if let taskId = thread.taskId,
      let collected = ctx.taskArtifacts[taskId], !collected.isEmpty
    {
      for artifact in collected {
        attachments.append(
          EmailAttachment(
            filename: artifact.filename,
            content: artifact.data.base64EncodedString(),
            contentType: artifact.mimeType
          ))
      }
      ctx.taskArtifacts[taskId] = []
      logDebug("resend_reply: attached \(attachments.count) artifacts")
    }

    let params = SendEmailParams(
      from: from, to: toList, subject: subject,
      html: input.body, text: nil,
      cc: ccList.isEmpty ? nil : ccList, bcc: nil,
      replyTo: [fromEmail],
      headers: headers.isEmpty ? nil : headers,
      attachments: attachments.isEmpty ? nil : attachments
    )

    let (emailId, error) = resendSendEmail(apiKey: apiKey, params: params)
    guard let emailId else {
      return "{\"error\":\"\(escapeJSON(error ?? "Reply failed"))\"}"
    }

    DatabaseManager.insertMessage(
      threadId: input.thread_id, emailId: emailId, direction: "out",
      fromAddress: fromEmail, toAddress: toList,
      ccAddress: ccList, bccAddress: [],
      subject: subject, bodyText: nil, bodyHtml: input.body,
      messageId: nil, inReplyTo: thread.lastMessageId,
      hasAttachments: !attachments.isEmpty
    )

    var updatedParticipants = Set(thread.participants.map { $0.lowercased() })
    for addr in toList + ccList { updatedParticipants.insert(addr.lowercased()) }

    DatabaseManager.updateThread(
      threadId: input.thread_id,
      participants: Array(updatedParticipants)
    )

    logInfo("resend_reply: replied in thread \(input.thread_id)")
    return "{\"thread_id\":\"\(input.thread_id)\",\"email_id\":\"\(emailId)\"}"
  }
}

// MARK: - resend_list_threads

struct ResendListThreadsTool {
  let name = "resend_list_threads"

  struct Args: Decodable {
    let participant: String?
    let label: String?
    let limit: Int?
  }

  func run(args: String) -> String {
    logDebug("resend_list_threads: args=\(String(args.prefix(200)))")
    let input = parseJSON(args, as: Args.self)

    let threads = DatabaseManager.listThreads(
      participant: input?.participant,
      label: input?.label,
      limit: input?.limit ?? 20
    )

    var results: [[String: Any]] = []
    for thread in threads {
      let preview = DatabaseManager.getLastMessagePreview(threadId: thread.threadId)
      var entry: [String: Any] = [
        "thread_id": thread.threadId,
        "participants": thread.participants,
        "labels": thread.labels,
        "updated_at": thread.updatedAt ?? 0,
      ]
      if let subject = thread.subject { entry["subject"] = subject }
      if let preview { entry["last_message_preview"] = preview }
      results.append(entry)
    }

    guard let data = try? JSONSerialization.data(withJSONObject: ["threads": results]),
      let json = String(data: data, encoding: .utf8)
    else { return "{\"threads\":[]}" }
    return json
  }
}

// MARK: - resend_get_thread

struct ResendGetThreadTool {
  let name = "resend_get_thread"

  struct Args: Decodable {
    let thread_id: String
    let limit: Int?
  }

  func run(args: String) -> String {
    logDebug("resend_get_thread: args=\(String(args.prefix(200)))")
    guard let input = parseJSON(args, as: Args.self) else {
      return "{\"error\":\"Invalid arguments\"}"
    }

    guard let thread = DatabaseManager.getThread(threadId: input.thread_id) else {
      return "{\"error\":\"Thread not found\"}"
    }

    let messages = DatabaseManager.getMessages(
      threadId: input.thread_id, limit: input.limit ?? 20
    )

    let messageDicts: [[String: Any]] = messages.reversed().map { msg in
      var entry: [String: Any] = [
        "direction": msg.direction,
        "created_at": msg.createdAt ?? 0,
      ]
      if let from = msg.fromAddress { entry["from"] = from }
      if !msg.toAddress.isEmpty { entry["to"] = msg.toAddress }
      if !msg.ccAddress.isEmpty { entry["cc"] = msg.ccAddress }
      if let subject = msg.subject { entry["subject"] = subject }
      if let text = msg.bodyText {
        entry["body_text"] = text
      } else if let html = msg.bodyHtml {
        entry["body_text"] = html
      }
      if msg.hasAttachments { entry["has_attachments"] = true }
      return entry
    }

    var result: [String: Any] = [
      "thread_id": thread.threadId,
      "participants": thread.participants,
      "labels": thread.labels,
      "messages": messageDicts,
    ]
    if let subject = thread.subject { result["subject"] = subject }

    guard let data = try? JSONSerialization.data(withJSONObject: result),
      let json = String(data: data, encoding: .utf8)
    else { return "{\"error\":\"Serialization failed\"}" }
    return json
  }
}

// MARK: - resend_label_thread

struct ResendLabelThreadTool {
  let name = "resend_label_thread"

  struct Args: Decodable {
    let thread_id: String
    let add: [String]?
    let remove: [String]?
  }

  func run(args: String) -> String {
    logDebug("resend_label_thread: args=\(String(args.prefix(200)))")
    guard let input = parseJSON(args, as: Args.self) else {
      return "{\"error\":\"Invalid arguments\"}"
    }

    guard let thread = DatabaseManager.getThread(threadId: input.thread_id) else {
      return "{\"error\":\"Thread not found\"}"
    }

    var labels = Set(thread.labels)
    if let add = input.add { for l in add { labels.insert(l) } }
    if let remove = input.remove { for l in remove { labels.remove(l) } }

    let updatedLabels = Array(labels).sorted()
    DatabaseManager.updateThread(threadId: input.thread_id, labels: updatedLabels)

    guard
      let data = try? JSONSerialization.data(withJSONObject: [
        "thread_id": input.thread_id,
        "labels": updatedLabels,
      ]),
      let json = String(data: data, encoding: .utf8)
    else { return "{\"error\":\"Serialization failed\"}" }
    return json
  }
}
