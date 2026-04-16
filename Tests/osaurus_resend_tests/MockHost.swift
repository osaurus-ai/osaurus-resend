import Foundation

@testable import osaurus_resend

// MARK: - Mock Host State

nonisolated(unsafe) var mockConfig: [String: String] = [:]
nonisolated(unsafe) var mockThreads: [[String: Any]] = []
nonisolated(unsafe) var mockMessages: [[String: Any]] = []
nonisolated(unsafe) var mockNextMessageId: Int = 1
nonisolated(unsafe) var mockHTTPResponses: [String] = []
nonisolated(unsafe) var mockDispatchCalls: [String] = []
nonisolated(unsafe) var mockDispatchResult: String = "{\"id\":\"task-001\",\"status\":\"running\"}"
nonisolated(unsafe) var mockFileContents: [String: String] = [:]
nonisolated(unsafe) var mockLogMessages: [(Int32, String)] = []
nonisolated(unsafe) var mockHostAPIStorage = osr_host_api()

// MARK: - MockHost Setup

enum MockHost {
  static func setUp() {
    mockConfig = [:]
    mockThreads = []
    mockMessages = []
    mockNextMessageId = 1
    mockHTTPResponses = []
    mockDispatchCalls = []
    mockDispatchResult = "{\"id\":\"task-001\",\"status\":\"running\"}"
    mockFileContents = [:]
    mockLogMessages = []

    mockHostAPIStorage = osr_host_api()
    mockHostAPIStorage.version = 2
    mockHostAPIStorage.config_get = mockConfigGet
    mockHostAPIStorage.config_set = mockConfigSet
    mockHostAPIStorage.config_delete = mockConfigDelete
    mockHostAPIStorage.db_exec = mockDbExec
    mockHostAPIStorage.db_query = mockDbQuery
    mockHostAPIStorage.log = mockLog
    mockHostAPIStorage.http_request = mockHttpRequest
    mockHostAPIStorage.dispatch = mockDispatch
    mockHostAPIStorage.file_read = mockFileRead

    withUnsafePointer(to: &mockHostAPIStorage) { ptr in
      hostAPI = ptr
    }
  }

  static func pushHTTPResponse(status: Int, body: [String: Any]) {
    let bodyStr: String
    if let data = try? JSONSerialization.data(withJSONObject: body),
      let str = String(data: data, encoding: .utf8)
    {
      bodyStr = str
    } else {
      bodyStr = "{}"
    }
    let resp: [String: Any] = [
      "status": status,
      "headers": ["Content-Type": "application/json"],
      "body": bodyStr,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: resp),
      let str = String(data: data, encoding: .utf8)
    {
      mockHTTPResponses.append(str)
    }
  }

  static func pushSendEmailResponse(emailId: String) {
    pushHTTPResponse(status: 200, body: ["id": emailId])
  }

  static func pushReceivedEmailResponse(
    emailId: String, from: String, to: [String], subject: String,
    text: String?, html: String?, messageId: String?,
    cc: [String]? = nil, headers: [String: String]? = nil
  ) {
    var body: [String: Any] = [
      "id": emailId,
      "from": from,
      "to": to,
      "subject": subject,
    ]
    if let text { body["text"] = text }
    if let html { body["html"] = html }
    if let messageId { body["message_id"] = messageId }
    if let cc { body["cc"] = cc }
    if let headers { body["headers"] = headers }
    pushHTTPResponse(status: 200, body: body)
  }
}

// MARK: - C Callbacks

private let mockConfigGet: osr_config_get_fn = { keyPtr in
  guard let keyPtr else { return nil }
  let key = String(cString: keyPtr)
  guard let value = mockConfig[key] else { return nil }
  return mockStr(value)
}

private let mockConfigSet: osr_config_set_fn = { keyPtr, valuePtr in
  guard let keyPtr else { return }
  let key = String(cString: keyPtr)
  if let valuePtr {
    mockConfig[key] = String(cString: valuePtr)
  }
}

private let mockConfigDelete: osr_config_delete_fn = { keyPtr in
  guard let keyPtr else { return }
  let key = String(cString: keyPtr)
  mockConfig.removeValue(forKey: key)
}

