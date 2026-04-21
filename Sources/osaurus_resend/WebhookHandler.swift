import Foundation

// MARK: - Route Handler

func handleRoute(ctx: PluginContext, requestJSON: String) -> String {
  guard let req = parseJSON(requestJSON, as: RouteRequest.self) else {
    logWarn("handleRoute: failed to parse request")
    return makeRouteResponse(status: 400, body: "{\"error\":\"Invalid request\"}")
  }

  switch req.route_id {
  case "webhook": return handleWebhook(ctx: ctx, req: req)
  case "health": return handleHealth(ctx: ctx)
  case "reset_webhook": return handleResetWebhook(ctx: ctx)
  default: return makeRouteResponse(status: 404, body: "{\"error\":\"Not found\"}")
  }
}

// MARK: - Webhook Endpoint

private func handleWebhook(ctx: PluginContext, req: RouteRequest) -> String {
  guard let body = req.body, !body.isEmpty else {
    logWarn("handleWebhook: empty body")
    return makeRouteResponse(status: 200, body: "ok")
  }

  // 1. Verify Svix signature when configured. We deliberately return 401 (not
  //    200) on bad signatures so Svix retries and the failure shows up in
  //    Resend's webhook events list.
  let svixId = findHeader(req.headers, name: "svix-id")
  switch verifyIncomingWebhook(req: req, body: body) {
  case .ok: break
  case .reject(let reason):
    logWarn("handleWebhook: signature verification failed: \(reason)")
    return makeRouteResponse(status: 401, body: "{\"error\":\"Invalid signature\"}")
  case .acceptUnverified(let reason):
    logWarn("handleWebhook: \(reason); accepting unverified")
  }

  // 2. Dedupe by svix-id across all event types. Same delivery reaching us
  //    twice (e.g. our 200 ack was lost) must process exactly once.
  if let svixId, !svixId.isEmpty, !DatabaseManager.recordSvixId(svixId) {
    logDebug("handleWebhook: skipping duplicate svix-id=\(svixId)")
    return makeRouteResponse(status: 200, body: "ok")
  }

  guard let event = parseJSON(body, as: ResendWebhookEvent.self) else {
    logWarn("handleWebhook: failed to parse event")
    return makeRouteResponse(status: 200, body: "ok")
  }

  logDebug("handleWebhook: type=\(event.type) email_id=\(event.data.email_id)")
  dispatchEvent(event: event, body: body, req: req, ctx: ctx)
  return makeRouteResponse(status: 200, body: "ok")
}

private func dispatchEvent(
  event: ResendWebhookEvent, body: String, req: RouteRequest, ctx: PluginContext
) {
  switch event.type {
  case "email.received":
    let emailId = event.data.email_id
    if DatabaseManager.hasEmailId(emailId) {
      logDebug("handleWebhook: skipping already-processed email_id=\(emailId)")
      return
    }
    processInboundEmail(
      ctx: ctx, eventData: event.data, agentAddress: req.osaurus?.agent_address)
  case "email.bounced":
    let reason = event.data.bounce_message ?? "bounced"
    handleSuppressionEvent(
      ctx: ctx, eventData: event.data, suppressReason: "bounce: \(reason)",
      eventType: "bounced", detail: reason,
      summary: "Email to {recipients} bounced: \(reason)")
  case "email.complained":
    handleSuppressionEvent(
      ctx: ctx, eventData: event.data, suppressReason: "complaint",
      eventType: "complained", detail: nil,
      summary: "Recipient {recipients} marked your email as spam.")
  case "email.failed":
    handleSendFailure(ctx: ctx, eventData: event.data, body: body)
  case "email.delivered":
    DatabaseManager.recordEmailEvent(
      emailId: event.data.email_id, type: "delivered", detail: nil)
  default:
    logDebug("handleWebhook: ignoring event type \(event.type)")
  }
}

// MARK: - Signature Gate

private enum SignatureCheck {
  case ok
  case reject(String)
  case acceptUnverified(String)
}

