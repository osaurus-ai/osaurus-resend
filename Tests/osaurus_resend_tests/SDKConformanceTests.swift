import Foundation
import OsaurusPluginABI
import OsaurusPluginTestSupport
import Testing

@testable import osaurus_resend

extension AllResendTests {
  /// SDK-provided conformance checks (replaces hand-rolled equivalents):
  /// manifest registry rules, ABI table completeness through the plugin's
  /// REAL entry points, and the canonical failure envelope shape.
  @Suite("SDK Conformance")
  struct SDKConformanceTests {

    @Test("manifest passes SDK registry conformance")
    func manifestConformance() throws {
      try ManifestConformance.assertConformant(resendManifestJSON)
    }

    @Test("v2 entry point returns a conformant ABI table")
    func abiConformanceV2() throws {
      MockHost.setUp()
      let entry = withUnsafePointer(to: &mockHostAPIStorage) { ptr in
        osaurus_plugin_entry_v2(UnsafeRawPointer(ptr))
      }
      try ABIConformance.assertEntryConformance(entry, manifestJSON: resendManifestJSON)
      // The manifest declares webhook routes; the v2 table must expose
      // handle_route + the lifecycle callbacks this plugin relies on.
      let api = try #require(entry).assumingMemoryBound(to: OsrPluginAPI.self).pointee
      #expect(api.version == OsrABIVersion.v2)
      #expect(api.handle_route != nil)
      #expect(api.on_config_changed != nil)
      #expect(api.on_task_event != nil)
      // Entry must reinstall the bridge for the injected host.
      #expect(HostBridge.shared.isInstalled)
    }

    @Test("v1 entry point returns the same conformant table")
    func abiConformanceV1() throws {
      MockHost.setUp()
      try ABIConformance.assertEntryConformance(
        osaurus_plugin_entry(), manifestJSON: resendManifestJSON)
    }

    @Test("tool failures render the canonical failure envelope")
    func canonicalFailureShape() throws {
      // Unknown tool id through the real invoke path must produce the
      // SDK-canonical not_found failure.
      MockHost.setUp()
      let json = Envelope.failure(.notFound, "Unknown tool: nope")
      try assertCanonicalFailure(json, kind: .notFound)
    }
  }
}
