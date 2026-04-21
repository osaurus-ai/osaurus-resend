import CryptoKit
import Foundation
import Testing

@testable import osaurus_resend

@Suite("Webhook Signature Verification", .serialized)
struct WebhookSignatureTests {

  // MARK: - Helpers

  /// Generates a fresh `whsec_<base64>` style secret backed by `secretBytes`.
  private func makeSecret(_ secretBytes: Data) -> String {
    return "whsec_\(secretBytes.base64EncodedString())"
  }

  /// Computes a valid v1 signature header for the given payload + secret.
  private func signWebhook(
    svixId: String, svixTimestamp: String, body: String, secretBytes: Data
  ) -> String {
    let signedPayload = "\(svixId).\(svixTimestamp).\(body)"
    let key = SymmetricKey(data: secretBytes)
    let mac = HMAC<SHA256>.authenticationCode(
      for: signedPayload.data(using: .utf8)!, using: key)
    return "v1,\(Data(mac).base64EncodedString())"
  }

  private func isSuccess(_ r: Result<Void, WebhookSignatureError>) -> Bool {
    if case .success = r { return true }
    return false
  }

  private func isFailure(
    _ r: Result<Void, WebhookSignatureError>, _ expected: WebhookSignatureError
  )
    -> Bool
  {
    if case .failure(let e) = r { return e == expected }
    return false
  }

  // MARK: - Tests

  @Test("Valid signature is accepted")
  func validSignatureAccepted() {
    let secretBytes = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    let secret = makeSecret(secretBytes)
    let svixId = "msg_test_001"
    let now = Date()
    let ts = String(Int64(now.timeIntervalSince1970))
    let body = "{\"type\":\"email.received\",\"data\":{\"email_id\":\"e1\"}}"
    let signature = signWebhook(
      svixId: svixId, svixTimestamp: ts, body: body, secretBytes: secretBytes)

    let result = verifySvixSignature(
      svixId: svixId, svixTimestamp: ts, svixSignature: signature,
      body: body, signingSecret: secret, now: now)

    #expect(isSuccess(result))
  }

  @Test("Tampered body is rejected")
  func tamperedBodyRejected() {
    let secretBytes = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    let secret = makeSecret(secretBytes)
    let svixId = "msg_test_002"
    let now = Date()
    let ts = String(Int64(now.timeIntervalSince1970))
    let body = "{\"type\":\"email.received\",\"data\":{\"email_id\":\"original\"}}"
    let signature = signWebhook(
      svixId: svixId, svixTimestamp: ts, body: body, secretBytes: secretBytes)

    let tamperedBody = "{\"type\":\"email.received\",\"data\":{\"email_id\":\"injected\"}}"
    let result = verifySvixSignature(
      svixId: svixId, svixTimestamp: ts, svixSignature: signature,
      body: tamperedBody, signingSecret: secret, now: now)

    #expect(isFailure(result, .noMatchingSignature))
  }

  @Test("Old timestamp (replay attack) is rejected")
  func replayRejected() {
    let secretBytes = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    let secret = makeSecret(secretBytes)
    let svixId = "msg_test_003"
    let now = Date()
    // Build a signature with a timestamp 10 minutes in the past.
    let oldTimestamp = String(Int64(now.timeIntervalSince1970) - 600)
    let body = "{}"
    let signature = signWebhook(
      svixId: svixId, svixTimestamp: oldTimestamp, body: body, secretBytes: secretBytes)

    let result = verifySvixSignature(
      svixId: svixId, svixTimestamp: oldTimestamp, svixSignature: signature,
      body: body, signingSecret: secret, now: now)

    #expect(isFailure(result, .timestampOutOfTolerance))
  }

  @Test("Signature header with rotated secrets accepts when any matches")
  func rotatedSecretsAccepts() {
    let secretBytes = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    let secret = makeSecret(secretBytes)
    let svixId = "msg_test_004"
    let now = Date()
    let ts = String(Int64(now.timeIntervalSince1970))
    let body = "{\"hello\":\"world\"}"
    let validSig = signWebhook(
      svixId: svixId, svixTimestamp: ts, body: body, secretBytes: secretBytes)

    // Header with a stale signature first, then the valid one.
    let header = "v1,bogusbase64bogusbase64bogusbase64bogusbase64bogus= \(validSig)"
    let result = verifySvixSignature(
      svixId: svixId, svixTimestamp: ts, svixSignature: header,
      body: body, signingSecret: secret, now: now)

    #expect(isSuccess(result))
  }

  @Test("Missing svix headers is reported as missingHeaders")
  func missingHeaders() {
    let result = verifySvixSignature(
      svixId: "", svixTimestamp: "", svixSignature: "",
      body: "{}", signingSecret: "whsec_abc")
    #expect(isFailure(result, .missingHeaders))
  }

  @Test("Malformed timestamp is reported")
  func malformedTimestamp() {
    let result = verifySvixSignature(
      svixId: "x", svixTimestamp: "not-a-number", svixSignature: "v1,xxx",
      body: "{}", signingSecret: "whsec_dGVzdA==")
    #expect(isFailure(result, .malformedTimestamp))
  }

