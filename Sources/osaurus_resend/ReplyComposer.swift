import Foundation

// MARK: - From Address

func formatFromAddress(name: String?, email: String) -> String {
  let trimmed = name?.trimmingCharacters(in: .whitespaces) ?? ""
  return trimmed.isEmpty ? email : "\(trimmed) <\(email)>"
}

// MARK: - Reply Recipients

struct ReplyRecipients {
  let to: [String]
  let cc: [String]
}

/// Resolves the recipient list for a reply.
///
/// Precedence:
/// 1. Explicit `to` (single recipient, no CC).
/// 2. Last inbound message's from-address as `to`, with remaining participants as CC.
/// 3. All thread participants minus self as `to`.
///
/// Returns `nil` when no valid recipients can be determined.
func computeReplyRecipients(
  thread: ThreadRow, fromEmail: String, explicitTo: String?
) -> ReplyRecipients? {
  let fromLower = fromEmail.lowercased()

  if let explicitTo, !explicitTo.isEmpty {
    return ReplyRecipients(to: [explicitTo], cc: [])
  }

  if let lastInbound = DatabaseManager.getLastInboundMessage(threadId: thread.threadId),
    let lastFrom = lastInbound.fromAddress
  {
    let replyTo = extractEmailAddress(lastFrom)
    let cc = thread.participants.filter {
      $0.lowercased() != fromLower && $0.lowercased() != replyTo.lowercased()
    }
    return ReplyRecipients(to: [replyTo], cc: cc)
  }

  let to = thread.participants.filter { $0.lowercased() != fromLower }
  guard !to.isEmpty else { return nil }
  return ReplyRecipients(to: to, cc: [])
}

// MARK: - Subject

func buildReplySubject(_ subject: String?) -> String {
  guard let subject else { return "Re:" }
  return subject.hasPrefix("Re:") ? subject : "Re: \(subject)"
}

// MARK: - Threading Headers

func buildThreadingHeaders(lastMessageId: String?, refs: String?) -> [String: String] {
  var headers: [String: String] = [:]
  if let lastMessageId {
    headers["In-Reply-To"] = lastMessageId
  }
  if let refs, !refs.isEmpty {
    if let lastMessageId, !refs.contains(lastMessageId) {
      headers["References"] = "\(refs) \(lastMessageId)"
    } else {
      headers["References"] = refs
    }
  } else if let lastMessageId {
    headers["References"] = lastMessageId
  }
  return headers
}

// MARK: - Suppression Check

/// Returns a JSON error string if any of the provided addresses are on the
/// suppression list, or `nil` if all recipients are clear to send.
///
/// Producing a structured error from the tool surface lets the agent see why
/// the send was blocked and adjust (e.g., "the recipient bounced last week,
/// pick a different contact") instead of silently re-trying a doomed send.
func checkSuppressed(_ addresses: [String]) -> String? {
  for raw in addresses {
    let addr = extractEmailAddress(raw)
    if addr.isEmpty { continue }
    if let reason = DatabaseManager.getSuppression(address: addr) {
      let escaped = escapeJSON("Recipient suppressed: \(addr) — \(reason)")
      return "{\"error\":\"\(escaped)\"}"
    }
  }
  return nil
}

// MARK: - Artifact Collection

/// Collects and clears the queued artifacts for a task, converting to `EmailAttachment`.
/// Returns an empty array if no task or no artifacts.
func collectAndClearArtifacts(taskId: String?, ctx: PluginContext) -> [EmailAttachment] {
  guard let taskId, let collected = ctx.taskArtifacts[taskId], !collected.isEmpty else {
    return []
  }
  let attachments = collected.map { artifact in
    EmailAttachment(
      filename: artifact.filename,
      content: artifact.data.base64EncodedString(),
      contentType: artifact.mimeType
    )
  }
  ctx.taskArtifacts[taskId] = []
  return attachments
}
