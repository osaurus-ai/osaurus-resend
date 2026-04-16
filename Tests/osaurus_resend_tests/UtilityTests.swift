import Foundation
import Testing

@testable import osaurus_resend

@Suite("Utilities", .serialized)
struct UtilityTests {

  @Test("makeJSONString serializes dictionary")
  func makeJSONStringBasic() {
    let result = makeJSONString(["key": "value", "num": 42])
    #expect(result != nil)
    #expect(result!.contains("\"key\""))
    #expect(result!.contains("\"value\""))
    #expect(result!.contains("42"))
  }

  @Test("makeJSONString handles nested objects")
  func makeJSONStringNested() {
    let result = makeJSONString(["outer": ["inner": "val"]])
    #expect(result != nil)
    #expect(result!.contains("inner"))
  }

  @Test("parseJSON decodes valid JSON")
  func parseJSONValid() {
    struct Simple: Decodable {
      let name: String
      let age: Int
    }
    let json = "{\"name\":\"Alice\",\"age\":30}"
    let result = parseJSON(json, as: Simple.self)
    #expect(result?.name == "Alice")
    #expect(result?.age == 30)
  }

  @Test("parseJSON returns nil for invalid JSON")
  func parseJSONInvalid() {
    struct Simple: Decodable { let name: String }
    let result = parseJSON("not json", as: Simple.self)
    #expect(result == nil)
  }

  @Test("parseJSON returns nil for missing required fields")
  func parseJSONMissingField() {
    struct Simple: Decodable {
      let name: String
      let required_field: Int
    }
    let result = parseJSON("{\"name\":\"Alice\"}", as: Simple.self)
    #expect(result == nil)
  }

  @Test("serializeParams produces JSON array")
  func serializeParamsBasic() {
    let result = serializeParams(["hello", 42, true])
    #expect(result.contains("\"hello\""))
    #expect(result.contains("42"))
    #expect(result.contains("true"))
  }

  @Test("serializeParams handles empty array")
  func serializeParamsEmpty() {
    let result = serializeParams([])
    #expect(result == "[]")
  }

  @Test("escapeJSON escapes special characters")
  func escapeJSONSpecialChars() {
    let result = escapeJSON("hello \"world\"")
    #expect(result.contains("\\\""))
  }

  @Test("escapeJSON handles plain strings")
  func escapeJSONPlain() {
    let result = escapeJSON("hello")
    #expect(result == "hello")
  }

  @Test("extractEmailAddress from angle brackets")
  func extractEmailAngleBrackets() {
    let result = extractEmailAddress("Alice <alice@example.com>")
    #expect(result == "alice@example.com")
  }

  @Test("extractEmailAddress from plain address")
  func extractEmailPlain() {
    let result = extractEmailAddress("alice@example.com")
    #expect(result == "alice@example.com")
  }

  @Test("extractEmailAddress trims whitespace")
  func extractEmailWhitespace() {
    let result = extractEmailAddress("  alice@example.com  ")
    #expect(result == "alice@example.com")
  }

  @Test("extractEmailAddress with display name and brackets")
  func extractEmailDisplayName() {
    let result = extractEmailAddress("\"Alice Smith\" <alice@example.com>")
    #expect(result == "alice@example.com")
  }

  @Test("randomHexString has correct length")
  func randomHexLength() {
    let result = randomHexString(bytes: 16)
    #expect(result.count == 32)
  }

  @Test("randomHexString contains only hex chars")
  func randomHexChars() {
    let result = randomHexString(bytes: 8)
    let hexChars = CharacterSet(charactersIn: "0123456789abcdef")
    for char in result.unicodeScalars {
      #expect(hexChars.contains(char))
    }
  }

  @Test("randomHexString produces different values")
  func randomHexUnique() {
    let a = randomHexString(bytes: 16)
    let b = randomHexString(bytes: 16)
    #expect(a != b)
  }
}