private func verifyIncomingWebhook(req: RouteRequest, body: String) -> SignatureCheck {
  // No secret configured yet (fresh install pre-registration, or upgrade from
  // an older plugin that didn't persist the secret). Accept with a loud warning
  // rather than silently 200ing or hard-failing the webhook.
  guard let signingSecret = configGet("signing_secret"), !signingSecret.isEmpty else {
    return .acceptUnverified("signing_secret not configured")
  }

  guard let svixId = findHeader(req.headers, name: "svix-id"),
    let svixTimestamp = findHeader(req.headers, name: "svix-timestamp"),
    let svixSignature = findHeader(req.headers, name: "svix-signature"),
    !svixId.isEmpty, !svixTimestamp.isEmpty, !svixSignature.isEmpty
  else {
    return .reject("missing svix-id/svix-timestamp/svix-signature header")
  }

  switch verifySvixSignature(
    svixId: svixId, svixTimestamp: svixTimestamp,
    svixSignature: svixSignature, body: body, signingSecret: signingSecret)
  {
  case .success: return .ok
  case .failure(let err): return .reject("\(err)")
  }
}

// MARK: - Lifecycle Event Handlers

/// Shared path for `email.bounced` + `email.complained`: both add the
/// recipient(s) to the suppression list, log an `email_events` row, and
/// optionally surface the failure into a running task.
///
/// `summary` may contain the literal placeholder `{recipients}`, which is
/// replaced with a comma-joined recipient list at call time.
private func handleSuppressionEvent(
  ctx: PluginContext, eventData: ResendEmailEventData,
  suppressReason: String, eventType: String, detail: String?, summary: String
) {
  let emailId = eventData.email_id
  let recipients = (eventData.to ?? [])
    .map { extractEmailAddress($0).lowercased() }
    .filter { !$0.isEmpty }

  for addr in recipients {
    DatabaseManager.suppressAddress(address: addr, reason: suppressReason, emailId: emailId)
    logInfo("\(eventType): suppressed \(addr) (email_id=\(emailId))")
  }
  DatabaseManager.recordEmailEvent(emailId: emailId, type: eventType, detail: detail)

  let recipientText = recipients.joined(separator: ", ")
  let resolvedSummary = summary.replacingOccurrences(of: "{recipients}", with: recipientText)
  surfaceFailureToTask(emailId: emailId, summary: resolvedSummary)
}

private func handleSendFailure(ctx: PluginContext, eventData: ResendEmailEventData, body: String) {
  let emailId = eventData.email_id
  let reason = extractFailureReason(body) ?? "send failure"
  DatabaseManager.recordEmailEvent(emailId: emailId, type: "failed", detail: reason)
  logWarn("handleSendFailure: email_id=\(emailId) reason=\(reason)")
  surfaceFailureToTask(emailId: emailId, summary: "Resend reported a send failure: \(reason)")
}

private func extractFailureReason(_ body: String) -> String? {
  guard let data = body.data(using: .utf8),
    let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    let payload = dict["data"] as? [String: Any]
  else { return nil }
  if let failed = payload["failed"] as? [String: Any], let reason = failed["reason"] as? String {
    return reason
  }
  return payload["reason"] as? String
}

/// When a send-related lifecycle event arrives for an email that belongs to a
/// thread with an active task, push the failure into the running task as an
/// issue so the agent can adapt mid-flight instead of finding out later.
private func surfaceFailureToTask(emailId: String, summary: String) {
  guard let thread = DatabaseManager.getThreadByOutboundEmailId(emailId),
    let taskId = thread.taskId, !taskId.isEmpty,
    let addIssue = hostAPI?.pointee.dispatch_add_issue
  else { return }

  let issuePayload: [String: Any] = [
    "kind": "email_send_problem",
    "summary": summary,
    "email_id": emailId,
    "thread_id": thread.threadId,
  ]
  guard let issueJSON = makeJSONString(issuePayload) else { return }
  taskId.withCString { taskPtr in
    issueJSON.withCString { jsonPtr in
      _ = addIssue(taskPtr, jsonPtr)
    }
  }
  logDebug("surfaceFailureToTask: pushed issue for task=\(taskId) email_id=\(emailId)")
}

