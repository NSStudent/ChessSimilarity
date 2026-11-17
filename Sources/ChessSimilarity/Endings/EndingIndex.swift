//
//  EndingIndex.swift
//  ChessSimilarity
//

/// A hit of a similar-ending search.
public struct SimilarEnding: Hashable, Sendable {
    public var gameID: Int64
    public var ply: Int
    /// ``EndingDistance``, smaller is more similar (0 = same features).
    public var distance: Double
}

/// Which endings to compare with the query.
public enum EndingCandidates: Hashable, Sendable {
    /// Only endings with the same pieces (pawns may differ), as a hard filter.
    case samePieces
    /// Every ending in the index.
    case all
}

/// Similar endings: one ending per game (its first quiet ending position) and a
/// linear scan with ``EndingDistance`` inside the bucket of the same pieces.
public struct EndingIndex: Sendable {
    public var distance: EndingDistance

    private var buckets: [String: [Int32]] = [:]
    private var gameIDs: [Int64] = []
    private var plies: [UInt16] = []
    private var features: [EndingFeatures] = []

    public init(distance: EndingDistance = .standard) {
        self.distance = distance
    }

    public var count: Int { features.count }

    /// Bytes per entry if stored packed: 10 counts, 20 traits, 16 pawn bytes, side to move,
    /// 2 bytes of ply (the game id is the row).
    public static let packedEntryBytes = 10 + 20 + 16 + 1 + 2

    /// The first quiet ending position of a game (see ``EndingPhase``), or `nil`.
    public static func endingPly(of line: GameLine) -> Int? {
        let captures = line.captures
        return line.positions.indices.first { i in
            EndingPhase.isEnding(line.positions[i]) && !captures[i] && !line.positions[i].isCheck
        }
    }

    public mutating func add(gameID: Int64, ply: Int, features f: EndingFeatures) {
        let i = Int32(features.count)
        features.append(f)
        gameIDs.append(gameID)
        plies.append(UInt16(clamping: ply))
        buckets[f.pieceKey, default: []].append(i)
    }

    /// Adds the ending of a game, if it has one, and returns its ply.
    @discardableResult
    public mutating func add(gameID: Int64, line: GameLine) -> Int? {
        guard let ply = Self.endingPly(of: line) else { return nil }
        add(gameID: gameID, ply: ply, features: EndingFeatures(line.positions[ply]))
        return ply
    }

    /// The `limit` nearest endings to `query`, nearest first (ties by game id).
    public func search(_ query: EndingFeatures, limit: Int = 10, candidates: EndingCandidates = .samePieces,
                       excludedGame: Int64? = nil) -> [SimilarEnding] {
        var pool: [Int32] = []
        switch candidates {
        case .all:
            pool = Array(0 ..< Int32(features.count))
        case .samePieces:
            pool = buckets[query.pieceKey] ?? []
            if distance.allowsSymmetries {
                let reversed = query.colorsReversed.pieceKey
                if reversed != query.pieceKey { pool += buckets[reversed] ?? [] }
            }
        }
        var hits: [SimilarEnding] = []
        hits.reserveCapacity(pool.count)
        for i in pool {
            let k = Int(i)
            if let excludedGame, gameIDs[k] == excludedGame { continue }
            hits.append(SimilarEnding(gameID: gameIDs[k], ply: Int(plies[k]), distance: distance(query, features[k])))
        }
        return Array(hits.sorted { ($0.distance, $0.gameID) < ($1.distance, $1.gameID) }.prefix(limit))
    }

    public func search(_ position: SimilarityPosition, limit: Int = 10, candidates: EndingCandidates = .samePieces,
                       excludedGame: Int64? = nil) -> [SimilarEnding] {
        search(EndingFeatures(position), limit: limit, candidates: candidates, excludedGame: excludedGame)
    }
}
