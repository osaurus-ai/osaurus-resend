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

// v3+ slots
typealias osr_complete_cancel_fn = @convention(c) (UnsafePointer<CChar>?) -> Void
typealias osr_get_active_agent_id_fn = @convention(c) () -> UnsafePointer<CChar>?
typealias osr_log_structured_fn =
  @convention(c) (Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void
typealias osr_host_free_string_fn = @convention(c) (UnsafePointer<CChar>?) -> Void

/// Mirror of the host's `osr_host_api` C struct. Field order is FROZEN and
/// MUST match the host layout exactly — adding, removing, or reordering any
/// slot dispatches every later callback into the wrong host function. RESERVED
/// slots (e.g. `dispatch_add_issue` since v6) stay wired for the same reason.
/// See `docs/plugins/HOST_API.md` "Mirror Struct Audit" for the canonical layout.
struct osr_host_api {
  var version: UInt32 = 0

  // v1 / v2
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
  /// RESERVED on v6+: returns `{"error":"not_supported"}`. Use
  /// `dispatch_interrupt` to inject failure context into a running task.
  var dispatch_add_issue: osr_dispatch_add_issue_fn?

  // v3 — streaming control
  var complete_cancel: osr_complete_cancel_fn?
  // v4 — agent introspection
  var get_active_agent_id: osr_get_active_agent_id_fn?
  // v5 — structured logging
  var log_structured: osr_log_structured_fn?
  // v6 — host-side free for strings the host returned. ALWAYS use this (via
  // the `freeHostString` helper) for host-returned `const char*` instead of
  // the plugin's own `free_string`, which is the reverse direction.
  var free_string: osr_host_free_string_fn?
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
    return makeCString(resendManifestJSON)
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
      return makeCString(
        Envelope.failure(.invalidArgs, "Unknown capability type: \(type)", retryable: false))
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
      result = Envelope.failure(.notFound, "Unknown tool: \(id)")
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