// MARK: - Inbound Email Processing

private func processInboundEmail(
  ctx: PluginContext, eventData: ResendEmailEventData, agentAddress: String?
) {
  let senderEmail = extractEmailAddress(eventData.from ?? "")
  if !isAuthorized(sender: senderEmail) {
    logInfo("Unauthorized sender \(senderEmail), ignoring")
    return
  }

  guard let apiKey = configGet("api_key"), !apiKey.isEmpty else {
    logError("processInboundEmail: no API key configured")
    return
  }
  guard let received = resendGetReceivedEmail(apiKey: apiKey, emailId: eventData.email_id) else {
    logError("processInboundEmail: failed to fetch email body for \(eventData.email_id)")
    return
  }

  let parsed = ParsedInboundEmail(received: received, eventData: eventData)
  let threadId = upsertThreadForInbound(parsed: parsed)

  DatabaseManager.insertMessage(
    threadId: threadId, emailId: eventData.email_id, direction: "in",
    fromAddress: parsed.fromAddress, toAddress: parsed.toAddresses,
    ccAddress: parsed.ccAddresses, bccAddress: [],
    subject: parsed.subject, bodyText: parsed.bodyText, bodyHtml: parsed.bodyHtml,
    messageId: parsed.messageId, inReplyTo: parsed.inReplyTo,
    hasAttachments: parsed.hasAttachments
  )

  dispatchInboundTask(
    ctx: ctx, parsed: parsed, threadId: threadId, agentAddress: agentAddress)
}

/// View into the parsed shape of an inbound email used by the inbound pipeline,
/// derived from both the webhook event and the full receive-API fetch.
private struct ParsedInboundEmail {
  let fromAddress: String
  let fromEmail: String
  let toAddresses: [String]
  let ccAddresses: [String]
  let subject: String?
  let messageId: String?
  let bodyText: String?
  let bodyHtml: String?
  let hasAttachments: Bool
  let inReplyTo: String?

  init(received: ResendReceivedEmail, eventData: ResendEmailEventData) {
    self.fromAddress = received.from ?? eventData.from ?? ""
    self.fromEmail = extractEmailAddress(self.fromAddress)
    self.toAddresses = received.to ?? eventData.to ?? []
    self.ccAddresses = received.cc ?? eventData.cc ?? []
    self.subject = received.subject ?? eventData.subject
    self.messageId = received.message_id ?? eventData.message_id
    self.bodyText = received.text
    self.bodyHtml = received.html
    self.hasAttachments = !(received.attachments ?? []).isEmpty
    self.inReplyTo = findHeader(received.headers, name: "in-reply-to")
  }

  /// All addresses involved in the message excluding the agent's own address
  /// (so the agent isn't listed as a participant of its own threads).
  func participants(excluding agentEmail: String) -> Set<String> {
    let raw =
      [fromEmail] + toAddresses.map { extractEmailAddress($0) }
      + ccAddresses.map { extractEmailAddress($0) }
    return Set(
      raw.map { $0.lowercased() }
        .filter { !$0.isEmpty && $0 != agentEmail }
    )
  }
}

