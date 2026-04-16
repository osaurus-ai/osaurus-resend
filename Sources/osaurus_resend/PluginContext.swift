import Foundation

// MARK: - Plugin Context

final class PluginContext: @unchecked Sendable {
  var tunnelURL: String?
  var taskArtifacts: [String: [CollectedArtifact]] = [:]
  var taskDispatchTimestamps: [String: Int] = [:]
  var processedEmailIds: Set<String> = []
  private static let maxProcessedIds = 500

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
    let newKey = (value?.isEmpty == false) ? value : nil

    if let oldWebhookId = configGet("webhook_id"), !oldWebhookId.isEmpty,
      let oldKey = configGet("api_key"), !oldKey.isEmpty
    {
      _ = resendDeleteWebhook(apiKey: oldKey, webhookId: oldWebhookId)
      configDelete("webhook_id")
      configDelete("signing_secret")
      configDelete("webhook_registered")
      logInfo("Old webhook deleted")
    }

    guard let newKey else {
      configDelete("webhook_registered")
      logInfo("API key cleared")
      return
    }

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

// MARK: - Webhook Setup

private func setupWebhook(ctx: PluginContext, apiKey: String, tunnelURL: String) {
  let pluginId = "osaurus.resend"
  let webhookURL = "\(tunnelURL)/plugins/\(pluginId)/webhook"

  logDebug("setupWebhook: registering at \(webhookURL)")

  let (webhookId, signingSecret) = resendCreateWebhook(apiKey: apiKey, endpoint: webhookURL)

  guard let webhookId else {
    logError("Failed to register webhook")
    configDelete("webhook_registered")
    return
  }

  configSet("webhook_id", webhookId)
  if let signingSecret {
    configSet("signing_secret", signingSecret)
  }
  configSet("webhook_registered", "true")
  logInfo("Webhook registered at \(webhookURL) (id: \(webhookId))")
}
