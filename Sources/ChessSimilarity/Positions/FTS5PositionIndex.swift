//
//  FTS5PositionIndex.swift
//  ChessSimilarity
//

#if canImport(SQLite3)
import Foundation
import SQLite3

/// Errors from SQLite.
public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public var code: Int32
    public var message: String
    public var description: String { "SQLite \(code): \(message)" }
}

/// The SQL that an app needs to keep similar positions in its own SQLite database.
///
/// The table is contentless (`content=''`): the term text is not stored, only the index.
/// It keeps the default `detail=full`. With `detail=column` a contentless table
/// cannot locate the hits of a row and `bm25()` returns 0 for every row (checked with
/// SQLite 3.54). Every term is ASCII letters and digits, so the `ascii` tokenizer keeps
/// it whole.
public enum PositionFTS5Schema {
    public static func createTable(_ table: String = "similar_positions") -> String {
        let columns = TermColumn.allCases.map(\.name).joined(separator: ", ")
        return "CREATE VIRTUAL TABLE IF NOT EXISTS \(table) USING fts5(\(columns), content='', tokenize='ascii')"
    }

    /// The vocabulary table used to read document frequencies.
    public static func createVocabulary(_ table: String = "similar_positions") -> String {
        "CREATE VIRTUAL TABLE IF NOT EXISTS \(table)_vocab USING fts5vocab(\(table), 'row')"
    }

    /// Insert with `rowid` = ``PositionDocumentID/make(gameID:ply:)`` and one text per column
    /// (``PositionTerms/columnTexts``).
    public static func insert(_ table: String = "similar_positions") -> String {
        let columns = TermColumn.allCases.map(\.name)
        return "INSERT INTO \(table)(rowid, \(columns.joined(separator: ", "))) VALUES (?\(String(repeating: ", ?", count: columns.count)))"
    }

    /// Ranking query: bind the ``matchExpression(_:materialKeys:excluding:)`` and a limit.
    /// Rows come back best first; the score is `-bm25`.
    public static func ranking(_ table: String = "similar_positions", parameters: BM25Parameters = .standard) -> String {
        let weights = parameters.columnWeights.map { String($0) }.joined(separator: ", ")
        return "SELECT rowid, -bm25(\(table), \(weights)) AS score FROM \(table) WHERE \(table) MATCH ? ORDER BY bm25(\(table), \(weights)) LIMIT ?"
    }

    /// The FTS5 query: `(m… OR m…) AND (t1 OR t2 OR …)`. Terms are unique across columns,
    /// so no column filter is needed. `excluding` drops terms (for example the most common ones).
    public static func matchExpression(_ terms: PositionTerms, materialKeys: [String]?, excluding: Set<String> = []) -> String {
        var seen = Set<String>()
        var ors: [String] = []
        for column in TermColumn.allCases where column != .material {
            for t in terms[column] where !excluding.contains(t) && seen.insert(t).inserted { ors.append(t) }
        }
        let any = "(" + ors.joined(separator: " OR ") + ")"
        guard let keys = materialKeys, !keys.isEmpty else { return any }
        return "(" + keys.joined(separator: " OR ") + ") AND " + any
    }
}

/// Similar positions over SQLite FTS5 and its built-in `bm25()`.
///
/// Use it on its own database file, or hand it an open connection of the app's database.
public final class FTS5PositionIndex {
    public let table: String
    public var parameters: BM25Parameters
    public var termOptions: TermOptions
    public private(set) var db: OpaquePointer?
    private let ownsConnection: Bool
    private var insertStatement: OpaquePointer?
    private var inTransaction = false
    /// Document frequencies, read once from the vocabulary when a query prunes terms and kept up to
    /// date by ``add(gameID:ply:terms:)`` afterwards.
    private var frequencies: [String: Int]?
    private var documents = 0

