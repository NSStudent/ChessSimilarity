//
//  BM25.swift
//  ChessSimilarity
//

import Foundation

/// BM25 with per-column weights, computed exactly like SQLite FTS5's `bm25()`:
///
/// ```
/// score = Σ_terms IDF(t) · f(t)·(k1+1) / (f(t) + k1·(1 − b + b·|D|/avgdl))
/// f(t)  = Σ_columns weight(c) · hits(t, c)
/// IDF   = ln((N − n(t) + 0.5) / (n(t) + 0.5)), at least 1e-6
/// ```
///
/// `|D|` is the number of terms of the document in all columns. FTS5 returns the score
/// negated (smaller is better); this package returns it positive (larger is better).
public struct BM25Parameters: Hashable, Sendable {
    public var k1: Double
    public var b: Double
    /// One weight per ``TermColumn``, in order.
    public var columnWeights: [Double]

    public init(k1: Double = 1.2, b: Double = 0.75, columnWeights: [Double] = BM25Parameters.defaultWeights) {
        precondition(columnWeights.count == TermColumn.allCases.count)
        self.k1 = k1
        self.b = b
        self.columnWeights = columnWeights
    }

    /// pieces 1, reach 0.5, links 0.75, pawns 1, king 0.75, balance 0.5, material 0.
    public static let defaultWeights: [Double] = [1, 0.5, 0.75, 1, 0.75, 0.5, 0]

    public static let standard = BM25Parameters()

    public func weight(_ column: TermColumn) -> Double { columnWeights[column.rawValue] }

    /// FTS5's IDF.
    @inlinable
    public static func idf(documents n: Int, containing hits: Int) -> Double {
        let v = log((Double(n) - Double(hits) + 0.5) / (Double(hits) + 0.5))
        return v <= 0 ? 1e-6 : v
    }

    /// The contribution of one term.
    @inlinable
    public func termScore(idf: Double, frequency f: Double, length: Double, averageLength: Double) -> Double {
        idf * f * (k1 + 1) / (f + k1 * (1 - b + b * length / averageLength))
    }
}

/// How to treat material when looking for similar positions.
public enum MaterialFilter: Hashable, Sendable {
    /// Any material.
    case none
    /// The same pieces and pawns on each side (ChessBase's «same material relation»).
    case exact
    /// The same pieces; each side's pawns may differ by up to `n`.
    case pawnTolerance(Int)

    /// The material tokens accepted for `p`.
    public func keys(for p: SimilarityPosition) -> [String]? {
        switch self {
        case .none: return nil
        case .exact: return [PositionTerms.materialKey(p)].compactMap { $0 }
        case let .pawnTolerance(n):
            var out: [String] = []
            for w in -n ... n {
                for b in -n ... n {
                    if let k = PositionTerms.materialKey(p, whitePawns: w, blackPawns: b) { out.append(k) }
                }
            }
            return out
        }
    }
}

/// A hit of a similar-position search.
public struct SimilarPosition: Hashable, Sendable {
    public var gameID: Int64
    public var ply: Int
    /// BM25 score, larger is more similar.
    public var score: Double

    public init(gameID: Int64, ply: Int, score: Double) {
        self.gameID = gameID
        self.ply = ply
        self.score = score
    }
}

/// Options of a similar-position query.
public struct PositionQueryOptions: Hashable, Sendable {
    public var limit: Int
    public var material: MaterialFilter
    /// Keep only the best position of each game (Ganguly et al.'s re-ranking, and what
    /// ChessBase's «similar middlegame» shows).
    public var onePerGame: Bool
    /// Leave out query terms that appear in more than this share of the documents
    /// (their IDF is close to zero, and in FTS5 they cost a long posting list each).
    /// `nil` keeps every term.
    public var maximumDocumentShare: Double?
    /// Keep only the query terms with the largest `IDF × column weight` (the ones that
    /// weigh most in BM25). FTS5's cost grows with the summed length of the posting lists
    /// of the query terms, so this is the main speed control. The default, 48 of about 160,
    /// keeps 80 % of the top-10 games of the full query on 100 k games at 1/15 of the time.
    /// `nil` keeps every term (exact BM25 over the whole document).
    public var maximumTerms: Int?
    /// Leave out this game (for example the game the query position comes from).
    public var excludedGame: Int64?

    public init(limit: Int = 10, material: MaterialFilter = .exact, onePerGame: Bool = true,
                maximumDocumentShare: Double? = nil, maximumTerms: Int? = 48, excludedGame: Int64? = nil) {
        self.limit = limit
        self.material = material
        self.onePerGame = onePerGame
        self.maximumDocumentShare = maximumDocumentShare
        self.maximumTerms = maximumTerms
        self.excludedGame = excludedGame
    }
}

extension PositionTerms {
    /// The query terms left after ``PositionQueryOptions/maximumDocumentShare`` and
    /// ``PositionQueryOptions/maximumTerms``, by column. Terms missing from the index
    /// (frequency 0) can't match and are dropped. The material column is kept as is.
    public func pruned(documents n: Int, frequency: (String) -> Int, weights: BM25Parameters,
                       options: PositionQueryOptions) -> PositionTerms {
        guard options.maximumDocumentShare != nil || options.maximumTerms != nil, n > 0 else { return self }
        var ranked: [(term: String, value: Double)] = []
        var seen = Set<String>()
        for column in TermColumn.allCases where column != .material {
            for t in self[column] where seen.insert(t).inserted {
                let df = frequency(t)
                guard df > 0 else { continue }
                if let share = options.maximumDocumentShare, Double(df) > share * Double(n) { continue }
                ranked.append((t, BM25Parameters.idf(documents: n, containing: df) * weights.weight(column)))
            }
        }
        if let limit = options.maximumTerms, ranked.count > limit {
            ranked.sort { ($0.value, $1.term) > ($1.value, $0.term) }
            ranked.removeLast(ranked.count - limit)
        }
        let keep = Set(ranked.map(\.term))
        return PositionTerms(columns: TermColumn.allCases.map { c in
            c == .material ? self[c] : self[c].filter { keep.contains($0) }
        })
    }
}

/// Document ids pack the game and the ply: `gameID << 10 | ply` (plies above 1023 are clamped).
public enum PositionDocumentID {
    public static func make(gameID: Int64, ply: Int) -> Int64 { gameID << 10 | Int64(min(max(ply, 0), 1023)) }
    public static func gameID(_ id: Int64) -> Int64 { id >> 10 }
    public static func ply(_ id: Int64) -> Int { Int(id & 1023) }
}

extension [SimilarPosition] {
    /// Sorts by score (ties by game and ply), keeps the best per game if asked, and cuts to `limit`.
    func ranked(_ options: PositionQueryOptions) -> [SimilarPosition] {
        var hits = self
        if let excluded = options.excludedGame { hits.removeAll { $0.gameID == excluded } }
        hits.sort { ($0.score, -$0.gameID, -$0.ply) > ($1.score, -$1.gameID, -$1.ply) }
        guard options.onePerGame else { return Array(hits.prefix(options.limit)) }
        var seen = Set<Int64>()
        var out: [SimilarPosition] = []
        for h in hits where seen.insert(h.gameID).inserted {
            out.append(h)
            if out.count == options.limit { break }
        }
        return out
    }
}
