import Foundation

// MARK: - Route Handler

func handleRoute(ctx: PluginContext, requestJSON: String) -> String {
  guard let req = parseJSON(requestJSON, as: RouteRequest.self) else {
    logWarn("handleRoute: failed to parse request")
    return makeRouteResponse(status: 400, body: "{\"error\":\"Invalid request\"}")
  }

  switch req.route_id {
  case "webhook":
    return handleWebhook(ctx: ctx, req: req)
  case "health":
    return handleHealth(ctx: ctx)
  default:
    return makeRouteResponse(status: 404, body: "{\"error\":\"Not found\"}")
  }
}

// MARK: - Webhook Endpoint

private func handleWebhook(ctx: PluginContext, req: RouteRequest) -> String {
  guard let body = req.body, !body.isEmpty else {
    logWarn("handleWebhook: empty body")
    return makeRouteResponse(status: 200, body: "ok")
  }

  guard let event = parseJSON(body, as: ResendWebhookEvent.self) else {
    logWarn("handleWebhook: failed to parse event")
    return makeRouteResponse(status: 200, body: "ok")
  }

  guard event.type == "email.received" else {
    logDebug("handleWebhook: ignoring event type \(event.type)")
    return makeRouteResponse(status: 200, body: "ok")
  }

  let emailId = event.data.email_id
  if DatabaseManager.hasEmailId(emailId) {
    logDebug("handleWebhook: skipping already-processed email_id=\(emailId)")
    return makeRouteResponse(status: 200, body: "ok")
  }

  let agentAddress = req.osaurus?.agent_address
  logDebug("handleWebhook: processing email_id=\(emailId)")

  processInboundEmail(ctx: ctx, eventData: event.data, agentAddress: agentAddress)

  return makeRouteResponse(status: 200, body: "ok")
}

// MARK: - Inbound Email Processing

