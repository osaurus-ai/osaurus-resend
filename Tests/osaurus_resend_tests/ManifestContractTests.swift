import Foundation
import Testing

@testable import osaurus_resend

@Suite("Plugin Manifest Contract", .serialized)
struct ManifestContractTests {

  private enum ManifestError: Error {
    case entryPointFailed
    case nilManifest
    case invalidJSON
  }

  private struct PluginAPI {
    let freeString: (@convention(c) (UnsafePointer<CChar>?) -> Void)
    let initContext: (@convention(c) () -> UnsafeMutableRawPointer?)
    let destroy: (@convention(c) (UnsafeMutableRawPointer?) -> Void)
    let getManifest: (@convention(c) (UnsafeMutableRawPointer?) -> UnsafePointer<CChar>?)
  }

  private func loadAPI() throws -> PluginAPI {
    guard let apiPtr = osaurus_plugin_entry() else {
      throw ManifestError.entryPointFailed
    }
    let fnPtrSize = MemoryLayout<UnsafeRawPointer?>.stride
    return PluginAPI(
      freeString: apiPtr.load(
        fromByteOffset: 0,
        as: (@convention(c) (UnsafePointer<CChar>?) -> Void).self),
      initContext: apiPtr.load(
        fromByteOffset: fnPtrSize,
        as: (@convention(c) () -> UnsafeMutableRawPointer?).self),
      destroy: apiPtr.load(
        fromByteOffset: fnPtrSize * 2,
        as: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self),
      getManifest: apiPtr.load(
        fromByteOffset: fnPtrSize * 3,
        as: (@convention(c) (UnsafeMutableRawPointer?) -> UnsafePointer<CChar>?).self)
    )
  }

  private func loadManifest() throws -> [String: Any] {
    MockHost.setUp()
    let api = try loadAPI()
    let ctx = api.initContext()
    defer { api.destroy(ctx) }

    guard let cStr = api.getManifest(ctx) else {
      throw ManifestError.nilManifest
    }
    let jsonString = String(cString: cStr)
    api.freeString(cStr)

    guard let data = jsonString.data(using: .utf8),
      let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw ManifestError.invalidJSON
    }
    return manifest
  }

  private func capabilities(from manifest: [String: Any]) -> [String: Any] {
    manifest["capabilities"] as? [String: Any] ?? [:]
  }

  private func toolMap(from manifest: [String: Any]) -> [String: [String: Any]] {
    let tools = capabilities(from: manifest)["tools"] as? [[String: Any]] ?? []
    return Dictionary(
      uniqueKeysWithValues: tools.compactMap { tool -> (String, [String: Any])? in
        guard let id = tool["id"] as? String else { return nil }
        return (id, tool)
      })
  }

  @Test("manifest has correct plugin identity and routes")
  func pluginIdentityAndRoutes() throws {
    let manifest = try loadManifest()
    #expect(manifest["plugin_id"] as? String == "osaurus.resend")
    #expect(manifest["version"] as? String == "0.1.0")

    let routes = capabilities(from: manifest)["routes"] as? [[String: Any]] ?? []
    let routeIDs = Set(routes.compactMap { $0["id"] as? String })
    #expect(routeIDs == ["webhook", "health", "reset_webhook"])

    let byID = Dictionary(uniqueKeysWithValues: routes.map { ($0["id"] as! String, $0) })
    #expect(byID["webhook"]?["auth"] as? String == "verify")
    #expect(byID["health"]?["auth"] as? String == "owner")
    #expect(byID["reset_webhook"]?["auth"] as? String == "owner")
  }

  @Test("manifest declares expected Resend tools")
  func toolIDs() throws {
    let map = try toolMap(from: loadManifest())
    #expect(
      Set(map.keys) == [
        "resend_send", "resend_reply", "resend_list_threads", "resend_get_thread",
        "resend_label_thread",
      ])
  }

  @Test("sensitive send, read, and mutation tools require approval")
  func permissionPolicies() throws {
    let map = try toolMap(from: loadManifest())
    for id in ["resend_send", "resend_reply", "resend_get_thread", "resend_label_thread"] {
      #expect(map[id]?["permission_policy"] as? String == "ask", "Tool '\(id)' should ask")
    }
    #expect(map["resend_list_threads"]?["permission_policy"] as? String == "auto")
  }

  @Test("send and reply tools declare required parameters")
  func requiredParameters() throws {
    let map = try toolMap(from: loadManifest())

    let sendParams = map["resend_send"]?["parameters"] as? [String: Any]
    let sendRequired = Set(sendParams?["required"] as? [String] ?? [])
    #expect(sendRequired == ["to", "subject", "body"])

    let replyParams = map["resend_reply"]?["parameters"] as? [String: Any]
    let replyRequired = Set(replyParams?["required"] as? [String] ?? [])
    #expect(replyRequired == ["thread_id", "body"])

    let getParams = map["resend_get_thread"]?["parameters"] as? [String: Any]
    let getRequired = Set(getParams?["required"] as? [String] ?? [])
    #expect(getRequired == ["thread_id"])
  }

  @Test("configuration exposes required Resend setup fields")
  func configFields() throws {
    let manifest = try loadManifest()
    let config = capabilities(from: manifest)["config"] as? [String: Any]
    let sections = config?["sections"] as? [[String: Any]] ?? []
    let fields = sections.flatMap { section -> [[String: Any]] in
      section["fields"] as? [[String: Any]] ?? []
    }
    let keys = Set(fields.compactMap { $0["key"] as? String })
    #expect(
      keys.isSuperset(of: [
        "api_key", "from_email", "from_name", "webhook_url", "webhook_status",
        "sender_policy", "allowed_senders",
      ]))
  }
}