  @Test("Malformed secret is reported")
  func malformedSecret() {
    let now = Date()
    let ts = String(Int64(now.timeIntervalSince1970))
    let result = verifySvixSignature(
      svixId: "x", svixTimestamp: ts, svixSignature: "v1,xxx",
      body: "{}", signingSecret: "whsec_!!!not-base64!!!", now: now)
    #expect(isFailure(result, .malformedSecret))
  }

  @Test("findHeader is case-insensitive")
  func headerLookupCaseInsensitive() {
    let headers = ["Svix-Id": "abc", "svix-timestamp": "123", "SVIX-SIGNATURE": "v1,x"]
    #expect(findHeader(headers, name: "svix-id") == "abc")
    #expect(findHeader(headers, name: "Svix-Timestamp") == "123")
    #expect(findHeader(headers, name: "Svix-Signature") == "v1,x")
    #expect(findHeader(headers, name: "X-Missing") == nil)
  }

  @Test("Webhook handler rejects unsigned delivery when secret is configured")
  func handlerRejectsUnsignedWhenSecretConfigured() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    mockConfig["sender_policy"] = "open"
    mockConfig["api_key"] = "re_test"
    mockConfig["from_email"] = "agent@d.com"
    let secretBytes = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    mockConfig["signing_secret"] = makeSecret(secretBytes)

    let body = "{\"type\":\"email.received\",\"data\":{\"email_id\":\"e1\"}}"
    let routeReq: [String: Any] = [
      "route_id": "webhook",
      "method": "POST",
      "path": "/webhook",
      "body": body,
        // Headers omitted intentionally.
    ]
    guard let reqJSON = makeJSONString(routeReq) else {
      #expect(Bool(false), "serialize failed")
      return
    }

    let result = handleRoute(ctx: PluginContext(), requestJSON: reqJSON)
    let parsed = parseRouteResponse(result)
    #expect(parsed.status == 401)
    #expect(mockDispatchCalls.isEmpty)
  }

  @Test("Webhook handler accepts properly-signed delivery")
  func handlerAcceptsValidSignature() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    mockConfig["sender_policy"] = "open"
    mockConfig["api_key"] = "re_test"
    mockConfig["from_email"] = "agent@d.com"
    let secretBytes = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    mockConfig["signing_secret"] = makeSecret(secretBytes)

    let body =
      "{\"type\":\"email.received\",\"data\":{\"email_id\":\"e1\",\"from\":\"a@a.com\",\"to\":[\"agent@d.com\"]}}"
    let svixId = "msg_signed_001"
    let now = Date()
    let ts = String(Int64(now.timeIntervalSince1970))
    let signature = signWebhook(
      svixId: svixId, svixTimestamp: ts, body: body, secretBytes: secretBytes)

    MockHost.pushReceivedEmailResponse(
      emailId: "e1", from: "a@a.com", to: ["agent@d.com"],
      subject: "test", text: "hi", html: nil, messageId: "<msg-1>")

    let routeReq: [String: Any] = [
      "route_id": "webhook",
      "method": "POST",
      "path": "/webhook",
      "body": body,
      "headers": [
        "svix-id": svixId,
        "svix-timestamp": ts,
        "svix-signature": signature,
      ],
    ]
    guard let reqJSON = makeJSONString(routeReq) else {
      #expect(Bool(false), "serialize failed")
      return
    }

    let result = handleRoute(ctx: PluginContext(), requestJSON: reqJSON)
    let parsed = parseRouteResponse(result)
    #expect(parsed.status == 200)
    #expect(mockDispatchCalls.count == 1)
  }

  @Test(
    "Webhook handler accepts unsigned delivery when no secret is configured (graceful migration)")
  func handlerAcceptsUnsignedWhenNoSecret() {
    MockHost.setUp()
    DatabaseManager.initSchema()
    mockConfig["sender_policy"] = "open"
    mockConfig["api_key"] = "re_test"
    mockConfig["from_email"] = "agent@d.com"
    // No signing_secret.

    MockHost.pushReceivedEmailResponse(
      emailId: "e2", from: "a@a.com", to: ["agent@d.com"],
      subject: "test", text: "hi", html: nil, messageId: "<msg-2>")

    let body =
      "{\"type\":\"email.received\",\"data\":{\"email_id\":\"e2\",\"from\":\"a@a.com\",\"to\":[\"agent@d.com\"]}}"
    let routeReq: [String: Any] = [
      "route_id": "webhook",
      "method": "POST",
      "path": "/webhook",
      "body": body,
    ]
    guard let reqJSON = makeJSONString(routeReq) else { return }

    let result = handleRoute(ctx: PluginContext(), requestJSON: reqJSON)
    let parsed = parseRouteResponse(result)
    #expect(parsed.status == 200)
    #expect(mockDispatchCalls.count == 1)
  }
}

// MARK: - Local helpers (avoid colliding with WebhookTests private helpers)

private struct ParsedRouteResponse {
  let status: Int
  let body: String
}

private func parseRouteResponse(_ json: String) -> ParsedRouteResponse {
  guard let data = json.data(using: .utf8),
    let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  else { return ParsedRouteResponse(status: 0, body: "") }
  let status = dict["status"] as? Int ?? 0
  let body = dict["body"] as? String ?? ""
  return ParsedRouteResponse(status: status, body: body)
}