private func processInboundEmail(
  ctx: PluginContext, eventData: ResendEmailEventData, agentAddress: String?
) {
  let senderRaw = eventData.from ?? ""
  let senderEmail = extractEmailAddress(senderRaw)

  if !isAuthorized(sender: senderEmail) {
    logInfo("Unauthorized sender \(senderEmail), ignoring")
    return
  }

  guard let apiKey = configGet("api_key"), !apiKey.isEmpty else {
    logError("processInboundEmail: no API key configured")
    return
  }

  guard let receivedEmail = resendGetReceivedEmail(apiKey: apiKey, emailId: eventData.email_id)
  else {
    logError("processInboundEmail: failed to fetch email body for \(eventData.email_id)")
    return
  }

  let fromAddress = receivedEmail.from ?? senderRaw
  let toAddresses = receivedEmail.to ?? eventData.to ?? []
  let ccAddresses = receivedEmail.cc ?? eventData.cc ?? []
  let subject = receivedEmail.subject ?? eventData.subject
  let messageId = receivedEmail.message_id ?? eventData.message_id
  let bodyText = receivedEmail.text
  let bodyHtml = receivedEmail.html
  let hasAttachments = !(receivedEmail.attachments ?? []).isEmpty

  let inReplyTo =
    receivedEmail.headers?["in-reply-to"]
    ?? receivedEmail.headers?["In-Reply-To"]

  let fromEmail = extractEmailAddress(fromAddress)
  let agentEmail = (configGet("from_email") ?? "").lowercased()

  var thread: ThreadRow?
  if let inReplyTo {
    thread = DatabaseManager.getThreadByMessageId(inReplyTo)
  }

  let allAddresses = Set(
    ([fromEmail] + toAddresses.map { extractEmailAddress($0) }
      + ccAddresses.map { extractEmailAddress($0) })
      .map { $0.lowercased() }
      .filter { !$0.isEmpty && $0 != agentEmail }
  )

  let threadId: String
  if let existing = thread {
    threadId = existing.threadId
    var updatedParticipants = Set(existing.participants.map { $0.lowercased() })
    for addr in allAddresses { updatedParticipants.insert(addr) }

    var updatedRefs = existing.refs ?? ""
    if let msgId = messageId, !updatedRefs.contains(msgId) {
      updatedRefs = updatedRefs.isEmpty ? msgId : "\(updatedRefs) \(msgId)"
    }

    DatabaseManager.updateThread(
      threadId: threadId,
      lastMessageId: messageId,
      refs: updatedRefs,
      participants: Array(updatedParticipants)
    )
    logDebug("processInboundEmail: joined thread \(threadId)")
  } else {
    threadId = UUID().uuidString
    DatabaseManager.createThread(
      threadId: threadId, subject: subject,
      participants: Array(allAddresses),
      messageId: messageId, refs: messageId
    )
    logDebug("processInboundEmail: created thread \(threadId)")
  }

  DatabaseManager.insertMessage(
    threadId: threadId, emailId: eventData.email_id, direction: "in",
    fromAddress: fromAddress, toAddress: toAddresses, ccAddress: ccAddresses, bccAddress: [],
    subject: subject, bodyText: bodyText, bodyHtml: bodyHtml,
    messageId: messageId, inReplyTo: inReplyTo, hasAttachments: hasAttachments
  )

  let prompt = buildEmailPrompt(
    from: fromAddress, subject: subject,
    bodyText: bodyText, bodyHtml: bodyHtml,
    threadId: threadId
  )

  guard let dispatch = hostAPI?.pointee.dispatch else {
    logError("processInboundEmail: dispatch not available")
    return
  }

  let titleText = subject ?? "Email from \(fromEmail)"
  var dispatchPayload: [String: Any] = [
    "prompt": prompt,
    "mode": "work",
    "title": "Email: \(String(titleText.prefix(60)))",
  ]
  if let agentAddress { dispatchPayload["agent_address"] = agentAddress }

  guard let dispatchJSON = makeJSONString(dispatchPayload) else {
    logError("processInboundEmail: failed to serialize dispatch payload")
    return
  }

  let resultStr: String? = dispatchJSON.withCString { ptr in
    guard let resultPtr = dispatch(ptr) else { return nil }
    return String(cString: resultPtr)
  }
  guard let resultStr,
    let dispatchResult = parseJSON(resultStr, as: DispatchResponse.self),
    let taskId = dispatchResult.id
  else {
    logError("processInboundEmail: dispatch failed")
    return
  }

  DatabaseManager.updateThread(threadId: threadId, taskId: taskId)
  ctx.taskDispatchTimestamps[taskId] = Int(Date().timeIntervalSince1970)
  logInfo("Dispatched task \(taskId) for email from \(fromEmail) in thread \(threadId)")
}

// MARK: - Authorization

func isAuthorized(sender: String) -> Bool {
  let policyRaw = configGet("sender_policy")
  let policy = policyRaw ?? "known"
  logDebug("isAuthorized: sender=\(sender) sender_policy='\(policy)' (raw=\(policyRaw ?? "nil"))")

  if policy != "known" {
    logDebug("isAuthorized: policy is not 'known', accepting all senders")
    return true
  }

  let senderLower = sender.lowercased()

  let allowedStr = configGet("allowed_senders")
  logDebug("isAuthorized: allowed_senders='\(allowedStr ?? "nil")'")

  if let allowedStr, !allowedStr.isEmpty {
    let allowed = allowedStr.split(separator: ",").map {
      $0.trimmingCharacters(in: .whitespaces).lowercased()
    }
    for entry in allowed {
      if entry.hasPrefix("@") {
        if senderLower.hasSuffix(entry) { return true }
      } else {
        if senderLower == entry { return true }
      }
    }
  }

  if DatabaseManager.hasSentTo(address: senderLower) {
    return true
  }

  if DatabaseManager.isParticipantInAnyThread(address: senderLower) {
    return true
  }

  return false
}

// MARK: - Prompt Builder