    /// Opens (or creates) a database at `path`; `":memory:"` for a temporary one.
    public init(path: String = ":memory:", table: String = "similar_positions",
                parameters: BM25Parameters = .standard, termOptions: TermOptions = TermOptions()) throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw SQLiteError(code: rc, message: message)
        }
        db = handle
        ownsConnection = true
        self.table = table
        self.parameters = parameters
        self.termOptions = termOptions
        try execute("PRAGMA journal_mode=WAL")
        try execute(PositionFTS5Schema.createTable(table))
        try execute(PositionFTS5Schema.createVocabulary(table))
    }

    /// Uses a connection that the caller owns and closes.
    public init(connection: OpaquePointer, table: String = "similar_positions",
                parameters: BM25Parameters = .standard, termOptions: TermOptions = TermOptions()) throws {
        db = connection
        ownsConnection = false
        self.table = table
        self.parameters = parameters
        self.termOptions = termOptions
        try execute(PositionFTS5Schema.createTable(table))
        try execute(PositionFTS5Schema.createVocabulary(table))
    }

    deinit {
        sqlite3_finalize(insertStatement)
        if ownsConnection { sqlite3_close_v2(db) }
    }

    // MARK: Writing

    public func beginBatch() throws {
        guard !inTransaction else { return }
        try execute("BEGIN")
        inTransaction = true
    }

    public func commit() throws {
        guard inTransaction else { return }
        try execute("COMMIT")
        inTransaction = false
    }

    public func add(gameID: Int64, ply: Int, terms: PositionTerms) throws {
        if insertStatement == nil { insertStatement = try prepare(PositionFTS5Schema.insert(table)) }
        let stmt = insertStatement
        sqlite3_reset(stmt)
        sqlite3_bind_int64(stmt, 1, PositionDocumentID.make(gameID: gameID, ply: ply))
        for (i, text) in terms.columnTexts.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 2), text, -1, Self.transient)
        }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else { throw error(rc) }
        if frequencies != nil {
            documents += 1
            for t in Set(terms.allTerms) { frequencies![t, default: 0] += 1 }
        }
    }

    /// Reads every document frequency from the FTS5 vocabulary (one scan; 0.8 s for 60 k terms
    /// and 215 k documents). Called on the first query that prunes terms.
    public func loadStatistics() throws {
        var out: [String: Int] = [:]
        let stmt = try prepare("SELECT term, doc FROM \(table)_vocab")
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            out[String(cString: sqlite3_column_text(stmt, 0))] = Int(sqlite3_column_int64(stmt, 1))
        }
        frequencies = out
        documents = try rowCount()
    }

    public func add(gameID: Int64, ply: Int, position: SimilarityPosition) throws {
        try add(gameID: gameID, ply: ply, terms: PositionTerms(position, options: termOptions))
    }

    /// Adds the moments of a game and returns them.
    @discardableResult
    public func add(gameID: Int64, line: GameLine, policy: MomentPolicy = MomentPolicy()) throws -> [Moment] {
        let moments = policy.moments(of: line)
        for m in moments { try add(gameID: gameID, ply: m.ply, position: line.positions[m.ply]) }
        return moments
    }

    /// Merges the FTS5 segments (smaller and faster to query after a bulk load).
    public func optimize() throws {
        try execute("INSERT INTO \(table)(\(table)) VALUES('optimize')")
    }

    // MARK: Reading

    public var documentCount: Int { (try? rowCount()) ?? 0 }

    private func rowCount() throws -> Int {
        // A contentless table has no content to count; the docsize shadow table has one row per document.
        try scalar("SELECT COUNT(*) FROM \(table)_docsize")
    }

    /// Documents containing `term`.
    public func documentFrequency(_ term: String) throws -> Int {
        let stmt = try prepare("SELECT doc FROM \(table)_vocab WHERE term = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, term, -1, Self.transient)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    public func search(_ position: SimilarityPosition, options: PositionQueryOptions = PositionQueryOptions()) throws -> [SimilarPosition] {
        try search(PositionTerms(position, options: termOptions), materialKeys: options.material.keys(for: position), options: options)
    }

    public func search(_ terms: PositionTerms, materialKeys: [String]?, options: PositionQueryOptions = PositionQueryOptions()) throws -> [SimilarPosition] {
        if let keys = materialKeys, keys.isEmpty { return [] }
        var terms = terms
        if options.maximumDocumentShare != nil || options.maximumTerms != nil {
            if frequencies == nil { try loadStatistics() }
            let df = frequencies ?? [:]
            terms = terms.pruned(documents: documents, frequency: { df[$0] ?? 0 }, weights: parameters, options: options)
        }
        guard TermColumn.allCases.contains(where: { $0 != .material && !terms[$0].isEmpty }) else { return [] }
        let excluded = Set<String>()
        let expression = PositionFTS5Schema.matchExpression(terms, materialKeys: materialKeys, excluding: excluded)
        let fetch = options.onePerGame ? max(options.limit * 8, 64) : options.limit + (options.excludedGame == nil ? 0 : 8)
        let stmt = try prepare(PositionFTS5Schema.ranking(table, parameters: parameters))
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, expression, -1, Self.transient)
        sqlite3_bind_int64(stmt, 2, Int64(fetch))
        var hits: [SimilarPosition] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(rc) }
            let id = sqlite3_column_int64(stmt, 0)
            hits.append(SimilarPosition(gameID: PositionDocumentID.gameID(id), ply: PositionDocumentID.ply(id), score: sqlite3_column_double(stmt, 1)))
        }
        return hits.ranked(options)
    }

    // MARK: SQLite helpers

    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &message)
        if rc != SQLITE_OK {
            let text = message.map { String(cString: $0) } ?? ""
            sqlite3_free(message)
            throw SQLiteError(code: rc, message: text)
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK else { throw error(rc) }
        return stmt
    }

    func scalar(_ sql: String) throws -> Int {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    func error(_ rc: Int32) -> SQLiteError {
        SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(db)))
    }
}
#endif