/// Returns the thread id this email belongs to, joining an existing thread
/// (matched via `In-Reply-To`) if one exists, or creating a new one.
private func upsertThreadForInbound(parsed: ParsedInboundEmail) -> String {
  let agentEmail = (configGet("from_email") ?? "").lowercased()
  let participants = parsed.participants(excluding: agentEmail)
  let existing = parsed.inReplyTo.flatMap { DatabaseManager.getThreadByMessageId($0) }

  if let existing {
    var merged = Set(existing.participants.map { $0.lowercased() })
    for p in participants { merged.insert(p) }

    var refs = existing.refs ?? ""
    if let mid = parsed.messageId, !refs.contains(mid) {
      refs = refs.isEmpty ? mid : "\(refs) \(mid)"
    }

    DatabaseManager.updateThread(
      threadId: existing.threadId,
      lastMessageId: parsed.messageId, refs: refs,
      participants: Array(merged)
    )
    logDebug("processInboundEmail: joined thread \(existing.threadId)")
    return existing.threadId
  }

  let threadId = UUID().uuidString
  DatabaseManager.createThread(
    threadId: threadId, subject: parsed.subject,
    participants: Array(participants),
    messageId: parsed.messageId, refs: parsed.messageId
  )
  logDebug("processInboundEmail: created thread \(threadId)")
  return threadId
}

private func dispatchInboundTask(
  ctx: PluginContext, parsed: ParsedInboundEmail, threadId: String, agentAddress: String?
) {
  guard let dispatch = hostAPI?.pointee.dispatch else {
    logError("processInboundEmail: dispatch not available")
    return
  }

  let prompt = buildEmailPrompt(
    from: parsed.fromAddress, subject: parsed.subject,
    bodyText: parsed.bodyText, bodyHtml: parsed.bodyHtml, threadId: threadId)
  let titleSource = parsed.subject ?? "Email from \(parsed.fromEmail)"

  var payload: [String: Any] = [
    "prompt": prompt,
    "title": "Email: \(String(titleSource.prefix(60)))",
    "external_session_key": "resend:thread:\(threadId)",
  ]
  if let agentAddress { payload["agent_address"] = agentAddress }

  guard let payloadJSON = makeJSONString(payload) else {
    logError("processInboundEmail: failed to serialize dispatch payload")
    return
  }

  let resultStr: String? = payloadJSON.withCString { ptr in
    guard let p = dispatch(ptr) else { return nil }
    return String(cString: p)
  }
  guard let resultStr,
    let result = parseJSON(resultStr, as: DispatchResponse.self),
    let taskId = result.id
  else {
    logError("processInboundEmail: dispatch failed")
    return
  }

  DatabaseManager.updateThread(threadId: threadId, taskId: taskId)
  ctx.taskDispatchTimestamps[taskId] = Int(Date().timeIntervalSince1970)
  logInfo("Dispatched task \(taskId) for email from \(parsed.fromEmail) in thread \(threadId)")
}

// MARK: - Authorization

func isAuthorized(sender: String) -> Bool {
  let policy = configGet("sender_policy") ?? "known"
  if policy != "known" { return true }

  let senderLower = sender.lowercased()

  if let allowedStr = configGet("allowed_senders"), !allowedStr.isEmpty {
    let allowed = allowedStr.split(separator: ",").map {
      $0.trimmingCharacters(in: .whitespaces).lowercased()
    }
    for entry in allowed {
      if entry.hasPrefix("@") {
        if senderLower.hasSuffix(entry) { return true }
      } else if senderLower == entry {
        return true
      }
    }
  }

  if DatabaseManager.hasSentTo(address: senderLower) { return true }
  if DatabaseManager.isParticipantInAnyThread(address: senderLower) { return true }
  return false
}

// MARK: - Prompt Builder

private func buildEmailPrompt(
  from: String, subject: String?,
  bodyText: String?, bodyHtml: String?,
  threadId: String
) -> String {
  var parts: [String] = [
    "You received an email. Read it and take appropriate action.",
    "",
    "From: \(from)",
  ]
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
  case OSR_TASK_EVENT_COMPLETED:
    handleTaskCompleted(ctx: ctx, taskId: taskId, eventJSON: eventJSON)
  case OSR_TASK_EVENT_FAILED, OSR_TASK_EVENT_CANCELLED:
    handleTaskFailed(ctx: ctx, taskId: taskId)
  default:
    break
  }
}

