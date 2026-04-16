import Foundation

enum DatabaseManager {

  // MARK: - Schema

  static func initSchema() {
    let statements = [
      """
      CREATE TABLE IF NOT EXISTS threads (
        thread_id       TEXT PRIMARY KEY,
        subject         TEXT,
        participants    TEXT DEFAULT '[]',
        last_message_id TEXT,
        refs            TEXT,
        task_id         TEXT,
        labels          TEXT DEFAULT '[]',
        created_at      INTEGER DEFAULT (unixepoch()),
        updated_at      INTEGER DEFAULT (unixepoch())
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS messages (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        thread_id       TEXT NOT NULL,
        email_id        TEXT,
        direction       TEXT NOT NULL,
        from_address    TEXT,
        to_address      TEXT DEFAULT '[]',
        cc_address      TEXT DEFAULT '[]',
        bcc_address     TEXT DEFAULT '[]',
        subject         TEXT,
        body_text       TEXT,
        body_html       TEXT,
        message_id      TEXT,
        in_reply_to     TEXT,
        has_attachments INTEGER DEFAULT 0,
        created_at      INTEGER DEFAULT (unixepoch()),
        FOREIGN KEY (thread_id) REFERENCES threads(thread_id)
      )
      """,
      "CREATE INDEX IF NOT EXISTS idx_messages_thread ON messages(thread_id, created_at DESC)",
      "CREATE INDEX IF NOT EXISTS idx_messages_message_id ON messages(message_id)",
      "CREATE INDEX IF NOT EXISTS idx_threads_updated ON threads(updated_at DESC)",
    ]
    for sql in statements {
      dbExec(sql, params: "[]")
    }
  }

  // MARK: - Threads

  static func createThread(
    threadId: String, subject: String?, participants: [String],
    messageId: String?, refs: String?
  ) {
    let participantsJSON = jsonArray(participants)
    let params = serializeParams([
      threadId, subject ?? NSNull(), participantsJSON, messageId ?? NSNull(),
      refs ?? NSNull(),
    ])
    let sql = """
      INSERT INTO threads (thread_id, subject, participants, last_message_id, refs)
      VALUES (?1, ?2, ?3, ?4, ?5)
      """
    dbExec(sql, params: params)
  }

  static func getThread(threadId: String) -> ThreadRow? {
    let sql =
      "SELECT thread_id, subject, participants, last_message_id, refs, task_id, labels, created_at, updated_at FROM threads WHERE thread_id = ?1"
    guard let resultStr = dbQuery(sql, params: serializeParams([threadId])),
      let rows = extractRows(resultStr),
      let row = rows.first
    else { return nil }
    return threadRowFromArray(row)
  }

  static func getThreadByMessageId(_ messageId: String) -> ThreadRow? {
    let sql = """
      SELECT t.thread_id, t.subject, t.participants, t.last_message_id, t.refs, t.task_id, t.labels, t.created_at, t.updated_at
      FROM threads t
      JOIN messages m ON m.thread_id = t.thread_id
      WHERE m.message_id = ?1
      ORDER BY t.updated_at DESC LIMIT 1
      """
    guard let resultStr = dbQuery(sql, params: serializeParams([messageId])),
      let rows = extractRows(resultStr),
      let row = rows.first
    else { return nil }
    return threadRowFromArray(row)
  }

  static func getThreadByTaskId(_ taskId: String) -> ThreadRow? {
    let sql =
      "SELECT thread_id, subject, participants, last_message_id, refs, task_id, labels, created_at, updated_at FROM threads WHERE task_id = ?1 LIMIT 1"
    guard let resultStr = dbQuery(sql, params: serializeParams([taskId])),
      let rows = extractRows(resultStr),
      let row = rows.first
    else { return nil }
    return threadRowFromArray(row)
  }

  static func updateThread(
    threadId: String,
    lastMessageId: String? = nil,
    refs: String? = nil,
    taskId: String? = nil,
    participants: [String]? = nil,
    labels: [String]? = nil
  ) {
    var setClauses: [String] = ["updated_at = unixepoch()"]
    var values: [Any] = []
    var paramIdx = 1

    if let lastMessageId {
      setClauses.append("last_message_id = ?\(paramIdx)")
      values.append(lastMessageId)
      paramIdx += 1
    }
    if let refs {
      setClauses.append("refs = ?\(paramIdx)")
      values.append(refs)
      paramIdx += 1
    }
    if let taskId {
      setClauses.append("task_id = ?\(paramIdx)")
      values.append(taskId)
      paramIdx += 1
    }
    if let participants {
      setClauses.append("participants = ?\(paramIdx)")
      values.append(jsonArray(participants))
      paramIdx += 1
    }
    if let labels {
      setClauses.append("labels = ?\(paramIdx)")
      values.append(jsonArray(labels))
      paramIdx += 1
    }

    values.append(threadId)
    let sql =
      "UPDATE threads SET \(setClauses.joined(separator: ", ")) WHERE thread_id = ?\(paramIdx)"
    dbExec(sql, params: serializeParams(values))
  }

