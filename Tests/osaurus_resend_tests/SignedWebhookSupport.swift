import CryptoKit
import Foundation

@testable import osaurus_resend

// MARK: - Signed Webhook Test Support
//
// The webhook route fails closed: deliveries are only processed when a
// signing secret is configured and the Svix signature verifies. These helpers
// let every suite exercise the processing pipeline with properly signed
// requests.

nonisolated(unsafe) var mockSigningSecretBytes = Data()

enum SignedWebhook {
  /// Generates a signing secret and installs it into the mock config.
  /// Call after `MockHost.setUp()`.
  static func installSecret() {
    let bytes = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    mockStateLock.lock()
    mockSigningSecretBytes = bytes
    mockConfig["signing_secret"] = "whsec_\(bytes.base64EncodedString())"
    mockStateLock.unlock()
  }

  /// Computes a valid v1 signature for the installed secret.
  static func signature(svixId: String, timestamp: String, body: String) -> String {
    let payload = "\(svixId).\(timestamp).\(body)"
    let key = SymmetricKey(data: mockSigningSecretBytes)
    let mac = HMAC<SHA256>.authenticationCode(
      for: payload.data(using: .utf8)!, using: key)
    return "v1,\(Data(mac).base64EncodedString())"
  }

  /// Builds a `handleRoute`-ready request JSON for a signed POST /webhook
  /// delivery, installing a signing secret first if none is present.
  static func requestJSON(body: String, svixId: String = "msg_\(UUID().uuidString)") -> String {
    if mockConfig["signing_secret"] == nil { installSecret() }
    let ts = String(Int64(Date().timeIntervalSince1970))
    let routeReq: [String: Any] = [
      "route_id": "webhook",
      "method": "POST",
      "path": "/webhook",
      "body": body,
      "headers": [
        "content-type": "application/json",
        "svix-id": svixId,
        "svix-timestamp": ts,
        "svix-signature": signature(svixId: svixId, timestamp: ts, body: body),
      ],
    ]
    return makeJSONString(routeReq) ?? "{}"
  }

  /// Sends a signed webhook delivery through `handleRoute` and returns the
  /// parsed status/body.
  @discardableResult
  static func send(
    ctx: PluginContext, body: String, svixId: String = "msg_\(UUID().uuidString)"
  ) -> (status: Int, body: String) {
    let result = handleRoute(ctx: ctx, requestJSON: requestJSON(body: body, svixId: svixId))
    guard let data = result.data(using: .utf8),
      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return (0, "") }
    return (dict["status"] as? Int ?? 0, dict["body"] as? String ?? "")
  }
}