private func handleTaskCompleted(ctx: PluginContext, taskId: String, eventJSON: String) {
  defer { clearTaskState(ctx: ctx, taskId: taskId) }

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
  if let blocked = checkSuppressed(recipients.to + recipients.cc) {
    logWarn("handleTaskCompleted: skipping auto-reply, recipient suppressed (\(blocked))")
    return
  }

  let attachments = collectAndClearArtifacts(taskId: taskId, ctx: ctx)
  let params = SendEmailParams(
    from: formatFromAddress(name: configGet("from_name"), email: fromEmail),
    to: recipients.to, subject: buildReplySubject(thread.subject),
    html: summary, text: nil,
    cc: recipients.cc.isEmpty ? nil : recipients.cc, bcc: nil,
    replyTo: [fromEmail],
    headers: emptyToNil(
      buildThreadingHeaders(
        lastMessageId: thread.lastMessageId, refs: thread.refs)),
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
    subject: params.subject, bodyText: nil, bodyHtml: summary,
    messageId: nil, inReplyTo: thread.lastMessageId,
    hasAttachments: !attachments.isEmpty
  )
  logInfo("Auto-replied in thread \(thread.threadId) with \(attachments.count) attachments")
}

private func handleTaskFailed(ctx: PluginContext, taskId: String) {
  defer { clearTaskState(ctx: ctx, taskId: taskId) }
  if let thread = DatabaseManager.getThreadByTaskId(taskId) {
    DatabaseManager.clearTaskId(threadId: thread.threadId)
    logInfo("Task \(taskId) failed/cancelled, no email sent")
  }
}

private func clearTaskState(ctx: PluginContext, taskId: String) {
  ctx.taskArtifacts.removeValue(forKey: taskId)
  ctx.taskDispatchTimestamps.removeValue(forKey: taskId)
}

private func emptyToNil(_ d: [String: String]) -> [String: String]? {
  d.isEmpty ? nil : d
}

// MARK: - Artifact Handler

func handleArtifactShare(ctx: PluginContext, payload: String) -> String {
  guard let artifact = parseJSON(payload, as: ArtifactPayload.self) else {
    logWarn("handleArtifactShare: failed to parse payload")
    return "{\"error\":\"Invalid artifact payload\"}"
  }
  if artifact.is_directory == true { return "{\"skipped\":true}" }

  let file: HostFileResult
  switch readHostFile(path: artifact.host_path) {
  case .success(let f): file = f
  case .failure(let error):
    logError("handleArtifactShare: \(error)")
    return "{\"error\":\"Failed to read artifact\"}"
  }

  // Attach to the most-recently-dispatched task; if there isn't one, the
  // artifact has nothing to ride along with and we drop it.
  guard
    let taskId = ctx.taskDispatchTimestamps.max(by: { $0.value < $1.value })?.key
  else {
    logDebug("handleArtifactShare: no active task, skipping")
    return "{\"skipped\":true}"
  }

  ctx.taskArtifacts[taskId, default: []].append(
    CollectedArtifact(
      filename: artifact.filename, data: file.data,
      mimeType: artifact.mime_type ?? file.mimeType
    )
  )
  logDebug("handleArtifactShare: collected \(artifact.filename) for task \(taskId)")
  return "{\"collected\":true}"
}

// MARK: - Health & Reset Endpoints

private func handleHealth(ctx: PluginContext) -> String {
  let registered = configGet("webhook_registered") == "true"
  let body = makeJSONString(["ok": registered, "webhook_registered": registered]) ?? "{}"
  return makeRouteResponse(status: 200, body: body, contentType: "application/json")
}

private func handleResetWebhook(ctx: PluginContext) -> String {
  let result = reconcileWebhook(ctx: ctx)
  if result.ok, let id = result.webhookId {
    let body = makeJSONString(["ok": true, "webhook_id": id]) ?? "{\"ok\":true}"
    return makeRouteResponse(status: 200, body: body, contentType: "application/json")
  }
  let body =
    makeJSONString(["ok": false, "error": result.error ?? "unknown"]) ?? "{\"ok\":false}"
  return makeRouteResponse(status: 500, body: body, contentType: "application/json")
}
