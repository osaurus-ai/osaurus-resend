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

  // Restore the tunnel URL into the in-memory ctx if a previous run persisted
  // it via host config; this lets the auto-reconcile below run without waiting
  // for an `onConfigChanged("tunnel_url", ...)` event after a restart.
  ctx.tunnelURL = configGet("tunnel_url")

  // Always reconcile on init: wipe every webhook of ours on the account and
  // register a fresh one. Guarantees exactly one active webhook after every
  // plugin start, even after crashes or restarts mid-config-change.
  let result = reconcileWebhook(ctx: ctx)
  if result.ok {
    logInfo("initPlugin: ready (webhook id=\(result.webhookId ?? "?"))")
  } else {
    logInfo("initPlugin: ready (webhook not configured: \(result.error ?? "unknown"))")
  }
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
  logDebug("onConfigChanged: key=\(key) hasValue=\(value != nil)")

  switch key {
  case "tunnel_url":
    ctx.tunnelURL = (value?.isEmpty == false) ? value : nil
    reconcileWebhook(ctx: ctx)

  case "api_key":
    // The webhook_id we have on file belongs to whatever account the previous
    // key referenced; drop it so reconcile starts clean against the new key.
    // (We can't delete the old account's webhook -- we no longer have its key.)
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
/// exists for our plugin endpoint.
///
/// Strategy ("nuke-and-create"):
/// 1. List every webhook on the account (paginated).
/// 2. Delete every entry whose endpoint matches our suffix.
/// 3. Create one fresh webhook with the current `tunnel_url` and the full
///    lifecycle event set.
///
/// Why not a PATCH/adopt reconcile:
/// - Eliminates the duplicate-trigger class of bug (multiple webhooks firing
///   per inbound email).
/// - Sidesteps Resend's 500 on duplicate-URL POSTs by always freeing the URL
///   first.
/// - Refreshes the `signing_secret` on every reconcile, so stale secrets
///   self-heal whenever the user rotates anything.
///
/// Returns a tri-tuple so callers (init, config-change, manual reset route)
/// can react uniformly. A missing api_key or tunnel_url is *not* an error;
/// it's just a no-op until both are configured.
@discardableResult
func reconcileWebhook(ctx: PluginContext) -> (ok: Bool, webhookId: String?, error: String?) {
  guard let apiKey = configGet("api_key"), !apiKey.isEmpty else {
    clearWebhookConfig()
    return (false, nil, "api_key not configured")
  }
  guard let tunnelURL = ctx.tunnelURL ?? configGet("tunnel_url"), !tunnelURL.isEmpty else {
    clearWebhookConfig()
    return (false, nil, "tunnel_url not configured")
  }

  let desiredURL = "\(tunnelURL)\(webhookEndpointSuffix)"
  logDebug("reconcileWebhook: desiredURL=\(desiredURL)")

  guard wipeOurWebhooks(apiKey: apiKey) else {
    clearWebhookConfig()
    return (false, nil, "failed to list existing webhooks")
  }

  let (webhookId, signingSecret) = resendCreateWebhook(apiKey: apiKey, endpoint: desiredURL)
  guard let webhookId else {
    clearWebhookConfig()
    return (false, nil, "failed to register webhook")
  }

  configSet("webhook_id", webhookId)
  if let signingSecret {
    configSet("signing_secret", signingSecret)
  } else {
    // Resend should always hand back a secret on create; if it doesn't,
    // signature verification can't engage. Log loudly and clear any stale value.
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
