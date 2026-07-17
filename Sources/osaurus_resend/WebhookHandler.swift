import Foundation

// MARK: - Route Handler

/// Upper bound on accepted request bodies. Resend webhook payloads are a few
/// KB; anything near this size is hostile or corrupt.
let maxRouteBodyBytes = 1_048_576

func handleRoute(ctx: PluginContext, requestJSON: String) -> String {
  guard let req = parseJSON(requestJSON, as: RouteRequest.self) else {
    logWarn("handleRoute: failed to parse request")
    return makeRouteResponse(status: 400, body: "{\"error\":\"Invalid request\"}")
  }

  switch req.route_id {
  case "webhook":
    if let rejection = validateRequest(req, method: "POST", requireJSONBody: true) {
      return rejection
    }
    return handleWebhook(ctx: ctx, req: req)
  case "health":
    if let rejection = validateRequest(req, method: "GET", requireJSONBody: false) {
      return rejection
    }
    return handleHealth(ctx: ctx)
  case "reset_webhook":
    if let rejection = validateRequest(req, method: "POST", requireJSONBody: false) {
      return rejection
    }
    return handleResetWebhook(ctx: ctx)
  default: return makeRouteResponse(status: 404, body: "{\"error\":\"Not found\"}")
  }
}

/// Method / content-type / body-size gate applied before any route handler
/// runs. Returns a ready-made rejection response, or `nil` when the request
/// is acceptable.
private func validateRequest(
  _ req: RouteRequest, method expectedMethod: String, requireJSONBody: Bool
) -> String? {
  if req.method.uppercased() != expectedMethod {
    logWarn("handleRoute: method \(req.method) not allowed for \(req.route_id)")
    return makeRouteResponse(status: 405, body: "{\"error\":\"Method not allowed\"}")
  }
  if let body = req.body, body.utf8.count > maxRouteBodyBytes {
    logWarn("handleRoute: body too large (\(body.utf8.count) bytes) for \(req.route_id)")
    return makeRouteResponse(status: 413, body: "{\"error\":\"Payload too large\"}")
  }
  if requireJSONBody, let body = req.body, !body.isEmpty {
    let contentType = findHeader(req.headers, name: "content-type") ?? ""
    if !contentType.lowercased().contains("application/json") {
      logWarn("handleRoute: unsupported content type '\(contentType)' for \(req.route_id)")
      return makeRouteResponse(status: 415, body: "{\"error\":\"Unsupported media type\"}")
    }
  }
  return nil
}

// MARK: - Webhook Endpoint

