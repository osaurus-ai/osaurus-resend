import Foundation

/// Column list used by every `SELECT ... FROM threads` query in this file.
/// Kept in lock-step with `threadRowFromArray`'s positional decode (9 cols).
private let threadColumns =
  "thread_id, subject, participants, last_message_id, refs, task_id, labels, created_at, updated_at"

/// Column list used by every `SELECT ... FROM messages` query in this file.
/// Kept in lock-step with `messageRowFromArray`'s positional decode (15 cols).
private let messageColumns = """
  id, thread_id, email_id, direction, from_address, to_address, cc_address, bcc_address, \
  subject, body_text, body_html, message_id, in_reply_to, has_attachments, created_at
  """

/// `threadColumns` requalified with the `t.` alias for use inside JOINs.
private let qualifiedThreadColumns: String = threadColumns
  .split(separator: ",")
  .map { "t.\($0.trimmingCharacters(in: .whitespaces))" }
  .joined(separator: ", ")

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
      """
      CREATE TABLE IF NOT EXISTS suppressed_addresses (
        address    TEXT PRIMARY KEY,
        reason     TEXT,
        email_id   TEXT,
        created_at INTEGER DEFAULT (unixepoch())
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS email_events (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        email_id   TEXT NOT NULL,
        type       TEXT NOT NULL,
        detail     TEXT,
        created_at INTEGER DEFAULT (unixepoch())
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS processed_svix_ids (
        svix_id    TEXT PRIMARY KEY,
        status     TEXT NOT NULL DEFAULT 'completed',
        created_at INTEGER DEFAULT (unixepoch())
      )
      """,
      "CREATE INDEX IF NOT EXISTS idx_messages_thread ON messages(thread_id, created_at DESC)",
      "CREATE INDEX IF NOT EXISTS idx_messages_message_id ON messages(message_id)",
      "CREATE INDEX IF NOT EXISTS idx_messages_email_id ON messages(email_id)",
      "CREATE INDEX IF NOT EXISTS idx_threads_updated ON threads(updated_at DESC)",
      "CREATE INDEX IF NOT EXISTS idx_email_events_email ON email_events(email_id, created_at DESC)",
      // At most one in-flight task per thread (messaging-pattern invariant 2).
      // Partial index lets multiple threads with NULL task_id coexist; the
      // constraint only kicks in when a thread actually has an active task.
      "CREATE UNIQUE INDEX IF NOT EXISTS idx_threads_task_id ON threads(task_id) WHERE task_id IS NOT NULL",
    ]
    for sql in statements {
      dbExec(sql, params: "[]")
    }

    // Migration: pre-1.3.1 databases created processed_svix_ids without the
    // status column. Existing rows were fully processed, so 'completed' is
    // the correct backfill (it is also the column default).
    let hasStatusColumn =
      queryScalarInt(
        "SELECT COUNT(*) FROM pragma_table_info('processed_svix_ids') WHERE name = 'status'",
        values: []) > 0
    if !hasStatusColumn {
      dbExec(
        "ALTER TABLE processed_svix_ids ADD COLUMN status TEXT NOT NULL DEFAULT 'completed'",
        params: "[]")
    }

    // Migration (Wave 2): the claim row now also carries the raw webhook
    // payload, persisted atomically with the claim so "claimed" always
    // implies "durably enqueued" for the async drain worker.
    let hasPayloadColumn =
      queryScalarInt(
        "SELECT COUNT(*) FROM pragma_table_info('processed_svix_ids') WHERE name = 'payload'",
        values: []) > 0
    if !hasPayloadColumn {
      dbExec("ALTER TABLE processed_svix_ids ADD COLUMN payload TEXT", params: "[]")
    }

    // Best-effort GC of replay-protection rows older than 30 days.
    dbExec(
      "DELETE FROM processed_svix_ids WHERE created_at < (unixepoch() - 2592000)",
      params: "[]")
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
    queryFirstThread(
      "SELECT \(threadColumns) FROM threads WHERE thread_id = ?1",
      values: [threadId])
  }

  static func getThreadByMessageId(_ messageId: String) -> ThreadRow? {
    let sql = """
      SELECT \(qualifiedThreadColumns)
      FROM threads t
      JOIN messages m ON m.thread_id = t.thread_id
      WHERE m.message_id = ?1
      ORDER BY t.updated_at DESC LIMIT 1
      """
    return queryFirstThread(sql, values: [messageId])
  }

  static func getThreadByTaskId(_ taskId: String) -> ThreadRow? {
    queryFirstThread(
      "SELECT \(threadColumns) FROM threads WHERE task_id = ?1 LIMIT 1",
      values: [taskId])
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

    var sql = "SELECT \(threadColumns) FROM threads"
    if !conditions.isEmpty {
      sql += " WHERE " + conditions.joined(separator: " AND ")
    }
    sql += " ORDER BY updated_at DESC LIMIT ?\(paramIdx)"
    values.append(min(max(limit, 1), 100))

    return queryRows(sql, values: values).compactMap(threadRowFromArray)
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
    let sql = """
      SELECT \(messageColumns) FROM messages WHERE thread_id = ?1
      ORDER BY created_at DESC LIMIT ?2
      """
    let clampedLimit = min(max(limit, 1), 200)
    return queryRows(sql, values: [threadId, clampedLimit]).compactMap(messageRowFromArray)
  }

  static func getLastInboundMessage(threadId: String) -> MessageRow? {
    let sql = """
      SELECT \(messageColumns) FROM messages WHERE thread_id = ?1 AND direction = 'in'
      ORDER BY created_at DESC LIMIT 1
      """
    return queryFirstRow(sql, values: [threadId]).flatMap(messageRowFromArray)
  }

  static func hasOutboundMessageSince(threadId: String, sinceTimestamp: Int) -> Bool {
    let sql = """
      SELECT COUNT(*) FROM messages
      WHERE thread_id = ?1 AND direction = 'out' AND created_at >= ?2
      """
    return queryScalarInt(sql, values: [threadId, sinceTimestamp]) > 0
  }

  /// Removes messages recorded for a given provider email id. Used to roll
  /// back a partially processed inbound email so a webhook redelivery gets a
  /// clean re-process instead of being skipped by the email-id dedupe.
  static func deleteMessagesByEmailId(_ emailId: String, direction: String) {
    dbExec(
      "DELETE FROM messages WHERE email_id = ?1 AND direction = ?2",
      params: serializeParams([emailId, direction]))
  }

  static func getLastMessagePreview(threadId: String) -> String? {
    let sql = "SELECT body_text FROM messages WHERE thread_id = ?1 ORDER BY created_at DESC LIMIT 1"
    guard let row = queryFirstRow(sql, values: [threadId]),
      let text = row.first as? String
    else { return nil }
    return String(text.prefix(200))
  }

  // MARK: - Authorization Queries

  static func hasSentTo(address: String) -> Bool {
    let sql = """
      SELECT COUNT(*) FROM messages
      WHERE direction = 'out' AND LOWER(to_address) LIKE ?1
      """
    return queryScalarInt(sql, values: ["%\(address.lowercased())%"]) > 0
  }

  static func hasEmailId(_ emailId: String) -> Bool {
    queryScalarInt(
      "SELECT COUNT(*) FROM messages WHERE email_id = ?1",
      values: [emailId]) > 0
  }

  static func isParticipantInAnyThread(address: String) -> Bool {
    queryScalarInt(
      "SELECT COUNT(*) FROM threads WHERE LOWER(participants) LIKE ?1",
      values: ["%\(address.lowercased())%"]) > 0
  }

  // MARK: - Outbound Lookup

  /// Finds the thread that contains an outbound message with the given Resend `email_id`.
  /// Used by lifecycle handlers to associate bounce/failure events with a thread/task.
  static func getThreadByOutboundEmailId(_ emailId: String) -> ThreadRow? {
    let sql = """
      SELECT \(qualifiedThreadColumns)
      FROM threads t
      JOIN messages m ON m.thread_id = t.thread_id
      WHERE m.email_id = ?1 AND m.direction = 'out'
      ORDER BY t.updated_at DESC LIMIT 1
      """
    return queryFirstThread(sql, values: [emailId])
  }

  // MARK: - Suppression List

  /// Records (or refreshes) a suppression entry for an address. Idempotent on the
  /// address PRIMARY KEY: re-suppression updates `reason` / `email_id` /
  /// `created_at` so the most recent reason wins.
  static func suppressAddress(address: String, reason: String, emailId: String?) {
    let cleaned = address.lowercased()
    let sql = """
      INSERT INTO suppressed_addresses (address, reason, email_id, created_at)
      VALUES (?1, ?2, ?3, unixepoch())
      ON CONFLICT(address) DO UPDATE SET
        reason = excluded.reason,
        email_id = excluded.email_id,
        created_at = excluded.created_at
      """
    dbExec(sql, params: serializeParams([cleaned, reason, emailId ?? NSNull()]))
  }

  /// Returns the suppression reason if the address is suppressed, else `nil`.
  static func getSuppression(address: String) -> String? {
    let sql = "SELECT reason, created_at FROM suppressed_addresses WHERE address = ?1 LIMIT 1"
    guard let row = queryFirstRow(sql, values: [address.lowercased()]) else { return nil }
    let reason = row.first as? String ?? "suppressed"
    guard let ts = (row.count > 1) ? row[1] as? Int : nil else { return reason }
    let date = Date(timeIntervalSince1970: TimeInterval(ts))
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return "\(reason) (\(formatter.string(from: date)))"
  }

  // MARK: - Email Events Log

  static func recordEmailEvent(emailId: String, type: String, detail: String?) {
    let sql = """
      INSERT INTO email_events (email_id, type, detail, created_at)
      VALUES (?1, ?2, ?3, unixepoch())
      """
    dbExec(sql, params: serializeParams([emailId, type, detail ?? NSNull()]))
  }

  // MARK: - Svix Replay Protection

  enum SvixClaim: Equatable {
    /// This delivery is ours to process (fresh id, or takeover of a stale claim).
    case claimed
    /// A previous delivery of this id was fully processed; skip with 200.
    case alreadyCompleted
    /// Another in-flight claim holds the lease (or the claim awaits
    /// reconciliation). Since Wave 2 the payload is stored with the claim,
    /// so retries are acked 200 without enqueueing again.
    case inFlight
    /// The claim could not be durably recorded (host DB unavailable).
    /// Durable-first: the webhook must answer 5xx so the provider's retry
    /// remains the recovery path for the enqueue step itself.
    case storeUnavailable
  }

  /// A `processing` claim older than this is considered abandoned (crashed or
  /// hung worker) and may be taken over by a redelivery or reconciliation.
  static let svixClaimLeaseSeconds = 300

  /// Atomically claims a Svix delivery id for processing. The claim is a
  /// single INSERT with an affected-row check: fresh ids insert a `processing`
  /// row, stale `processing` rows (lease expired) are re-claimed, and anything
  /// else leaves the row untouched (0 rows affected).
  ///
  /// `payload` (Wave 2) is the raw signed webhook body, persisted in the SAME
  /// statement as the claim so "claimed" always implies "durably enqueued" —
  /// there is no window where a crash loses the event after the 200 went out.
  /// Pass nil to preserve whatever payload the row already carries (lease
  /// takeover keeps the original delivery's body).
  static func claimSvixId(_ svixId: String, payload: String? = nil) -> SvixClaim {
    let sql = """
      INSERT INTO processed_svix_ids (svix_id, status, created_at, payload)
      VALUES (?1, 'processing', unixepoch(), ?2)
      ON CONFLICT(svix_id) DO UPDATE SET
          created_at = unixepoch(),
          payload = COALESCE(?2, processed_svix_ids.payload)
        WHERE processed_svix_ids.status = 'processing'
          AND processed_svix_ids.created_at < (unixepoch() - \(svixClaimLeaseSeconds))
      """
    if dbExec(sql, params: serializeParams([svixId, payload ?? NSNull()])) > 0 {
      return .claimed
    }
    guard
      let row = queryFirstRow(
        "SELECT status FROM processed_svix_ids WHERE svix_id = ?1",
        values: [svixId]),
      let status = row.first as? String
    else {
      // INSERT affected nothing AND no row is readable — the write itself
      // failed (DB unavailable / error), not a claim conflict.
      return .storeUnavailable
    }
    return status == "completed" ? .alreadyCompleted : .inFlight
  }

  /// Marks a claimed delivery as fully processed. Only after this call do
  /// duplicate deliveries get skipped. Drops the stored payload — it is
  /// only needed while the claim is resumable.
  static func completeSvixId(_ svixId: String) {
    dbExec(
      "UPDATE processed_svix_ids SET status = 'completed', payload = NULL WHERE svix_id = ?1",
      params: serializeParams([svixId]))
  }

  // NOTE: Wave 1's `releaseSvixId` (DELETE on transient failure so the
  // provider's retry re-claims immediately) was removed in Wave 2: the 200
  // already went out at enqueue time, so deleting the row would orphan the
  // event if the provider never redelivers. Failed claims now stay
  // `processing` and are reprocessed from the stored payload once the lease
  // expires.

  /// One resumable inbox row: a `processing` claim whose lease expired and
  /// whose raw payload is still available for reprocessing.
  struct StaleClaimRow {
    let svixId: String
    let payload: String
  }

  /// `processing` claims older than the lease that still carry a payload —
  /// i.e. events a crashed/failed worker left behind. Ordered oldest first
  /// so reconciliation drains in arrival order. Rows without a payload
  /// (pre-Wave-2, or claims from deliveries lacking a svix-id) are skipped:
  /// there is nothing to reprocess, and they age out via the 30-day GC.
  static func staleIncompleteSvixClaims(limit: Int = 16) -> [StaleClaimRow] {
    let sql = """
      SELECT svix_id, payload FROM processed_svix_ids
      WHERE status = 'processing' AND payload IS NOT NULL
        AND created_at < (unixepoch() - \(svixClaimLeaseSeconds))
      ORDER BY created_at ASC
      LIMIT ?1
      """
    return queryRows(sql, values: [limit]).compactMap { row in
      guard row.count >= 2, let svixId = row[0] as? String,
        let payload = row[1] as? String
      else { return nil }
      return StaleClaimRow(svixId: svixId, payload: payload)
    }
  }

  /// Whether a claim row still carries its durable payload. Used by the
  /// webhook handler to distinguish a wave-2 in-flight claim (payload
  /// stored, safe to ack 200) from a payload-less one (pre-Wave-2 row or
  /// synthetic claim), where only the provider's retry can recover.
  static func svixClaimHasPayload(_ svixId: String) -> Bool {
    queryScalarInt(
      "SELECT COUNT(*) FROM processed_svix_ids WHERE svix_id = ?1 AND payload IS NOT NULL",
      values: [svixId]) > 0
  }

  /// Queue depth for `/health`: claims not yet completed (in-lease =
  /// queued/processing, lease-expired = awaiting reconciliation).
  static func pendingSvixClaimCount() -> Int {
    queryScalarInt(
      "SELECT COUNT(*) FROM processed_svix_ids WHERE status = 'processing'",
      values: [])
  }

  /// Age (seconds) of the oldest not-yet-completed claim, or nil when the
  /// queue is empty. Surfaced by `/health` so a wedged worker shows up as a
  /// growing age even while the depth stays flat.
  static func oldestPendingSvixClaimAge() -> Int? {
    guard
      let row = queryFirstRow(
        """
        SELECT unixepoch() - MIN(created_at) FROM processed_svix_ids
        WHERE status = 'processing'
        """,
        values: []),
      let age = row.first as? Int
    else { return nil }
    return age
  }

  // MARK: - Query Helpers

  /// Runs a query and returns all rows as positional arrays. Empty array on
  /// any failure (transport, parse, no rows).
  private static func queryRows(_ sql: String, values: [Any]) -> [[Any]] {
    guard let resultStr = dbQuery(sql, params: serializeParams(values)),
      let rows = extractRows(resultStr)
    else { return [] }
    return rows
  }

  /// Runs a query and returns the first row, or nil if the query returned no
  /// rows (or failed).
  private static func queryFirstRow(_ sql: String, values: [Any]) -> [Any]? {
    queryRows(sql, values: values).first
  }

  /// Runs a query whose first row's first column is an `Int` (e.g. `COUNT(*)`)
  /// and returns that integer. Returns 0 for any failure mode.
  private static func queryScalarInt(_ sql: String, values: [Any]) -> Int {
    queryFirstRow(sql, values: values).flatMap { $0.first as? Int } ?? 0
  }

  /// Runs a query whose row shape matches `threadColumns` and decodes the
  /// first row into a `ThreadRow`.
  private static func queryFirstThread(_ sql: String, values: [Any]) -> ThreadRow? {
    queryFirstRow(sql, values: values).flatMap(threadRowFromArray)
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

  /// Executes a statement and returns the number of affected rows (the host
  /// replies `{"changes":N,"last_insert_rowid":N}`). Returns 0 on any failure.
  @discardableResult
  static func dbExec(_ sql: String, params: String) -> Int {
    guard let exec = hostAPI?.pointee.db_exec else {
      logError("db_exec not available")
      return 0
    }
    guard let result = callHostString(sql, params, via: exec) else { return 0 }
    if result.contains("\"error\"") {
      logWarn("DB exec error: \(result)")
      return 0
    }
    guard let data = result.data(using: .utf8),
      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return 0 }
    return dict["changes"] as? Int ?? 0
  }

  static func dbQuery(_ sql: String, params: String) -> String? {
    guard let query = hostAPI?.pointee.db_query else { return nil }
    return callHostString(sql, params, via: query)
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
