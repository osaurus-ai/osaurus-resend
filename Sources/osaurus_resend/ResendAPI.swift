import Foundation

// MARK: - Resend API Transport

/// Maximum number of retry attempts for transient failures (429 / 5xx).
private let maxRetryAttempts = 3
/// Base backoff in milliseconds; effective delay = base * 2^attempt with jitter.
private let baseBackoffMs: UInt32 = 200
/// Hard ceiling on a single retry sleep.
private let maxBackoffMs: UInt32 = 5_000

/// Test hook: when set to a non-nil value, the retry loop uses this many
/// milliseconds for every backoff (overriding the exponential schedule). Setting
/// to 0 makes retries effectively instantaneous so unit tests can exercise the
/// 429/5xx path without sleeping for seconds.
nonisolated(unsafe) var resendRetryBackoffOverrideMs: UInt? = nil

// MARK: - Client-Side Rate Limiter
//
// Resend's documented limit is 5 requests per second. A burst of N back-to-back
// DELETE calls (e.g. wiping leftover webhooks) was hitting 429 immediately.
// We enforce a minimum spacing between consecutive requests so we never breach
// the limit in the first place; the existing 429-retry path still covers shared
// quota with other plugins or brief contention.

/// Minimum spacing between consecutive Resend HTTP calls, in milliseconds.
/// `1000ms / 5 req = 200ms`; we add a tiny pad so we don't tag the boundary.
private let minRequestIntervalMs: UInt = 220
private let throttleLock = NSLock()
nonisolated(unsafe) private var lastRequestEndedAtMs: UInt64 = 0

/// Test hook: when set to a non-nil value, overrides the throttle interval.
/// Set to 0 in tests to disable throttling entirely.
nonisolated(unsafe) var resendThrottleIntervalOverrideMs: UInt? = nil

/// Sleeps just long enough that the next HTTP request respects the rate limit.
private func awaitRateLimitSlot() {
  let interval = resendThrottleIntervalOverrideMs ?? minRequestIntervalMs
  if interval == 0 { return }

  throttleLock.lock()
  let nowMs = currentMonotonicMillis()
  let earliestNextMs = lastRequestEndedAtMs + UInt64(interval)
  let waitMs: UInt64 = (nowMs < earliestNextMs) ? earliestNextMs - nowMs : 0
  // Reserve our slot now so concurrent callers stagger correctly.
  lastRequestEndedAtMs = max(nowMs, earliestNextMs)
  throttleLock.unlock()

  if waitMs > 0 {
    usleep(UInt32(min(waitMs, UInt64(UInt32.max / 1000))) * 1000)
  }
}

private func currentMonotonicMillis() -> UInt64 {
  let nanos = clock_gettime_nsec_np(CLOCK_MONOTONIC)
  return nanos / 1_000_000
}

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

  var attempt = 0
  while true {
    awaitRateLimitSlot()
    let responseStr: String? = requestJSON.withCString { ptr in
      guard let responsePtr = httpRequest(ptr) else { return nil }
      return String(cString: responsePtr)
    }
    guard let responseStr else {
      logError("No response from http_request for \(method) \(path)")
      return (false, nil)
    }

    guard let responseData = responseStr.data(using: .utf8),
      let httpResponse = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
    else {
      logError("Failed to parse http response for \(method) \(path)")
      return (false, nil)
    }

    let httpStatus = httpResponse["status"] as? Int ?? 0
    let rawBody = (httpResponse["body"] as? String) ?? ""
    let parsed: [String: Any]? = {
      guard let data = rawBody.data(using: .utf8),
        let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return nil }
      return dict
    }()

    let ok = httpStatus >= 200 && httpStatus < 300
    if ok {
      if parsed == nil && !rawBody.isEmpty {
        logWarn("Resend \(method) \(path) succeeded (HTTP \(httpStatus)) but body was non-JSON")
      }
      return (true, parsed)
    }

    let shouldRetry = attempt < maxRetryAttempts && isRetryableStatus(httpStatus)
    let responseHeaders = httpResponse["headers"] as? [String: Any]
    let retryAfterMs = retryAfterMilliseconds(headers: responseHeaders)

    logResendError(
      method: method, path: path, status: httpStatus,
      parsed: parsed, rawBody: rawBody,
      willRetry: shouldRetry, attempt: attempt
    )

    if shouldRetry {
      let computedSleep = retryAfterMs ?? backoffMilliseconds(for: attempt)
      let sleepMs = resendRetryBackoffOverrideMs ?? computedSleep
      let cappedMs = UInt32(min(sleepMs, UInt(maxBackoffMs)))
      if cappedMs > 0 { usleep(cappedMs * 1000) }
      attempt += 1
      continue
    }

    return (false, parsed)
  }
}

