import Foundation

// MARK: - C ABI Surface (v2)

typealias osr_plugin_ctx_t = UnsafeMutableRawPointer

// Config + Storage + Logging
typealias osr_config_get_fn = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_config_set_fn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
typealias osr_config_delete_fn = @convention(c) (UnsafePointer<CChar>?) -> Void
typealias osr_db_exec_fn =
  @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_db_query_fn =
  @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_log_fn = @convention(c) (Int32, UnsafePointer<CChar>?) -> Void

// Agent Dispatch
typealias osr_dispatch_fn = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_task_status_fn = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_dispatch_cancel_fn = @convention(c) (UnsafePointer<CChar>?) -> Void
typealias osr_dispatch_clarify_fn =
  @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void

// Inference
typealias osr_complete_fn = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_complete_stream_fn =
  @convention(c) (
    UnsafePointer<CChar>?,
    (@convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void)?,
    UnsafeMutableRawPointer?
  ) -> UnsafePointer<CChar>?
typealias osr_embed_fn = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
typealias osr_list_models_fn = @convention(c) () -> UnsafePointer<CChar>?

// HTTP Client
typealias osr_http_request_fn = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?

// File I/O
typealias osr_file_read_fn = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?

// Extended Agent Dispatch
typealias osr_list_active_tasks_fn = @convention(c) () -> UnsafePointer<CChar>?
typealias osr_send_draft_fn =
  @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
typealias osr_dispatch_interrupt_fn =
  @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
typealias osr_dispatch_add_issue_fn =
  @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?

struct osr_host_api {
  var version: UInt32 = 0

  var config_get: osr_config_get_fn?
  var config_set: osr_config_set_fn?
  var config_delete: osr_config_delete_fn?
  var db_exec: osr_db_exec_fn?
  var db_query: osr_db_query_fn?
  var log: osr_log_fn?

  var dispatch: osr_dispatch_fn?
  var task_status: osr_task_status_fn?
  var dispatch_cancel: osr_dispatch_cancel_fn?
  var dispatch_clarify: osr_dispatch_clarify_fn?

  var complete: osr_complete_fn?
  var complete_stream: osr_complete_stream_fn?
  var embed: osr_embed_fn?
  var list_models: osr_list_models_fn?

  var http_request: osr_http_request_fn?

  var file_read: osr_file_read_fn?

  var list_active_tasks: osr_list_active_tasks_fn?
  var send_draft: osr_send_draft_fn?
  var dispatch_interrupt: osr_dispatch_interrupt_fn?
  var dispatch_add_issue: osr_dispatch_add_issue_fn?
}

private typealias osr_free_string_t = @convention(c) (UnsafePointer<CChar>?) -> Void
private typealias osr_init_t = @convention(c) () -> osr_plugin_ctx_t?
private typealias osr_destroy_t = @convention(c) (osr_plugin_ctx_t?) -> Void
private typealias osr_get_manifest_t = @convention(c) (osr_plugin_ctx_t?) -> UnsafePointer<CChar>?
private typealias osr_invoke_t =
  @convention(c) (
    osr_plugin_ctx_t?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?
  ) -> UnsafePointer<CChar>?