  static func clearTaskId(threadId: String) {
    dbExec(
      "UPDATE threads SET task_id = NULL, updated_at = unixepoch() WHERE thread_id = ?1",
      params: serializeParams([threadId]))
  }

  static func listThreads(participant: String? = nil, label: String? = nil, limit: Int = 20)
    -> [ThreadRow]
  {
    var conditions: [String] = []
    var values: [Any] = []
    var paramIdx = 1

    if let participant {
      let cleaned = participant.lowercased()
      conditions.append("LOWER(participants) LIKE ?\(paramIdx)")
      values.append("%\(cleaned)%")
      paramIdx += 1
    }
    if let label {
      conditions.append("labels LIKE ?\(paramIdx)")
      values.append("%\"\(label)\"%")
      paramIdx += 1
    }

    var sql =
      "SELECT thread_id, subject, participants, last_message_id, refs, task_id, labels, created_at, updated_at FROM threads"
    if !conditions.isEmpty {
      sql += " WHERE " + conditions.joined(separator: " AND ")
    }
    sql += " ORDER BY updated_at DESC LIMIT ?\(paramIdx)"
    values.append(min(max(limit, 1), 100))

    guard let resultStr = dbQuery(sql, params: serializeParams(values)),
      let rows = extractRows(resultStr)
    else { return [] }
    return rows.compactMap(threadRowFromArray)
  }

  // MARK: - Messages

  static func insertMessage(
    threadId: String, emailId: String?, direction: String,
    fromAddress: String?, toAddress: [String], ccAddress: [String], bccAddress: [String],
    subject: String?, bodyText: String?, bodyHtml: String?,
    messageId: String?, inReplyTo: String?, hasAttachments: Bool
  ) {
    let params = serializeParams([
      threadId,
      emailId ?? NSNull(),
      direction,
      fromAddress ?? NSNull(),
      jsonArray(toAddress),
      jsonArray(ccAddress),
      jsonArray(bccAddress),
      subject ?? NSNull(),
      bodyText ?? NSNull(),
      bodyHtml ?? NSNull(),
      messageId ?? NSNull(),
      inReplyTo ?? NSNull(),
      hasAttachments ? 1 : 0,
    ])
    let sql = """
      INSERT INTO messages (thread_id, email_id, direction, from_address, to_address, cc_address, bcc_address, subject, body_text, body_html, message_id, in_reply_to, has_attachments)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
      """
    dbExec(sql, params: params)
  }

  static func getMessages(threadId: String, limit: Int = 20) -> [MessageRow] {
    let clampedLimit = min(max(limit, 1), 200)
    let sql = """
      SELECT id, thread_id, email_id, direction, from_address, to_address, cc_address, bcc_address,
             subject, body_text, body_html, message_id, in_reply_to, has_attachments, created_at
      FROM messages WHERE thread_id = ?1
      ORDER BY created_at DESC LIMIT ?2
      """
    guard let resultStr = dbQuery(sql, params: serializeParams([threadId, clampedLimit])),
      let rows = extractRows(resultStr)
    else { return [] }
    return rows.compactMap(messageRowFromArray)
  }

  static func getLastInboundMessage(threadId: String) -> MessageRow? {
    let sql = """
      SELECT id, thread_id, email_id, direction, from_address, to_address, cc_address, bcc_address,
             subject, body_text, body_html, message_id, in_reply_to, has_attachments, created_at
      FROM messages WHERE thread_id = ?1 AND direction = 'in'
      ORDER BY created_at DESC LIMIT 1
      """
    guard let resultStr = dbQuery(sql, params: serializeParams([threadId])),
      let rows = extractRows(resultStr),
      let row = rows.first
    else { return nil }
    return messageRowFromArray(row)
  }

  static func hasOutboundMessageSince(threadId: String, sinceTimestamp: Int) -> Bool {
    let sql = """
      SELECT COUNT(*) FROM messages
      WHERE thread_id = ?1 AND direction = 'out' AND created_at >= ?2
      """
    guard let resultStr = dbQuery(sql, params: serializeParams([threadId, sinceTimestamp])),
      let rows = extractRows(resultStr),
      let row = rows.first,
      let count = row.first as? Int
    else { return false }
    return count > 0
  }