// MARK: - Retry / Error Helpers

private func isRetryableStatus(_ status: Int) -> Bool {
  if status == 429 { return true }
  if status >= 500 && status <= 599 { return true }
  return false
}

private func backoffMilliseconds(for attempt: Int) -> UInt {
  let base = UInt(baseBackoffMs) << attempt
  let capped = min(base, UInt(maxBackoffMs))
  // Add small jitter (0-25% of capped) to avoid thundering herd.
  let jitter = UInt.random(in: 0...(capped / 4 + 1))
  return capped + jitter
}

private func retryAfterMilliseconds(headers: [String: Any]?) -> UInt? {
  guard let headers else { return nil }
  // HTTP headers are case-insensitive; check common casings.
  let candidates = ["Retry-After", "retry-after", "RETRY-AFTER"]
  for key in candidates {
    if let raw = headers[key] {
      if let seconds = (raw as? Int) ?? Int("\(raw)") {
        return UInt(max(0, seconds)) * 1000
      }
    }
  }
  return nil
}

/// Centralized non-2xx logger that surfaces enough context to debug "Something went wrong".
private func logResendError(
  method: String, path: String, status: Int,
  parsed: [String: Any]?, rawBody: String,
  willRetry: Bool, attempt: Int
) {
  let name = (parsed?["name"] as? String) ?? "(no name)"
  let message = (parsed?["message"] as? String) ?? "(no message)"
  let snippet = String(rawBody.prefix(500))
  let retryNote = willRetry ? " (will retry, attempt=\(attempt + 1)/\(maxRetryAttempts))" : ""
  logWarn(
    "Resend \(method) \(path) failed (HTTP \(status))\(retryNote): name=\(name) message=\(message) body=\(snippet)"
  )
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

/// Event set the plugin subscribes to. Includes inbound (`email.received`) plus
/// the outbound lifecycle events the agent needs awareness of.
let resendSubscribedEvents: [String] = [
  "email.received",
  "email.delivered",
  "email.bounced",
  "email.complained",
  "email.failed",
]

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
    "events": resendSubscribedEvents,
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

/// Lists all webhooks for the account, paginating until exhausted.
///
/// Returns `nil` when any page's API call fails (so callers can distinguish transport
/// failure from "no webhooks"). A safety cap caps total fetched at `maxWebhooksToFetch`.
func resendListWebhooks(apiKey: String) -> [ResendWebhookSummary]? {
  let pageSize = 100
  let maxWebhooksToFetch = 1000
  var collected: [ResendWebhookSummary] = []
  var offset = 0

  while collected.count < maxWebhooksToFetch {
    let (ok, data) = resendRequest(
      apiKey: apiKey, method: "GET",
      path: "/webhooks?limit=\(pageSize)&offset=\(offset)"
    )
    guard ok else { return nil }
    guard let data else { return collected }

    let rows = (data["data"] as? [[String: Any]]) ?? []
    let parsed: [ResendWebhookSummary] = rows.compactMap { row in
      guard let id = row["id"] as? String,
        let endpoint = row["endpoint"] as? String
      else { return nil }
      let events = row["events"] as? [String] ?? []
      return ResendWebhookSummary(id: id, endpoint: endpoint, events: events)
    }
    collected.append(contentsOf: parsed)

    // Stop when the page is short of pageSize, when has_more is explicitly false,
    // or when no rows came back at all.
    if rows.count < pageSize { break }
    if let hasMore = data["has_more"] as? Bool, hasMore == false { break }

    offset += pageSize
  }

  if collected.count >= maxWebhooksToFetch {
    logWarn(
      "resendListWebhooks: hit safety cap of \(maxWebhooksToFetch); some webhooks may be hidden")
  }
  return collected
}
