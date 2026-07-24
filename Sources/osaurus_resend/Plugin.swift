import Foundation
import OsaurusPluginABI
import OsaurusPluginKit

// MARK: - C ABI Surface
//
// The `osr_host_api` / `osr_plugin_api` mirrors that used to live here are
// now provided by the pinned `osaurus-plugin-sdk` (`OsrHostAPI` /
// `OsrPluginAPI` in `OsaurusPluginABI`). The SDK pins the frozen v6 layout
// (offsets 0 / 176 / 184 / 192, stride 200) with its own layout tests, so
// mirror drift fails the SDK's CI instead of crashing hosts.

// MARK: - Task Lifecycle Event Types

let OSR_TASK_EVENT_STARTED: Int32 = OsrTaskEvent.started
let OSR_TASK_EVENT_ACTIVITY: Int32 = OsrTaskEvent.activity
let OSR_TASK_EVENT_PROGRESS: Int32 = OsrTaskEvent.progress
let OSR_TASK_EVENT_CLARIFICATION: Int32 = OsrTaskEvent.clarification
let OSR_TASK_EVENT_COMPLETED: Int32 = OsrTaskEvent.completed
let OSR_TASK_EVENT_FAILED: Int32 = OsrTaskEvent.failed
let OSR_TASK_EVENT_CANCELLED: Int32 = OsrTaskEvent.cancelled
let OSR_TASK_EVENT_OUTPUT: Int32 = OsrTaskEvent.output
let OSR_TASK_EVENT_DRAFT: Int32 = OsrTaskEvent.draft

// MARK: - Global State
//
// `HostBridge.shared` (installed by `PluginEntry.enterV2`) covers config,
// logging, agent-id resolution, and host-string freeing. The raw pointer
// below is kept for the slots the bridge does not expose (db_exec /
// db_query / dispatch / dispatch_interrupt / http_request / file_read).

nonisolated(unsafe) var hostAPI: UnsafePointer<OsrHostAPI>?

// MARK: - Plugin API

private nonisolated(unsafe) var api: OsrPluginAPI = PluginEntry.makeAPI(
  version: OsrABIVersion.v2,
  init: {
    let ctx = PluginContext()
    initPlugin(ctx)
    logInfo("Plugin init complete")
    return Unmanaged.passRetained(ctx).toOpaque()
  },
  destroy: { ctxPtr in
    guard let ctxPtr else { return }
    let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
    destroyPlugin(ctx)
    Unmanaged<PluginContext>.fromOpaque(ctxPtr).release()
  },
  getManifest: { _ in
    osrMakeCString(resendManifestJSON)
  },
  invoke: { ctxPtr, typePtr, idPtr, payloadPtr in
    guard let ctxPtr, let typePtr, let idPtr, let payloadPtr else { return nil }

    let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
    let type = String(cString: typePtr)
    let id = String(cString: idPtr)
    let payload = String(cString: payloadPtr)

    logDebug("invoke: type=\(type) id=\(id)")

    if type == "artifact" && id == "share" {
      return osrMakeCString(handleArtifactShare(ctx: ctx, payload: payload))
    }

    guard type == "tool" else {
      return osrMakeCString(
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

    return osrMakeCString(result)
  },
  handleRoute: { ctxPtr, requestJsonPtr in
    guard let ctxPtr, let requestJsonPtr else { return nil }
    let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
    let requestJson = String(cString: requestJsonPtr)
    return osrMakeCString(handleRoute(ctx: ctx, requestJSON: requestJson))
  },
  onConfigChanged: { ctxPtr, keyPtr, valuePtr in
    guard let ctxPtr, let keyPtr else { return }
    let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
    let key = String(cString: keyPtr)
    let value = valuePtr.map { String(cString: $0) }
    onConfigChanged(ctx: ctx, key: key, value: value)
  },
  onTaskEvent: { ctxPtr, taskIdPtr, eventType, eventJsonPtr in
    guard let ctxPtr, let taskIdPtr, let eventJsonPtr else { return }
    let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
    let taskId = String(cString: taskIdPtr)
    let eventJson = String(cString: eventJsonPtr)
    handleTaskEvent(ctx: ctx, taskId: taskId, eventType: eventType, eventJSON: eventJson)
  }
)

// MARK: - Entry Points

@_cdecl("osaurus_plugin_entry_v2")
public func osaurus_plugin_entry_v2(_ host: UnsafeRawPointer?) -> UnsafeRawPointer? {
  hostAPI = host?.assumingMemoryBound(to: OsrHostAPI.self)
  return PluginEntry.enterV2(host, api: &api)
}

@_cdecl("osaurus_plugin_entry")
public func osaurus_plugin_entry() -> UnsafeRawPointer? {
  return PluginEntry.enterV1(api: &api)
}