private func buildEmailPrompt(
  from: String, subject: String?,
  bodyText: String?, bodyHtml: String?,
  threadId: String
) -> String {
  var parts: [String] = []

  parts.append("You received an email. Read it and take appropriate action.")
  parts.append("")
  parts.append("From: \(from)")
  if let subject { parts.append("Subject: \(subject)") }
  parts.append("Thread ID: \(threadId)")
  parts.append("")

  let body = bodyText ?? bodyHtml ?? "(empty body)"
  parts.append("--- Email Body ---")
  parts.append(body)
  parts.append("--- End Email Body ---")

  let history = DatabaseManager.getMessages(threadId: threadId, limit: 10)
  if history.count > 1 {
    parts.append("")
    parts.append("--- Prior Thread History (most recent first) ---")
    for msg in history.dropFirst().prefix(9) {
      let dir = msg.direction == "in" ? "From" : "To"
      let addr =
        msg.direction == "in"
        ? (msg.fromAddress ?? "unknown")
        : (msg.toAddress.first ?? "unknown")
      let preview = String((msg.bodyText ?? msg.bodyHtml ?? "").prefix(500))
      parts.append("[\(dir): \(addr)] \(preview)")
    }
    parts.append("--- End Thread History ---")
  }

  parts.append("")
  parts.append("To reply to this email, call resend_reply with thread_id \"\(threadId)\".")

  return parts.joined(separator: "\n")
}

// MARK: - Task Event Handler

func handleTaskEvent(ctx: PluginContext, taskId: String, eventType: Int32, eventJSON: String) {
  switch eventType {
  case 4:  // COMPLETED
    handleTaskCompleted(ctx: ctx, taskId: taskId, eventJSON: eventJSON)
  case 5:  // FAILED
    handleTaskFailed(ctx: ctx, taskId: taskId, eventJSON: eventJSON)
  case 6:  // CANCELLED
    handleTaskFailed(ctx: ctx, taskId: taskId, eventJSON: eventJSON)
  default:
    break
  }
}

private func handleTaskCompleted(ctx: PluginContext, taskId: String, eventJSON: String) {
  defer {
    ctx.taskArtifacts.removeValue(forKey: taskId)
    ctx.taskDispatchTimestamps.removeValue(forKey: taskId)
  }

  guard let thread = DatabaseManager.getThreadByTaskId(taskId) else {
    logDebug("handleTaskCompleted: no thread for task \(taskId)")
    return
  }

  defer { DatabaseManager.clearTaskId(threadId: thread.threadId) }

  let dispatchTime = ctx.taskDispatchTimestamps[taskId] ?? 0
  if DatabaseManager.hasOutboundMessageSince(
    threadId: thread.threadId, sinceTimestamp: dispatchTime)
  {
    logDebug(
      "handleTaskCompleted: agent already replied in thread \(thread.threadId), skipping auto-reply"
    )
    return
  }

  let summary =
    parseJSON(eventJSON, as: TaskCompletedEvent.self)
    .map { $0.output ?? $0.summary ?? "" } ?? ""
  if summary.isEmpty {
    logDebug("handleTaskCompleted: empty summary, skipping auto-reply")
    return
  }

  guard let apiKey = configGet("api_key"), !apiKey.isEmpty,
    let fromEmail = configGet("from_email"), !fromEmail.isEmpty
  else {
    logWarn("handleTaskCompleted: missing config, cannot auto-reply")
    return
  }

  guard
    let recipients = computeReplyRecipients(
      thread: thread, fromEmail: fromEmail, explicitTo: nil)
  else {
    logWarn("handleTaskCompleted: no recipients for auto-reply")
    return
  }

  let from = formatFromAddress(name: configGet("from_name"), email: fromEmail)
  let subject = buildReplySubject(thread.subject)
  let headers = buildThreadingHeaders(lastMessageId: thread.lastMessageId, refs: thread.refs)
  let attachments = collectAndClearArtifacts(taskId: taskId, ctx: ctx)

  let params = SendEmailParams(
    from: from, to: recipients.to, subject: subject,
    html: summary, text: nil,
    cc: recipients.cc.isEmpty ? nil : recipients.cc, bcc: nil,
    replyTo: [fromEmail],
    headers: headers.isEmpty ? nil : headers,
    attachments: attachments.isEmpty ? nil : attachments
  )

  let (emailId, error) = resendSendEmail(apiKey: apiKey, params: params)
  guard let emailId else {
    logError("handleTaskCompleted: auto-reply failed: \(error ?? "unknown")")
    return
  }

  DatabaseManager.insertMessage(
    threadId: thread.threadId, emailId: emailId, direction: "out",
    fromAddress: fromEmail, toAddress: recipients.to, ccAddress: recipients.cc, bccAddress: [],
    subject: subject, bodyText: nil, bodyHtml: summary,
    messageId: nil, inReplyTo: thread.lastMessageId,
    hasAttachments: !attachments.isEmpty
  )
  logInfo("Auto-replied in thread \(thread.threadId) with \(attachments.count) attachments")
}