/// Hot path (Wave 2: claim-then-async-drain). The handler verifies the
/// Svix signature, parses the event, and atomically claims the svix-id
/// into the inbox with the raw payload persisted in the SAME statement
/// (durable-first); the receive-API fetch + dispatch happen on the
/// background worker. Wave 1's 503-on-transient is kept for the enqueue
/// step itself (`.storeUnavailable`).
private func handleWebhook(ctx: PluginContext, req: RouteRequest) -> String {
  guard let body = req.body, !body.isEmpty else {
    logWarn("handleWebhook: empty body")
    return makeRouteResponse(status: 200, body: "ok")
  }

  // 1. Verify Svix signature, failing closed. 503 while no secret is
  //    persisted yet (bootstrap window: Svix retries and the delivery is
  //    processed once registration completes); 401 for bad signatures so the
  //    failure shows up in Resend's webhook events list.
  let svixId = findHeader(req.headers, name: "svix-id")
  switch verifyIncomingWebhook(req: req, body: body) {
  case .ok: break
  case .reject(let reason):
    logWarn("handleWebhook: signature verification failed: \(reason)")
    return makeRouteResponse(status: 401, body: "{\"error\":\"Invalid signature\"}")
  case .notReady(let reason):
    logWarn("handleWebhook: \(reason); rejecting until webhook registration persists a secret")
    return makeRouteResponse(status: 503, body: "{\"error\":\"Webhook not configured yet\"}")
  }

  // Every authenticated webhook doubles as the recovery heartbeat: kick a
  // reconciliation pass for stale claims. Cheap on the request path — the
  // actual reprocessing runs on the worker.
  triggerSvixReconciliation(ctx: ctx)

  guard let event = parseJSON(body, as: ResendWebhookEvent.self) else {
    logWarn("handleWebhook: failed to parse event")
    return makeRouteResponse(status: 200, body: "ok")
  }
  logDebug("handleWebhook: type=\(event.type) email_id=\(event.data.email_id)")

  let stored = StoredWebhookPayload(body: body, agent_address: req.osaurus?.agent_address)

  // 2. Deliveries without a svix-id have no dedupe/enqueue key, so there is
  //    nothing to durably claim against: process synchronously exactly like
  //    wave 1 (200 on success, retryable 503 on transient failure). Real
  //    Svix deliveries always carry the id; this is a defensive path.
  guard let svixId, !svixId.isEmpty else {
    switch processWebhookEvent(
      ctx: ctx, event: event, body: body, agentAddress: stored.agent_address)
    {
    case .success:
      return makeRouteResponse(status: 200, body: "ok")
    case .transientFailure(let reason):
      logWarn("handleWebhook: transient failure (\(reason)), requesting redelivery")
      ctx.recordProcessingError(reason)
      return makeRouteResponse(status: 503, body: "{\"error\":\"Processing failed, retry\"}")
    }
  }

  // 3. Atomically claim + durably persist, then hand off to the worker.
  switch DatabaseManager.claimSvixId(svixId, payload: stored.encoded()) {
  case .claimed:
    ctx.webhookWorker.enqueue {
      processClaimedDelivery(ctx: ctx, svixId: svixId, stored: stored)
    }
    return makeRouteResponse(status: 200, body: "ok")

  case .alreadyCompleted:
    logDebug("handleWebhook: skipping duplicate svix-id=\(svixId)")
    return makeRouteResponse(status: 200, body: "ok")

  case .inFlight:
    // In-lease claim. With a stored payload the delivery is already durably
    // queued (or awaiting reconciliation): ack 200 and MUST NOT enqueue
    // again — that would double-process. Without one (pre-Wave-2 row, or a
    // claim made outside the webhook path) only the provider's retry can
    // recover the event, so keep wave 1's retryable 503.
    if DatabaseManager.svixClaimHasPayload(svixId) {
      logDebug("handleWebhook: svix-id=\(svixId) already durably enqueued, 200 OK")
      return makeRouteResponse(status: 200, body: "ok")
    }
    logDebug("handleWebhook: svix-id=\(svixId) in flight without payload, asking for retry")
    return makeRouteResponse(status: 503, body: "{\"error\":\"Delivery is being processed\"}")

  case .storeUnavailable:
    // The claim could not be durably recorded. Durable-first forbids acking
    // here — 503 keeps Svix's retry as the recovery mechanism for the
    // enqueue step itself (the wave-1 contract).
    logWarn("handleWebhook: claim store unavailable for svix-id=\(svixId)")
    return makeRouteResponse(status: 503, body: "{\"error\":\"Delivery could not be recorded\"}")
  }
}

/// Outcome of processing one webhook event. Permanent conditions (unauthorized
/// sender, unknown event type, duplicates) count as `success` so the provider
/// stops redelivering; `transientFailure` means a retry may succeed.
enum ProcessingOutcome {
  case success
  case transientFailure(String)
}

/// Worker-side event processing (Wave 2): everything that used to run
/// synchronously after the claim. Runs on the drain lane for claimed
/// deliveries; also runs inline for the defensive no-svix-id path.
func processWebhookEvent(
  ctx: PluginContext, event: ResendWebhookEvent, body: String, agentAddress: String?
) -> ProcessingOutcome {
  switch event.type {
  case "email.received":
    let emailId = event.data.email_id
    if DatabaseManager.hasEmailId(emailId) {
      logDebug("handleWebhook: skipping already-processed email_id=\(emailId)")
      return .success
    }
    return processInboundEmail(
      ctx: ctx, eventData: event.data, agentAddress: agentAddress)
  case "email.bounced":
    let reason = event.data.bounce_message ?? "bounced"
    handleSuppressionEvent(
      ctx: ctx, eventData: event.data, suppressReason: "bounce: \(reason)",
      eventType: "bounced", detail: reason,
      summary: "Email to {recipients} bounced: \(reason)")
    return .success
  case "email.complained":
    handleSuppressionEvent(
      ctx: ctx, eventData: event.data, suppressReason: "complaint",
      eventType: "complained", detail: nil,
      summary: "Recipient {recipients} marked your email as spam.")
    return .success
  case "email.failed":
    handleSendFailure(ctx: ctx, eventData: event.data, body: body)
    return .success
  case "email.delivered":
    DatabaseManager.recordEmailEvent(
      emailId: event.data.email_id, type: "delivered", detail: nil)
    return .success
  default:
    logDebug("handleWebhook: ignoring event type \(event.type)")
    return .success
  }
}