private let mockLog: osr_log_fn = { level, msgPtr in
  guard let msgPtr else { return }
  let msg = String(cString: msgPtr)
  mockLogMessages.append((level, msg))
}

private let mockHttpRequest: osr_http_request_fn = { requestPtr in
  guard !mockHTTPResponses.isEmpty else {
    return mockStr("{\"status\":500,\"body\":\"{}\"}")
  }
  let resp = mockHTTPResponses.removeFirst()
  return mockStr(resp)
}

private let mockDispatch: osr_dispatch_fn = { requestPtr in
  if let requestPtr {
    let req = String(cString: requestPtr)
    mockDispatchCalls.append(req)
  }
  return mockStr(mockDispatchResult)
}

private let mockFileRead: osr_file_read_fn = { pathPtr in
  guard let pathPtr else { return nil }
  let path = String(cString: pathPtr)
  guard let content = mockFileContents[path] else {
    let err = "{\"error\":\"File not found: \(path)\"}"
    return mockStr(err)
  }
  return mockStr(content)
}

// MARK: - Mock DB

private let mockDbExec: osr_db_exec_fn = { sqlPtr, paramsPtr in
  guard let sqlPtr else { return nil }
  let sql = String(cString: sqlPtr).trimmingCharacters(in: .whitespacesAndNewlines)
  let params = paramsPtr.map { String(cString: $0) } ?? "[]"
  let paramValues = parseParamArray(params)

  if sql.hasPrefix("CREATE TABLE") || sql.hasPrefix("CREATE INDEX") {
    return mockStr("{\"ok\":true}")
  }

  if sql.hasPrefix("INSERT INTO threads") {
    guard paramValues.count >= 5 else { return mockStr("{\"ok\":true}") }
    let thread: [String: Any] = [
      "thread_id": paramValues[0],
      "subject": paramValues[1],
      "participants": paramValues[2],
      "last_message_id": paramValues[3],
      "refs": paramValues[4],
      "task_id": NSNull(),
      "labels": "[]",
      "created_at": Int(Date().timeIntervalSince1970),
      "updated_at": Int(Date().timeIntervalSince1970),
    ]
    mockThreads.append(thread)
    return mockStr("{\"ok\":true}")
  }

  if sql.hasPrefix("INSERT INTO messages") {
    guard paramValues.count >= 13 else { return mockStr("{\"ok\":true}") }
    let msg: [String: Any] = [
      "id": mockNextMessageId,
      "thread_id": paramValues[0],
      "email_id": paramValues[1],
      "direction": paramValues[2],
      "from_address": paramValues[3],
      "to_address": paramValues[4],
      "cc_address": paramValues[5],
      "bcc_address": paramValues[6],
      "subject": paramValues[7],
      "body_text": paramValues[8],
      "body_html": paramValues[9],
      "message_id": paramValues[10],
      "in_reply_to": paramValues[11],
      "has_attachments": paramValues[12],
      "created_at": Int(Date().timeIntervalSince1970),
    ]
    mockNextMessageId += 1
    mockMessages.append(msg)
    return mockStr("{\"ok\":true}")
  }

  if sql.hasPrefix("UPDATE threads SET") {
    let threadIdParam = paramValues.last
    guard let tid = threadIdParam as? String else { return mockStr("{\"ok\":true}") }
    if let idx = mockThreads.firstIndex(where: { ($0["thread_id"] as? String) == tid }) {
      if sql.contains("task_id = NULL") {
        mockThreads[idx]["task_id"] = NSNull()
      }
      for (i, val) in paramValues.dropLast().enumerated() {
        let paramNum = i + 1
        if sql.contains("last_message_id = ?\(paramNum)") {
          mockThreads[idx]["last_message_id"] = val
        }
        if sql.contains("refs = ?\(paramNum)") {
          mockThreads[idx]["refs"] = val
        }
        if sql.contains("task_id = ?\(paramNum)") {
          mockThreads[idx]["task_id"] = val
        }
        if sql.contains("participants = ?\(paramNum)") {
          mockThreads[idx]["participants"] = val
        }
        if sql.contains("labels = ?\(paramNum)") {
          mockThreads[idx]["labels"] = val
        }
      }
      mockThreads[idx]["updated_at"] = Int(Date().timeIntervalSince1970)
    }
    return mockStr("{\"ok\":true}")
  }

  return mockStr("{\"ok\":true}")
}

