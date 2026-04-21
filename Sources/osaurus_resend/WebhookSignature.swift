import CryptoKit
import Foundation

// MARK: - Svix Signature Verification
//
// Resend signs every webhook delivery via Svix using HMAC-SHA256 over
//   "${svix-id}.${svix-timestamp}.${body}"
// keyed by the secret bytes obtained by base64-decoding the portion of
// `signing_secret` after the `whsec_` prefix.
//
// The `svix-signature` header is a space-separated list of `version,base64sig`
// pairs (e.g., `v1,XXXX v1,YYYY`). Multiple entries support secret rotation;
// any matching signature accepts the payload.
//
// We also enforce a timestamp tolerance to defeat replay attacks.

/// Maximum age of a webhook delivery the plugin will accept, in seconds.
/// Resend's retry schedule starts at 5 seconds and the longest documented retry
/// is 10 hours, so 5 minutes (300 s) is the right replay window for fresh
/// deliveries while still being tight enough to defeat replays.
private let svixTimestampToleranceSeconds: Int64 = 300

enum WebhookSignatureError: Error, Equatable {
  case missingHeaders
  case malformedTimestamp
  case timestampOutOfTolerance
  case malformedSignatureHeader
  case noMatchingSignature
  case malformedSecret
}

/// Verifies a Svix-style signature against the given body using `signingSecret`.
///
/// Returns `.success(())` only when at least one v1 signature in the header
/// matches the HMAC computed from `(svixId, svixTimestamp, body)` and the
/// timestamp is within tolerance.
///
/// Headers should be passed exactly as received (case-insensitive lookup is
/// the caller's job; the helper `findHeader` covers the common casings).
func verifySvixSignature(
  svixId: String,
  svixTimestamp: String,
  svixSignature: String,
  body: String,
  signingSecret: String,
  now: Date = Date()
) -> Result<Void, WebhookSignatureError> {
  guard !svixId.isEmpty, !svixTimestamp.isEmpty, !svixSignature.isEmpty else {
    return .failure(.missingHeaders)
  }

  guard let ts = Int64(svixTimestamp) else {
    return .failure(.malformedTimestamp)
  }
  let nowSeconds = Int64(now.timeIntervalSince1970)
  if abs(nowSeconds - ts) > svixTimestampToleranceSeconds {
    return .failure(.timestampOutOfTolerance)
  }

  guard let secretBytes = decodeSigningSecret(signingSecret) else {
    return .failure(.malformedSecret)
  }

  let signedPayload = "\(svixId).\(svixTimestamp).\(body)"
  guard let payloadData = signedPayload.data(using: .utf8) else {
    return .failure(.malformedSignatureHeader)
  }
  let key = SymmetricKey(data: secretBytes)
  let mac = HMAC<SHA256>.authenticationCode(for: payloadData, using: key)
  let expectedSignature = Data(mac).base64EncodedString()

  let providedSignatures = parseSvixSignatureHeader(svixSignature)
  if providedSignatures.isEmpty {
    return .failure(.malformedSignatureHeader)
  }

  for sig in providedSignatures {
    if constantTimeEquals(sig, expectedSignature) {
      return .success(())
    }
  }
  return .failure(.noMatchingSignature)
}

/// Parses the space-separated `version,signature` list and returns the
/// base64 signature strings whose version is `v1`.
func parseSvixSignatureHeader(_ header: String) -> [String] {
  return header.split(separator: " ").compactMap { entry in
    let parts = entry.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    let version = String(parts[0]).lowercased()
    let sig = String(parts[1])
    return version == "v1" ? sig : nil
  }
}

/// Strips the `whsec_` prefix and base64-decodes the remainder to recover the
/// raw secret bytes Svix uses as the HMAC key.
private func decodeSigningSecret(_ secret: String) -> Data? {
  let trimmed: String
  if secret.hasPrefix("whsec_") {
    trimmed = String(secret.dropFirst("whsec_".count))
  } else {
    trimmed = secret
  }
  return Data(base64Encoded: trimmed)
}

/// Constant-time string comparison to avoid leaking signature bytes via timing.
private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
  let aBytes = Array(a.utf8)
  let bBytes = Array(b.utf8)
  if aBytes.count != bBytes.count { return false }
  var diff: UInt8 = 0
  for i in 0..<aBytes.count {
    diff |= aBytes[i] ^ bBytes[i]
  }
  return diff == 0
}

// MARK: - Header Lookup

/// Case-insensitively finds a header value across the common casings used by
/// proxies and tunnels. Returns `nil` only if the header is genuinely absent.
func findHeader(_ headers: [String: String]?, name: String) -> String? {
  guard let headers else { return nil }
  if let v = headers[name] { return v }
  let lower = name.lowercased()
  if let v = headers[lower] { return v }
  let upper = name.uppercased()
  if let v = headers[upper] { return v }
  for (k, v) in headers where k.lowercased() == lower {
    return v
  }
  return nil
}
