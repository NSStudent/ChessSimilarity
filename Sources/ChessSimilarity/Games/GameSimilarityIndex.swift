//
//  GameSimilarityIndex.swift
//  ChessSimilarity
//

/// A hit of a similar-game search.
public struct SimilarGame: Hashable, Sendable {
    public var gameID: Int64
    /// Estimated Jaccard similarity of the two games' sets.
    public var similarity: Double
}

/// A pair of games found by ``GameSimilarityIndex/pairs(minimumSimilarity:)``.
public struct SimilarGamePair: Hashable, Sendable {
    public var first: Int64
    public var second: Int64
    public var similarity: Double
}

/// Similar games and near duplicates: MinHash signatures in LSH buckets.
///
/// Storage per game is `hashCount × 2` bytes of signature (64 B with the presets) plus one
/// bucket entry per band.
public struct GameSimilarityIndex: Sendable {
    public let hasher: MinHasher
    public let lsh: LSHConfiguration
    public let setOptions: GameSetOptions

    private var gameIDs: [Int64] = []
    private var signatures: [UInt16] = []
    private var buckets: [[UInt64: [Int32]]]

    public init(lsh: LSHConfiguration = .similarGames, setOptions: GameSetOptions = .similarGames, seed: UInt64 = 0x5EED_C0DE_2026_1117) {
        self.lsh = lsh
        self.setOptions = setOptions
        hasher = MinHasher(hashCount: lsh.hashCount, seed: seed)
        buckets = Array(repeating: [:], count: lsh.bands)
    }

    /// Near-duplicate preset: every position, 8 × 4 bands.
    public static func nearDuplicates() -> GameSimilarityIndex {
        GameSimilarityIndex(lsh: .nearDuplicates, setOptions: .nearDuplicates)
    }

    public var count: Int { gameIDs.count }

    /// Bytes of signatures plus bucket entries (4 B per entry), without dictionary overhead.
    public var payloadBytes: Int { signatures.count * 2 + gameIDs.count * lsh.bands * 4 }

    public func signature(_ line: GameLine) -> [UInt16] {
        hasher.signature(line, options: setOptions)
    }

    func bandKey(_ sig: ArraySlice<UInt16>, band: Int) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325 ^ UInt64(band)
        for v in sig { h = (h ^ UInt64(v)) &* 0x0000_0100_0000_01B3 }
        return h
    }

    func storedSignature(_ i: Int) -> ArraySlice<UInt16> {
        signatures[i * lsh.hashCount ..< (i + 1) * lsh.hashCount]
    }

    public mutating func add(gameID: Int64, signature sig: [UInt16]) {
        precondition(sig.count == lsh.hashCount)
        let i = Int32(gameIDs.count)
        gameIDs.append(gameID)
        signatures += sig
        for band in 0 ..< lsh.bands {
            let key = bandKey(sig[band * lsh.rows ..< (band + 1) * lsh.rows], band: band)
            buckets[band][key, default: []].append(i)
        }
    }

    public mutating func add(gameID: Int64, line: GameLine) {
        add(gameID: gameID, signature: signature(line))
    }

    static func similarity(_ a: ArraySlice<UInt16>, _ b: ArraySlice<UInt16>) -> Double {
        MinHasher.estimatedJaccard(Array(a), Array(b))
    }

    /// Indexed games that share a band with `sig`, by estimated similarity (ties by game id).
    public func search(signature sig: [UInt16], limit: Int = 10, minimumSimilarity: Double = 0, excludedGame: Int64? = nil) -> [SimilarGame] {
        var seen = Set<Int32>()
        for band in 0 ..< lsh.bands {
            let key = bandKey(sig[band * lsh.rows ..< (band + 1) * lsh.rows], band: band)
            for i in buckets[band][key] ?? [] { seen.insert(i) }
        }
        var hits: [SimilarGame] = []
        for i in seen {
            let k = Int(i)
            if let excludedGame, gameIDs[k] == excludedGame { continue }
            let s = Self.similarity(sig[...], storedSignature(k))
            if s >= minimumSimilarity { hits.append(SimilarGame(gameID: gameIDs[k], similarity: s)) }
        }
        return Array(hits.sorted { ($0.similarity, -$0.gameID) > ($1.similarity, -$1.gameID) }.prefix(limit))
    }

    public func search(_ line: GameLine, limit: Int = 10, minimumSimilarity: Double = 0, excludedGame: Int64? = nil) -> [SimilarGame] {
        search(signature: signature(line), limit: limit, minimumSimilarity: minimumSimilarity, excludedGame: excludedGame)
    }

    /// Every pair of indexed games that shares a band and reaches `minimumSimilarity`
    /// (for example 0.8 for near duplicates), most similar first. Buckets larger than
    /// `maximumBucket` are skipped (they come from very common sets, such as games that
    /// end in the opening).
    public func pairs(minimumSimilarity: Double, maximumBucket: Int = 500) -> [SimilarGamePair] {
        var seen = Set<UInt64>()
        var out: [SimilarGamePair] = []
        for band in buckets {
            for (_, members) in band where members.count > 1 && members.count <= maximumBucket {
                for x in 0 ..< members.count {
                    for y in x + 1 ..< members.count {
                        let a = members[x], b = members[y]
                        let key = UInt64(UInt32(min(a, b))) << 32 | UInt64(UInt32(max(a, b)))
                        guard seen.insert(key).inserted else { continue }
                        let s = Self.similarity(storedSignature(Int(a)), storedSignature(Int(b)))
                        if s >= minimumSimilarity {
                            out.append(SimilarGamePair(first: gameIDs[Int(min(a, b))], second: gameIDs[Int(max(a, b))], similarity: s))
                        }
                    }
                }
            }
        }
        return out.sorted { ($0.similarity, -$0.first, -$0.second) > ($1.similarity, -$1.first, -$1.second) }
    }
}