private let mockDbQuery: osr_db_query_fn = { sqlPtr, paramsPtr in
  guard let sqlPtr else { return nil }
  let sql = String(cString: sqlPtr).trimmingCharacters(in: .whitespacesAndNewlines)
  let params = paramsPtr.map { String(cString: $0) } ?? "[]"
  let paramValues = parseParamArray(params)

  if sql.contains("FROM threads") && sql.contains("WHERE thread_id = ?1")
    || sql.contains("WHERE thread_id = ?1 LIMIT 1")
  {
    guard let tid = paramValues.first as? String else { return returnRows([]) }
    let matching = mockThreads.filter { ($0["thread_id"] as? String) == tid }
    return returnThreadRows(matching)
  }

  if sql.contains("FROM threads") && sql.contains("WHERE task_id = ?1") {
    guard let tid = paramValues.first as? String else { return returnRows([]) }
    let matching = mockThreads.filter { ($0["task_id"] as? String) == tid }
    return returnThreadRows(matching)
  }

  if sql.contains("JOIN messages m ON m.thread_id = t.thread_id")
    && sql.contains("WHERE m.message_id = ?1")
  {
    guard let mid = paramValues.first as? String else { return returnRows([]) }
    let matchingMsgs = mockMessages.filter { ($0["message_id"] as? String) == mid }
    if let firstMsg = matchingMsgs.first, let threadId = firstMsg["thread_id"] as? String {
      let matching = mockThreads.filter { ($0["thread_id"] as? String) == threadId }
      return returnThreadRows(matching)
    }
    return returnRows([])
  }

  if sql.contains("FROM threads") && sql.contains("ORDER BY updated_at DESC LIMIT") {
    var filtered = mockThreads
    if let pIdx = paramValues.firstIndex(where: { _ in sql.contains("LOWER(participants) LIKE") }),
      let pVal = paramValues[safe: 0] as? String, sql.contains("LOWER(participants) LIKE ?1")
    {
      let search = pVal.replacingOccurrences(of: "%", with: "").lowercased()
      filtered = filtered.filter {
        ($0["participants"] as? String ?? "").lowercased().contains(search)
      }
    }
    if sql.contains("labels LIKE") {
      let labelIdx =
        sql.contains("LIKE ?1") && !sql.contains("LOWER(participants)")
        ? 0 : sql.contains("LIKE ?2") ? 1 : -1
      if labelIdx >= 0, let lVal = paramValues[safe: labelIdx] as? String {
        let search = lVal.replacingOccurrences(of: "%", with: "")
        filtered = filtered.filter {
          ($0["labels"] as? String ?? "").contains(search)
        }
      }
    }
    return returnThreadRows(filtered)
  }

  if sql.contains("FROM messages WHERE thread_id = ?1") && sql.contains("direction = 'in'") {
    guard let tid = paramValues.first as? String else { return returnRows([]) }
    let matching = mockMessages.filter {
      ($0["thread_id"] as? String) == tid && ($0["direction"] as? String) == "in"
    }.sorted { (a, b) in
      (a["created_at"] as? Int ?? 0) > (b["created_at"] as? Int ?? 0)
    }
    return returnMessageRows(Array(matching.prefix(1)))
  }

  if sql.contains("FROM messages WHERE thread_id = ?1") && sql.contains("ORDER BY created_at DESC")
  {
    guard let tid = paramValues.first as? String else { return returnRows([]) }
    let matching = mockMessages.filter { ($0["thread_id"] as? String) == tid }
      .sorted { (a, b) in (a["created_at"] as? Int ?? 0) > (b["created_at"] as? Int ?? 0) }
    let limit = (paramValues.count > 1) ? (paramValues[1] as? Int ?? 20) : 20
    return returnMessageRows(Array(matching.prefix(limit)))
  }

  if sql.contains("SELECT body_text FROM messages") {
    guard let tid = paramValues.first as? String else { return returnRows([]) }
    let matching = mockMessages.filter { ($0["thread_id"] as? String) == tid }
      .sorted { (a, b) in (a["created_at"] as? Int ?? 0) > (b["created_at"] as? Int ?? 0) }
    if let first = matching.first {
      let text = first["body_text"]
      return returnRows([[text is NSNull ? NSNull() : text as Any]])
    }
    return returnRows([])
  }

  if sql.contains("SELECT COUNT(*)") && sql.contains("direction = 'out'")
    && sql.contains("LOWER(to_address) LIKE")
  {
    guard let search = paramValues.first as? String else { return returnRows([[0]]) }
    let cleaned = search.replacingOccurrences(of: "%", with: "").lowercased()
    let count = mockMessages.filter {
      ($0["direction"] as? String) == "out"
        && ($0["to_address"] as? String ?? "").lowercased().contains(cleaned)
    }.count
    return returnRows([[count]])
  }

  if sql.contains("SELECT COUNT(*)") && sql.contains("FROM threads")
    && sql.contains("LOWER(participants) LIKE")
  {
    guard let search = paramValues.first as? String else { return returnRows([[0]]) }
    let cleaned = search.replacingOccurrences(of: "%", with: "").lowercased()
    let count = mockThreads.filter {
      ($0["participants"] as? String ?? "").lowercased().contains(cleaned)
    }.count
    return returnRows([[count]])
  }

  if sql.contains("SELECT COUNT(*)") && sql.contains("direction = 'out'")
    && sql.contains("created_at >= ?2")
  {
    guard let tid = paramValues.first as? String,
      let since = paramValues[safe: 1] as? Int
    else { return returnRows([[0]]) }
    let count = mockMessages.filter {
      ($0["thread_id"] as? String) == tid && ($0["direction"] as? String) == "out"
        && ($0["created_at"] as? Int ?? 0) >= since
    }.count
    return returnRows([[count]])
  }

  return returnRows([])
}

