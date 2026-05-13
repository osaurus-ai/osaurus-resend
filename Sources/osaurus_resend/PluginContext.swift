import Foundation

// MARK: - Plugin Context

final class PluginContext: @unchecked Sendable {
  var tunnelURL: String?
  var taskArtifacts: [String: [CollectedArtifact]] = [:]
  var taskDispatchTimestamps: [String: Int] = [:]

  let sendTool = ResendSendTool()
  let replyTool = ResendReplyTool()
  let listThreadsTool = ResendListThreadsTool()
  let getThreadTool = ResendGetThreadTool()
  let labelThreadTool = ResendLabelThreadTool()
}

// MARK: - Webhook Constants

/// Plugin's webhook endpoint suffix. Any webhook on the Resend account whose
/// endpoint ends with this string is considered owned by this plugin and is
/// safe to delete during reconciliation. Webhooks belonging to other plugins
/// or apps are never touched.
let webhookEndpointSuffix = "/plugins/osaurus.resend/webhook"

// MARK: - Lifecycle

func initPlugin(_ ctx: PluginContext) {
  logDebug("initPlugin: starting")
  DatabaseManager.initSchema()

  // Pure DB + state restore. Reconciliation lives in `onConfigChanged`: init
  // runs without an active agent context, and the host force-redelivers
  // `tunnel_url` post-init (and on every tunnel reconnect) anyway.
  ctx.tunnelURL = configGet("tunnel_url")
  logInfo("initPlugin: ready (waiting for config push)")
}

func destroyPlugin(_ ctx: PluginContext) {
  if let apiKey = configGet("api_key"), !apiKey.isEmpty,
    let webhookId = configGet("webhook_id"), !webhookId.isEmpty
  {
    _ = resendDeleteWebhook(apiKey: apiKey, webhookId: webhookId)
    logInfo("destroyPlugin: deleted webhook \(webhookId)")
  }
  configDelete("webhook_registered")
}

func onConfigChanged(ctx: PluginContext, key: String, value: String?) {
  // v6 ABI mirror probe: explicit opt-out keeps the rest of this function
  // off the host's pre-flight handshake hot path.
  if key == "__osaurus_abi_probe__" { return }

  logDebug("onConfigChanged: key=\(key) hasValue=\(value != nil)")

  switch key {
  case "tunnel_url":
    ctx.tunnelURL = (value?.isEmpty == false) ? value : nil
    reconcileWebhook(ctx: ctx)

  case "api_key":
    // Stored webhook_id belongs to the previous account, drop it so
    // reconcile starts clean. (We can't delete the old account's webhook
    // anymore — we no longer have its key.)
    clearWebhookConfig()
    reconcileWebhook(ctx: ctx)

  case "sender_policy":
    logInfo("Sender policy changed to: \(value ?? "known")")

  case "allowed_senders":
    logInfo("Allowed senders updated: \(value ?? "(empty)")")

  default:
    break
  }
}

// MARK: - Webhook Reconciliation (single entry point)

/// Single, idempotent entry point that ensures exactly one Resend webhook
/// exists for our plugin endpoint. "Nuke-and-create" strategy: list, delete
/// every entry matching our suffix, then create one fresh webhook with the
/// current `tunnel_url` and the full lifecycle event set.
///
/// Trade-off vs. PATCH/adopt: eliminates duplicate-trigger bugs (multiple
/// webhooks firing per email), sidesteps Resend's 500 on duplicate-URL POSTs,
/// and refreshes the `signing_secret` on every reconcile so stale secrets
/// self-heal.
///
/// A missing `api_key` or `tunnel_url` is not an error; it's a no-op until
/// both are configured.
@discardableResult
func reconcileWebhook(ctx: PluginContext) -> (ok: Bool, webhookId: String?, error: String?) {
  func fail(_ reason: String) -> (ok: Bool, webhookId: String?, error: String?) {
    clearWebhookConfig()
    return (false, nil, reason)
  }

  guard let apiKey = configGet("api_key"), !apiKey.isEmpty else {
    return fail("api_key not configured")
  }
  guard let tunnelURL = ctx.tunnelURL ?? configGet("tunnel_url"), !tunnelURL.isEmpty else {
    return fail("tunnel_url not configured")
  }

  let desiredURL = "\(tunnelURL)\(webhookEndpointSuffix)"
  logDebug("reconcileWebhook: desiredURL=\(desiredURL)")

  guard wipeOurWebhooks(apiKey: apiKey) else {
    return fail("failed to list existing webhooks")
  }

  let (webhookId, signingSecret) = resendCreateWebhook(apiKey: apiKey, endpoint: desiredURL)
  guard let webhookId else {
    return fail("failed to register webhook")
  }

  configSet("webhook_id", webhookId)
  if let signingSecret {
    configSet("signing_secret", signingSecret)
  } else {
    // Resend should always return a secret on create; without one, signature
    // verification can't engage. Log loudly and clear any stale value.
    logWarn("reconcileWebhook: webhook \(webhookId) created but no signing_secret returned")
    configDelete("signing_secret")
  }
  configSet("webhook_registered", "true")
  logInfo("reconcileWebhook: registered \(desiredURL) (id: \(webhookId))")
  return (true, webhookId, nil)
}

/// Deletes every webhook on the account whose endpoint matches this plugin's
/// suffix. Returns `false` only when the listing call itself fails so callers
/// can distinguish transport failure from "nothing to wipe". Individual delete
/// failures are logged but don't fail the whole operation.
@discardableResult
func wipeOurWebhooks(apiKey: String) -> Bool {
  guard let existing = resendListWebhooks(apiKey: apiKey) else {
    return false
  }
  let ours = existing.filter { $0.endpoint.hasSuffix(webhookEndpointSuffix) }
  for w in ours {
    if resendDeleteWebhook(apiKey: apiKey, webhookId: w.id) {
      logInfo("wipeOurWebhooks: deleted \(w.id) endpoint=\(w.endpoint)")
    } else {
      logWarn("wipeOurWebhooks: failed to delete \(w.id) endpoint=\(w.endpoint)")
    }
  }
  return true
}

private func clearWebhookConfig() {
  configDelete("webhook_id")
  configDelete("signing_secret")
  configDelete("webhook_registered")
}
