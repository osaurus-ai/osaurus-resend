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

// MARK: - Lifecycle

func initPlugin(_ ctx: PluginContext) {
  logDebug("initPlugin: starting")
  DatabaseManager.initSchema()
  configDelete("webhook_registered")
  logInfo("initPlugin: ready")
}

func destroyPlugin(_ ctx: PluginContext) {
  if let apiKey = configGet("api_key"), !apiKey.isEmpty,
    let webhookId = configGet("webhook_id"), !webhookId.isEmpty
  {
    _ = resendDeleteWebhook(apiKey: apiKey, webhookId: webhookId)
    logInfo("Webhook deleted on destroy")
  }
  configDelete("webhook_registered")
}

func onConfigChanged(ctx: PluginContext, key: String, value: String?) {
  logDebug("onConfigChanged: key=\(key) hasValue=\(value != nil)")

  switch key {
  case "tunnel_url":
    guard let newURL = value, !newURL.isEmpty else {
      ctx.tunnelURL = nil
      return
    }
    ctx.tunnelURL = newURL
    guard let apiKey = configGet("api_key"), !apiKey.isEmpty else {
      logDebug("onConfigChanged: tunnel_url stored, waiting for api_key")
      return
    }
    setupWebhook(ctx: ctx, apiKey: apiKey, tunnelURL: newURL)

  case "api_key":
    // Note: when the user rotates to a different Resend account, we cannot
    // delete the old account's webhook -- we no longer have its API key.
    // The reconcile in setupWebhook will at least dedupe on the new account.
    let newKey = (value?.isEmpty == false) ? value : nil

    guard let newKey else {
      configDelete("webhook_id")
      configDelete("signing_secret")
      configDelete("webhook_registered")
      logInfo("API key cleared")
      return
    }

    // Stored webhook_id belongs to whichever account the previous key referenced;
    // drop it so reconcile rediscovers from the new account.
    configDelete("webhook_id")
    configDelete("signing_secret")

    guard let tunnelURL = ctx.tunnelURL, !tunnelURL.isEmpty else {
      logDebug("onConfigChanged: api_key stored, waiting for tunnel_url")
      return
    }

    setupWebhook(ctx: ctx, apiKey: newKey, tunnelURL: tunnelURL)

  case "sender_policy":
    logInfo("Sender policy changed to: \(value ?? "known")")

  case "allowed_senders":
    logInfo("Allowed senders updated: \(value ?? "(empty)")")

  default:
    break
  }
}

// MARK: - Webhook Setup (Reconcile)

/// Idempotently ensures exactly one Resend webhook exists for our plugin endpoint.
///
/// Flow:
/// 1. List all webhooks on the account.
/// 2. Filter to those whose endpoint targets our plugin path.
/// 3. Pick a keeper (preferring one that already matches the desired URL).
/// 4. Delete any extras.
/// 5. PATCH the keeper if its endpoint differs, otherwise create one.
private func setupWebhook(ctx: PluginContext, apiKey: String, tunnelURL: String) {
  let pluginId = "osaurus.resend"
  let endpointSuffix = "/plugins/\(pluginId)/webhook"
  let desiredURL = "\(tunnelURL)\(endpointSuffix)"

  logDebug("setupWebhook: reconciling for \(desiredURL)")

  guard let existing = resendListWebhooks(apiKey: apiKey) else {
    logError("setupWebhook: failed to list webhooks; aborting")
    configDelete("webhook_registered")
    return
  }

  let ours = existing.filter { $0.endpoint.hasSuffix(endpointSuffix) }
  let keeper = ours.first(where: { $0.endpoint == desiredURL }) ?? ours.first

  for w in ours where w.id != keeper?.id {
    if resendDeleteWebhook(apiKey: apiKey, webhookId: w.id) {
      logInfo("setupWebhook: deleted stale webhook \(w.id) endpoint=\(w.endpoint)")
    } else {
      logWarn("setupWebhook: failed to delete stale webhook \(w.id)")
    }
  }

  if let keeper {
    if keeper.endpoint != desiredURL {
      guard resendUpdateWebhook(apiKey: apiKey, webhookId: keeper.id, endpoint: desiredURL) else {
        logError("setupWebhook: failed to update webhook endpoint")
        configDelete("webhook_registered")
        return
      }
      logInfo("setupWebhook: updated webhook \(keeper.id) -> \(desiredURL)")
    } else {
      logDebug("setupWebhook: webhook \(keeper.id) already points at \(desiredURL)")
    }
    configSet("webhook_id", keeper.id)
    configSet("webhook_registered", "true")
    return
  }

  let (webhookId, signingSecret) = resendCreateWebhook(apiKey: apiKey, endpoint: desiredURL)
  guard let webhookId else {
    logError("setupWebhook: failed to register webhook")
    configDelete("webhook_registered")
    return
  }
  configSet("webhook_id", webhookId)
  if let signingSecret {
    configSet("signing_secret", signingSecret)
  }
  configSet("webhook_registered", "true")
  logInfo("setupWebhook: registered \(desiredURL) (id: \(webhookId))")
}