// MARK: - Signature Gate

private enum SignatureCheck {
  case ok
  case reject(String)
  case notReady(String)
}

private func verifyIncomingWebhook(req: RouteRequest, body: String) -> SignatureCheck {
  // No secret persisted yet (fresh install pre-registration, or upgrade from
  // an older plugin that didn't persist the secret). Fail closed: 503 tells
  // Svix to redeliver once registration completes, instead of processing
  // unauthenticated payloads.
  guard let signingSecret = configGet("signing_secret"), !signingSecret.isEmpty else {
    return .notReady("signing_secret not configured")
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

/// Pushes a send-related failure into the live task as a user-role turn so
/// the agent re-decides on the next round (the legacy `dispatch_add_issue`
/// slot is RESERVED on v6 hosts and returns `not_supported`).
private func surfaceFailureToTask(emailId: String, summary: String) {
  guard let thread = DatabaseManager.getThreadByOutboundEmailId(emailId),
    let taskId = thread.taskId, !taskId.isEmpty
  else { return }

  let message =
    "[email-system] \(summary) Adjust your plan: try a different recipient, "
    + "fix the address, or stop trying to email this destination."
  if dispatchInterrupt(taskId: taskId, message: message) {
    logDebug("surfaceFailureToTask: interrupted task=\(taskId) email_id=\(emailId)")
  }
}

/// Wraps the C-string juggling around `host->dispatch_interrupt`. Returns
/// `true` when the call was actually dispatched. No-op on hosts older than
/// the slot's introduction (and on empty `taskId`).
@discardableResult
private func dispatchInterrupt(taskId: String, message: String) -> Bool {
  guard !taskId.isEmpty, let interrupt = hostAPI?.pointee.dispatch_interrupt else {
    return false
  }
  taskId.withCString { taskPtr in
    message.withCString { msgPtr in
      interrupt(taskPtr, msgPtr)
    }
  }
  return true
}

// MARK: - Inbound Email Processing

private func processInboundEmail(
  ctx: PluginContext, eventData: ResendEmailEventData, agentAddress: String?
) -> ProcessingOutcome {
  let senderEmail = extractEmailAddress(eventData.from ?? "")
  if !isAuthorized(sender: senderEmail) {
    logInfo("Unauthorized sender \(senderEmail), ignoring")
    return .success
  }

  guard let apiKey = configGet("api_key"), !apiKey.isEmpty else {
    logError("processInboundEmail: no API key configured")
    return .transientFailure("no API key configured")
  }
  guard let received = resendGetReceivedEmail(apiKey: apiKey, emailId: eventData.email_id) else {
    logError("processInboundEmail: failed to fetch email body for \(eventData.email_id)")
    return .transientFailure("failed to fetch email body")
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

  let outcome = dispatchInboundTask(
    ctx: ctx, parsed: parsed, threadId: threadId, agentAddress: agentAddress)
  if case .transientFailure = outcome {
    // Roll back the inbound row so the provider's redelivery isn't skipped by
    // the hasEmailId dedupe and gets a full re-process.
    DatabaseManager.deleteMessagesByEmailId(eventData.email_id, direction: "in")
  }
  return outcome
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

/// Reply tools we want the model to see on turn 1 of every inbound dispatch.
/// Pinning closes the gap where auto-mode preflight occasionally misses them.
/// Names not in this plugin's manifest would be silently dropped by the host.
private let pinnedReplyTools = [
  "resend_reply",
  "resend_get_thread",
  "resend_label_thread",
]

private func dispatchInboundTask(
  ctx: PluginContext, parsed: ParsedInboundEmail, threadId: String, agentAddress: String?
) -> ProcessingOutcome {
  guard let dispatch = hostAPI?.pointee.dispatch else {
    logError("processInboundEmail: dispatch not available")
    return .transientFailure("dispatch not available")
  }

  // Follow-up email on a thread with an in-flight task: inject the new body
  // into the live session and cancel the current stream, then dispatch fresh
  // with the same session_id. The reattach merges full context so the model
  // produces one coherent reply instead of two racing parallel agents.
  if let activeTask = DatabaseManager.getThread(threadId: threadId)?.taskId,
    !activeTask.isEmpty
  {
    let interruptText =
      "[follow-up email arrived in this thread, from \(parsed.fromAddress)]\n\n"
      + (parsed.bodyText ?? parsed.bodyHtml ?? "(empty body)")
    if dispatchInterrupt(taskId: activeTask, message: interruptText) {
      DatabaseManager.clearTaskId(threadId: threadId)
      clearTaskState(ctx: ctx, taskId: activeTask)
      logInfo(
        "dispatchInboundTask: interrupted in-flight task \(activeTask) on thread \(threadId)")
    }
  }

  let prompt = buildEmailPrompt(
    from: parsed.fromAddress, subject: parsed.subject,
    bodyText: parsed.bodyText, bodyHtml: parsed.bodyHtml, threadId: threadId)
  let titleSource = parsed.subject ?? "Email from \(parsed.fromEmail)"

  var payload: [String: Any] = [
    "prompt": prompt,
    "title": "Email: \(String(titleSource.prefix(60)))",
    // Reattaches every email on the same thread to one continuous Osaurus
    // session. Replaces `external_session_key`, which is not in the dispatch
    // schema and was being silently dropped by the host.
    "session_id": sessionId(forThreadId: threadId),
    "tools": pinnedReplyTools,
  ]
  if let agentAddress { payload["agent_address"] = agentAddress }

  guard let payloadJSON = makeJSONString(payload) else {
    logError("processInboundEmail: failed to serialize dispatch payload")
    return .transientFailure("failed to serialize dispatch payload")
  }

  guard let resultStr = callHostString(payloadJSON, via: dispatch),
    let result = parseJSON(resultStr, as: DispatchResponse.self),
    let taskId = result.id
  else {
    logError("processInboundEmail: dispatch failed")
    return .transientFailure("dispatch failed")
  }

  DatabaseManager.updateThread(threadId: threadId, taskId: taskId)
  ctx.taskDispatchTimestamps[taskId] = Int(Date().timeIntervalSince1970)
  logInfo("Dispatched task \(taskId) for email from \(parsed.fromEmail) in thread \(threadId)")
  return .success
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
  case OSR_TASK_EVENT_CLARIFICATION:
    handleTaskClarification(ctx: ctx, taskId: taskId, eventJSON: eventJSON)
  case OSR_TASK_EVENT_COMPLETED:
    handleTaskCompleted(ctx: ctx, taskId: taskId, eventJSON: eventJSON)
  case OSR_TASK_EVENT_FAILED, OSR_TASK_EVENT_CANCELLED:
    handleTaskFailed(ctx: ctx, taskId: taskId)
  default:
    break
  }
}

/// Forwards a paused agent's clarify question to the email channel. Without
/// this branch the user would see nothing: the host suppresses COMPLETED for
/// the duration of a clarify pause and the question text only ever lives in
/// this event's payload.
///
/// `task_id` deliberately survives the pause; the same task resumes when the
/// user replies and the webhook arrives, at which point `dispatchInboundTask`'s
/// in-flight check interrupts the paused task with the user's response.
/// Recording the question as outbound keeps the COMPLETED safety-net auto-reply
/// disarmed when the resumed run terminates.
private func handleTaskClarification(
  ctx: PluginContext, taskId: String, eventJSON: String
) {
  guard let event = parseJSON(eventJSON, as: TaskClarificationEvent.self),
    let question = event.question, !question.isEmpty
  else {
    logDebug("handleTaskClarification: empty/invalid payload, skipping")
    return
  }
  guard let thread = DatabaseManager.getThreadByTaskId(taskId) else {
    logDebug("handleTaskClarification: no thread for task \(taskId)")
    return
  }

  let html = renderClarificationBody(event: event, question: question)
  let logCtx = "handleTaskClarification (task \(taskId), thread \(thread.threadId))"
  if sendAndRecordReply(thread: thread, html: html, logContext: logCtx) {
    logInfo("\(logCtx): forwarded question")
  }
}

private func renderClarificationBody(
  event: TaskClarificationEvent, question: String
) -> String {
  guard let options = event.options, !options.isEmpty else { return question }
  let bullets = options.enumerated()
    .map { i, opt in "\(i + 1). \(opt)" }
    .joined(separator: "<br/>")
  let multiNote =
    (event.allow_multiple == true)
    ? "<br/><br/><i>(multiple selections allowed)</i>" : ""
  return "\(question)<br/><br/>\(bullets)\(multiNote)"
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

  let attachments = collectAndClearArtifacts(taskId: taskId, ctx: ctx)
  let logCtx = "handleTaskCompleted (task \(taskId), thread \(thread.threadId))"
  if sendAndRecordReply(
    thread: thread, html: summary, attachments: attachments, logContext: logCtx)
  {
    logInfo("Auto-replied in thread \(thread.threadId) with \(attachments.count) attachments")
  }
}

private func handleTaskFailed(ctx: PluginContext, taskId: String) {
  defer { clearTaskState(ctx: ctx, taskId: taskId) }
  if let thread = DatabaseManager.getThreadByTaskId(taskId) {
    DatabaseManager.clearTaskId(threadId: thread.threadId)
    logInfo("Task \(taskId) failed/cancelled, no email sent")
  }
}

/// Sends an HTML email as a reply on `thread`, performing the standard pre-
/// flight (config check, recipient resolution, suppression check) and on
/// success records a corresponding outbound row so `hasOutboundMessageSince`
/// reflects the send (which is what disarms the COMPLETED safety net).
///
/// Returns `true` only when the email was actually accepted by Resend and the
/// outbound row was inserted; all failure modes are logged with `logContext`
/// as the prefix and return `false` so callers can short-circuit cleanly.
@discardableResult
private func sendAndRecordReply(
  thread: ThreadRow,
  html: String,
  attachments: [EmailAttachment] = [],
  logContext: String
) -> Bool {
  guard let apiKey = configGet("api_key"), !apiKey.isEmpty,
    let fromEmail = configGet("from_email"), !fromEmail.isEmpty
  else {
    logWarn("\(logContext): missing config, cannot reply")
    return false
  }
  guard
    let recipients = computeReplyRecipients(
      thread: thread, fromEmail: fromEmail, explicitTo: nil)
  else {
    logWarn("\(logContext): no recipients on thread")
    return false
  }
  if let blocked = checkSuppressed(recipients.to + recipients.cc) {
    logWarn("\(logContext): skipping, recipient suppressed (\(blocked))")
    return false
  }

  let params = SendEmailParams(
    from: formatFromAddress(name: configGet("from_name"), email: fromEmail),
    to: recipients.to, subject: buildReplySubject(thread.subject),
    html: html, text: nil,
    cc: recipients.cc.isEmpty ? nil : recipients.cc, bcc: nil,
    replyTo: [fromEmail],
    headers: emptyToNil(
      buildThreadingHeaders(
        lastMessageId: thread.lastMessageId, refs: thread.refs)),
    attachments: attachments.isEmpty ? nil : attachments
  )

  let (emailId, error) = resendSendEmail(apiKey: apiKey, params: params)
  guard let emailId else {
    logError("\(logContext): send failed: \(error ?? "unknown")")
    return false
  }

  DatabaseManager.insertMessage(
    threadId: thread.threadId, emailId: emailId, direction: "out",
    fromAddress: fromEmail, toAddress: recipients.to,
    ccAddress: recipients.cc, bccAddress: [],
    subject: params.subject, bodyText: nil, bodyHtml: html,
    messageId: nil, inReplyTo: thread.lastMessageId,
    hasAttachments: !attachments.isEmpty
  )
  return true
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

/// GET /health (Wave 2): reports the async-drain inbox alongside webhook
/// registration status. `ok` means "registered and nothing stuck": a
/// pending claim older than the lease indicates a wedged/failed worker
/// awaiting reconciliation.
private func handleHealth(ctx: PluginContext) -> String {
  let registered = configGet("webhook_registered") == "true"
  let queueDepth = DatabaseManager.pendingSvixClaimCount()
  let oldestAge = DatabaseManager.oldestPendingSvixClaimAge()

  var payload: [String: Any] = [
    "webhook_registered": registered,
    "queue_depth": queueDepth,
    "oldest_pending_claim_age_seconds": oldestAge ?? NSNull(),
  ]
  if let lastError = ctx.lastProcessingError() {
    payload["last_processing_error"] = lastError.message
    payload["last_processing_error_at"] = lastError.at
  } else {
    payload["last_processing_error"] = NSNull()
  }
  payload["ok"] =
    registered && (oldestAge ?? 0) <= DatabaseManager.svixClaimLeaseSeconds

  let body = makeJSONString(payload) ?? "{}"
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