private typealias osr_handle_route_t =
  @convention(c) (osr_plugin_ctx_t?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
private typealias osr_on_config_changed_t =
  @convention(c) (osr_plugin_ctx_t?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
private typealias osr_on_task_event_t =
  @convention(c) (osr_plugin_ctx_t?, UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?) -> Void

private struct osr_plugin_api {
  var free_string: osr_free_string_t?
  var `init`: osr_init_t?
  var destroy: osr_destroy_t?
  var get_manifest: osr_get_manifest_t?
  var invoke: osr_invoke_t?
  var version: UInt32 = 0
  var handle_route: osr_handle_route_t?
  var on_config_changed: osr_on_config_changed_t?
  var on_task_event: osr_on_task_event_t?
}

// MARK: - Task Lifecycle Event Types

let OSR_TASK_EVENT_STARTED: Int32 = 0
let OSR_TASK_EVENT_ACTIVITY: Int32 = 1
let OSR_TASK_EVENT_PROGRESS: Int32 = 2
let OSR_TASK_EVENT_CLARIFICATION: Int32 = 3
let OSR_TASK_EVENT_COMPLETED: Int32 = 4
let OSR_TASK_EVENT_FAILED: Int32 = 5
let OSR_TASK_EVENT_CANCELLED: Int32 = 6
let OSR_TASK_EVENT_OUTPUT: Int32 = 7
let OSR_TASK_EVENT_DRAFT: Int32 = 8

// MARK: - Global State

nonisolated(unsafe) var hostAPI: UnsafePointer<osr_host_api>?

func makeCString(_ s: String) -> UnsafePointer<CChar>? {
  guard let ptr = strdup(s) else { return nil }
  return UnsafePointer(ptr)
}

// MARK: - Plugin API

private nonisolated(unsafe) var api: osr_plugin_api = {
  var api = osr_plugin_api()

  api.free_string = { ptr in
    if let p = ptr { free(UnsafeMutableRawPointer(mutating: p)) }
  }

  api.`init` = {
    let ctx = PluginContext()
    initPlugin(ctx)
    logInfo("Plugin init complete")
    return Unmanaged.passRetained(ctx).toOpaque()
  }

  api.destroy = { ctxPtr in
    guard let ctxPtr else { return }
    let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
    destroyPlugin(ctx)
    Unmanaged<PluginContext>.fromOpaque(ctxPtr).release()
  }

  api.get_manifest = { _ in
    let manifest = """
      {
        "plugin_id": "osaurus.resend",
        "name": "Resend (Email)",
        "version": "0.1.0",
        "description": "Send, receive, and manage email through Resend",
        "instructions": "You have access to email via the Resend plugin. This is asynchronous email communication, not instant messaging. Write complete, professional, self-contained responses -- the recipient may not read your reply for hours or days. Every response should be thorough enough to stand on its own without requiring immediate follow-up.\\n\\nWhen you receive an inbound email, the thread_id is provided in the prompt. Use resend_reply with that thread_id to respond. The reply is sent to all thread participants by default (reply-all). If you need to reply only to a specific person, pass the to parameter.\\n\\nTo compose a new email to someone not in the current thread, use resend_send. This creates a new thread and authorizes the recipient for future replies.\\n\\nTo review past conversations, use resend_list_threads (filterable by participant or label) for summaries, and resend_get_thread for full message bodies. Use resend_label_thread to tag threads for organization (e.g. scheduling, invoices, urgent).\\n\\nWhen producing files during a task, they are automatically attached to your next reply. You do not need to handle attachments manually.",
        "license": "MIT",
        "authors": [],
        "min_macos": "15.0",
        "min_osaurus": "0.5.0",
        "capabilities": {
          "tools": [
            {
              "id": "resend_send",
              "description": "Send a new email to start a new conversation. Use this when you need to email someone who is not part of the current thread (e.g. scheduling with a new contact, forwarding information to another person). Creates a new thread. The recipient will be able to reply back.",
              "parameters": {
                "type": "object",
                "properties": {
                  "to": { "type": "string", "description": "Recipient email address" },
                  "subject": { "type": "string", "description": "Email subject line" },
                  "body": { "type": "string", "description": "Email body content. HTML is supported for formatting." },
                  "cc": { "type": "string", "description": "CC recipient email address (optional)" },
                  "bcc": { "type": "string", "description": "BCC recipient email address (optional)" }
                },
                "required": ["to", "subject", "body"]
              },
              "requirements": [],
              "permission_policy": "auto"
            },
            {
              "id": "resend_reply",
              "description": "Reply to an email in an existing thread. Sends to all thread participants by default (reply-all). Use the optional 'to' parameter to reply to only one specific person. Threading headers are handled automatically so the reply appears in the same conversation in the recipient's inbox. Any files produced during the current task are attached automatically.",
              "parameters": {
                "type": "object",
                "properties": {
                  "thread_id": { "type": "string", "description": "The thread ID to reply in (provided in the inbound email prompt)" },
                  "body": { "type": "string", "description": "Reply body content. HTML is supported for formatting." },
                  "to": { "type": "string", "description": "Send to only this address instead of all participants (optional)" }
                },
                "required": ["thread_id", "body"]
              },
              "requirements": [],
              "permission_policy": "auto"
            },
            {
              "id": "resend_list_threads",
              "description": "List email conversation threads. Returns thread summaries (subject, participants, labels, last message preview). Use this to find threads by participant email or label, or to see recent conversations. For full message content, follow up with resend_get_thread.",
              "parameters": {
                "type": "object",
                "properties": {
                  "participant": { "type": "string", "description": "Filter to threads involving this email address" },
                  "label": { "type": "string", "description": "Filter to threads with this label (e.g. 'invoices', 'scheduling')" },
                  "limit": { "type": "integer", "description": "Max threads to return (default 20, max 100)" }
                },
                "required": []
              },
              "requirements": [],
              "permission_policy": "auto"
            },
            {
              "id": "resend_get_thread",
              "description": "Get the full details of a specific email thread, including complete message bodies in chronological order. Use this to read the full conversation, quote a previous message, or gather context before replying.",
              "parameters": {
                "type": "object",
                "properties": {
                  "thread_id": { "type": "string", "description": "Thread ID to retrieve" },
                  "limit": { "type": "integer", "description": "Max messages to return (default 20, max 200)" }
                },
                "required": ["thread_id"]
              },
              "requirements": [],
              "permission_policy": "auto"
            },
            {
              "id": "resend_label_thread",
              "description": "Add or remove labels on a thread to organize conversations. Labels are freeform strings -- use whatever makes sense for the context (e.g. scheduling, invoices, urgent, follow-up). Threads can be filtered by label using resend_list_threads.",
              "parameters": {
                "type": "object",
                "properties": {
                  "thread_id": { "type": "string", "description": "Thread ID to update labels on" },
                  "add": {
                    "type": "array",
                    "items": { "type": "string" },
                    "description": "Labels to add to the thread"
                  },
                  "remove": {
                    "type": "array",
                    "items": { "type": "string" },
                    "description": "Labels to remove from the thread"
                  }
                },
                "required": ["thread_id"]
              },
              "requirements": [],
              "permission_policy": "auto"
            }
          ],
          "artifact_handler": true,
          "routes": [
            {
              "id": "webhook",
              "path": "/webhook",
              "methods": ["POST"],
              "description": "Resend webhook endpoint for inbound emails",
              "auth": "verify"
            },
            {
              "id": "health",
              "path": "/health",
              "methods": ["GET"],
              "description": "Health check",
              "auth": "owner"
            }
          ],
          "config": {
            "title": "Resend (Email)",
            "sections": [
              {
                "title": "Resend Configuration",
                "fields": [
                  {
                    "key": "api_key",
                    "type": "secret",
                    "label": "API Key",
                    "placeholder": "re_xxxxxxxxx",
                    "description": "Get your API key from [Resend](https://resend.com/api-keys)",
                    "validation": { "required": true }
                  },
                  {
                    "key": "from_email",
                    "type": "text",
                    "label": "From Email",
                    "placeholder": "agent@yourdomain.com",
                    "description": "Sender email address (must be a verified domain in Resend)",
                    "validation": { "required": true }
                  },
                  {
                    "key": "from_name",
                    "type": "text",
                    "label": "From Name",
                    "placeholder": "Agent",
                    "description": "Display name for outgoing emails"
                  }
                ]
              },
              {
                "title": "Webhook",
                "fields": [
                  {
                    "key": "webhook_url",
                    "type": "readonly",
                    "label": "Webhook URL",
                    "value_template": "{{plugin_url}}/webhook",
                    "copyable": true
                  },
                  {
                    "key": "webhook_status",
                    "type": "status",
                    "label": "Webhook",
                    "connected_when": "webhook_registered"
                  }
                ]
              },
              {
                "title": "Authorization",
                "fields": [
                  {
                    "key": "sender_policy",
                    "type": "select",
                    "label": "Sender Policy",
                    "description": "Controls who can email the agent. 'known' only accepts emails from allowed senders and existing thread participants. 'open' accepts all emails.",
                    "default": "known",
                    "options": [
                      { "value": "known", "label": "Known senders only" },
                      { "value": "open", "label": "Accept all emails" }
                    ]
                  },
                  {
                    "key": "allowed_senders",
                    "type": "text",
                    "label": "Allowed Senders",
                    "placeholder": "alice@gmail.com, @company.com",
                    "description": "Comma-separated email addresses or @domains. These senders are always authorized."
                  }
                ]
              }
            ]
          }
        },
        "docs": {
          "readme": "README.md",
          "links": [
            { "label": "Resend Docs", "url": "https://resend.com/docs" },
            { "label": "Resend API", "url": "https://resend.com/docs/api-reference/introduction" }
          ]
        }
      }
      """
    return makeCString(manifest)
  }

  api.invoke = { ctxPtr, typePtr, idPtr, payloadPtr in
    guard let ctxPtr, let typePtr, let idPtr, let payloadPtr else { return nil }

    let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
    let type = String(cString: typePtr)
    let id = String(cString: idPtr)
    let payload = String(cString: payloadPtr)

    logDebug("invoke: type=\(type) id=\(id)")

    if type == "artifact" && id == "share" {
      return makeCString(handleArtifactShare(ctx: ctx, payload: payload))
    }

    guard type == "tool" else {
      return makeCString("{\"error\":\"Unknown capability type\"}")
    }

    let result: String
    switch id {
    case ctx.sendTool.name:
      result = ctx.sendTool.run(args: payload, ctx: ctx)
    case ctx.replyTool.name:
      result = ctx.replyTool.run(args: payload, ctx: ctx)
    case ctx.listThreadsTool.name:
      result = ctx.listThreadsTool.run(args: payload)
    case ctx.getThreadTool.name:
      result = ctx.getThreadTool.run(args: payload)
    case ctx.labelThreadTool.name:
      result = ctx.labelThreadTool.run(args: payload)
    default:
      result = "{\"error\":\"Unknown tool: \(id)\"}"
    }

    return makeCString(result)
  }

  api.version = 2

  api.handle_route = { ctxPtr, requestJsonPtr in
    guard let ctxPtr, let requestJsonPtr else { return nil }
    let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
    let requestJson = String(cString: requestJsonPtr)
    return makeCString(handleRoute(ctx: ctx, requestJSON: requestJson))
  }

  api.on_config_changed = { ctxPtr, keyPtr, valuePtr in
    guard let ctxPtr, let keyPtr else { return }
    let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
    let key = String(cString: keyPtr)
    let value = valuePtr.map { String(cString: $0) }
    onConfigChanged(ctx: ctx, key: key, value: value)
  }

  api.on_task_event = { ctxPtr, taskIdPtr, eventType, eventJsonPtr in
    guard let ctxPtr, let taskIdPtr, let eventJsonPtr else { return }
    let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
    let taskId = String(cString: taskIdPtr)
    let eventJson = String(cString: eventJsonPtr)
    handleTaskEvent(ctx: ctx, taskId: taskId, eventType: eventType, eventJSON: eventJson)
  }

  return api
}()

// MARK: - Entry Points

@_cdecl("osaurus_plugin_entry_v2")
public func osaurus_plugin_entry_v2(_ host: UnsafeRawPointer?) -> UnsafeRawPointer? {
  hostAPI = host?.assumingMemoryBound(to: osr_host_api.self)
  return UnsafeRawPointer(&api)
}

@_cdecl("osaurus_plugin_entry")
public func osaurus_plugin_entry() -> UnsafeRawPointer? {
  return UnsafeRawPointer(&api)
}