private func handleTaskFailed(ctx: PluginContext, taskId: String, eventJSON: String) {
  defer {
    ctx.taskArtifacts.removeValue(forKey: taskId)
    ctx.taskDispatchTimestamps.removeValue(forKey: taskId)
  }
  if let thread = DatabaseManager.getThreadByTaskId(taskId) {
    DatabaseManager.clearTaskId(threadId: thread.threadId)
    logInfo("Task \(taskId) failed/cancelled, no email sent")
  }
}

// MARK: - Artifact Handler

func handleArtifactShare(ctx: PluginContext, payload: String) -> String {
  guard let artifact = parseJSON(payload, as: ArtifactPayload.self) else {
    logWarn("handleArtifactShare: failed to parse payload")
    return "{\"error\":\"Invalid artifact payload\"}"
  }

  if artifact.is_directory == true {
    return "{\"skipped\":true}"
  }

  let file: HostFileResult
  switch readHostFile(path: artifact.host_path) {
  case .success(let f):
    file = f
  case .failure(let error):
    logError("handleArtifactShare: \(error)")
    return "{\"error\":\"Failed to read artifact\"}"
  }

  let activeTaskId = findActiveTaskId(ctx: ctx)
  guard let taskId = activeTaskId else {
    logDebug("handleArtifactShare: no active task, skipping")
    return "{\"skipped\":true}"
  }

  let collected = CollectedArtifact(
    filename: artifact.filename,
    data: file.data,
    mimeType: artifact.mime_type ?? file.mimeType
  )

  if ctx.taskArtifacts[taskId] == nil {
    ctx.taskArtifacts[taskId] = []
  }
  ctx.taskArtifacts[taskId]?.append(collected)

  logDebug("handleArtifactShare: collected \(artifact.filename) for task \(taskId)")
  return "{\"collected\":true}"
}

private func findActiveTaskId(ctx: PluginContext) -> String? {
  ctx.taskDispatchTimestamps.max(by: { $0.value < $1.value })?.key
}

// MARK: - Health Endpoint

private func handleHealth(ctx: PluginContext) -> String {
  let registered = configGet("webhook_registered") == "true"
  let body: [String: Any] = [
    "ok": registered,
    "webhook_registered": registered,
  ]
  let bodyStr = makeJSONString(body) ?? "{}"
  return makeRouteResponse(status: 200, body: bodyStr, contentType: "application/json")
}

// MARK: - Response Builder

func makeRouteResponse(status: Int, body: String, contentType: String = "text/plain") -> String {
  let resp: [String: Any] = [
    "status": status,
    "headers": ["Content-Type": contentType],
    "body": body,
  ]
  return makeJSONString(resp) ?? "{\"status\":500}"
}

// MARK: - Helpers

func extractEmailAddress(_ raw: String) -> String {
  if let start = raw.firstIndex(of: "<"),
    let end = raw.firstIndex(of: ">"),
    start < end
  {
    return String(raw[raw.index(after: start)..<end])
  }
  return raw.trimmingCharacters(in: .whitespaces)
}