  static func getLastMessagePreview(threadId: String) -> String? {
    let sql = "SELECT body_text FROM messages WHERE thread_id = ?1 ORDER BY created_at DESC LIMIT 1"
    guard let resultStr = dbQuery(sql, params: serializeParams([threadId])),
      let rows = extractRows(resultStr),
      let row = rows.first,
      let text = row.first as? String
    else { return nil }
    return String(text.prefix(200))
  }

  // MARK: - Authorization Queries

  static func hasSentTo(address: String) -> Bool {
    let cleaned = address.lowercased()
    let sql = """
      SELECT COUNT(*) FROM messages
      WHERE direction = 'out' AND LOWER(to_address) LIKE ?1
      """
    guard let resultStr = dbQuery(sql, params: serializeParams(["%\(cleaned)%"])),
      let rows = extractRows(resultStr),
      let row = rows.first,
      let count = row.first as? Int
    else { return false }
    return count > 0
  }

  static func isParticipantInAnyThread(address: String) -> Bool {
    let cleaned = address.lowercased()
    let sql = """
      SELECT COUNT(*) FROM threads
      WHERE LOWER(participants) LIKE ?1
      """
    guard let resultStr = dbQuery(sql, params: serializeParams(["%\(cleaned)%"])),
      let rows = extractRows(resultStr),
      let row = rows.first,
      let count = row.first as? Int
    else { return false }
    return count > 0
  }

  // MARK: - Parsing Helpers

  private static func threadRowFromArray(_ row: [Any]) -> ThreadRow? {
    guard row.count >= 9 else { return nil }
    return ThreadRow(
      threadId: "\(row[0])",
      subject: row[1] as? String,
      participants: parseJSONArray(row[2] as? String),
      lastMessageId: row[3] as? String,
      refs: row[4] as? String,
      taskId: row[5] as? String,
      labels: parseJSONArray(row[6] as? String),
      createdAt: row[7] as? Int,
      updatedAt: row[8] as? Int
    )
  }

  private static func messageRowFromArray(_ row: [Any]) -> MessageRow? {
    guard row.count >= 15 else { return nil }
    return MessageRow(
      id: row[0] as? Int,
      threadId: "\(row[1])",
      emailId: row[2] as? String,
      direction: "\(row[3])",
      fromAddress: row[4] as? String,
      toAddress: parseJSONArray(row[5] as? String),
      ccAddress: parseJSONArray(row[6] as? String),
      bccAddress: parseJSONArray(row[7] as? String),
      subject: row[8] as? String,
      bodyText: row[9] as? String,
      bodyHtml: row[10] as? String,
      messageId: row[11] as? String,
      inReplyTo: row[12] as? String,
      hasAttachments: (row[13] as? Int) == 1,
      createdAt: row[14] as? Int
    )
  }

  private static func parseJSONArray(_ str: String?) -> [String] {
    guard let str, let data = str.data(using: .utf8),
      let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
    else { return [] }
    return arr
  }

  private static func jsonArray(_ arr: [String]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: arr),
      let str = String(data: data, encoding: .utf8)
    else { return "[]" }
    return str
  }

  // MARK: - DB Execution

  static func dbExec(_ sql: String, params: String) {
    guard let exec = hostAPI?.pointee.db_exec else {
      logError("db_exec not available")
      return
    }
    let result = sql.withCString { sqlPtr in
      params.withCString { paramsPtr in
        exec(sqlPtr, paramsPtr)
      }
    }
    if let result {
      let str = String(cString: result)
      if str.contains("\"error\"") {
        logWarn("DB exec error: \(str)")
      }
    }
  }

  static func dbQuery(_ sql: String, params: String) -> String? {
    guard let query = hostAPI?.pointee.db_query else { return nil }
    return sql.withCString { sqlPtr in
      params.withCString { paramsPtr in
        guard let resultPtr = query(sqlPtr, paramsPtr) else { return nil }
        return String(cString: resultPtr)
      }
    }
  }

  static func extractRows(_ resultStr: String) -> [[Any]]? {
    guard let data = resultStr.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data)
    else { return nil }
    if let dict = json as? [String: Any], let rows = dict["rows"] as? [[Any]] {
      return rows
    }
    if let rows = json as? [[Any]] {
      return rows
    }
    return nil
  }
}