// MARK: - DB Response Helpers

private func returnRows(_ rows: [[Any]]) -> UnsafePointer<CChar>? {
  let result: [String: Any] = ["rows": rows]
  guard let data = try? JSONSerialization.data(withJSONObject: result),
    let str = String(data: data, encoding: .utf8)
  else {
    return mockStr("{\"rows\":[]}")
  }
  return mockStr(str)
}

private func returnThreadRows(_ threads: [[String: Any]]) -> UnsafePointer<CChar>? {
  let rows: [[Any]] = threads.map { t in
    [
      t["thread_id"] ?? NSNull(),
      t["subject"] ?? NSNull(),
      t["participants"] ?? "[]",
      t["last_message_id"] ?? NSNull(),
      t["refs"] ?? NSNull(),
      t["task_id"] ?? NSNull(),
      t["labels"] ?? "[]",
      t["created_at"] ?? NSNull(),
      t["updated_at"] ?? NSNull(),
    ]
  }
  return returnRows(rows)
}

private func returnMessageRows(_ messages: [[String: Any]]) -> UnsafePointer<CChar>? {
  let rows: [[Any]] = messages.map { m in
    [
      m["id"] ?? NSNull(),
      m["thread_id"] ?? NSNull(),
      m["email_id"] ?? NSNull(),
      m["direction"] ?? NSNull(),
      m["from_address"] ?? NSNull(),
      m["to_address"] ?? "[]",
      m["cc_address"] ?? "[]",
      m["bcc_address"] ?? "[]",
      m["subject"] ?? NSNull(),
      m["body_text"] ?? NSNull(),
      m["body_html"] ?? NSNull(),
      m["message_id"] ?? NSNull(),
      m["in_reply_to"] ?? NSNull(),
      m["has_attachments"] ?? 0,
      m["created_at"] ?? NSNull(),
    ]
  }
  return returnRows(rows)
}

private func parseParamArray(_ json: String) -> [Any] {
  guard let data = json.data(using: .utf8),
    let arr = try? JSONSerialization.jsonObject(with: data) as? [Any]
  else { return [] }
  return arr
}

extension Array {
  fileprivate subscript(safe index: Int) -> Element? {
    index >= 0 && index < count ? self[index] : nil
  }
}

private func mockStr(_ s: String) -> UnsafePointer<CChar>? {
  guard let ptr = strdup(s) else { return nil }
  return UnsafePointer(ptr)
}
