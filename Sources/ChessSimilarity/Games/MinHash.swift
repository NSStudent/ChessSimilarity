//
//  MinHash.swift
//  ChessSimilarity
//

import Foundation

/// Which elements make the set of a game.
public struct GameSetOptions: Hashable, Sendable {
    /// Plies before this one are left out (every game shares the first ones).
    public var firstPly: Int
    /// Add the position keys (placement and side to move).
    public var includesPositions: Bool
    /// Add the pawn structures (pawn keys) of the game, so games that share
    /// structures but not exact positions still look alike.
    public var includesPawnStructures: Bool

    public init(firstPly: Int = 0, includesPositions: Bool = true, includesPawnStructures: Bool = false) {
        self.firstPly = firstPly
        self.includesPositions = includesPositions
        self.includesPawnStructures = includesPawnStructures
    }

    /// Every position: Jaccard over the set of position keys, for (near) duplicates.
    public static let nearDuplicates = GameSetOptions(firstPly: 0)
    /// The pawn structures from ply 8 on: games that go through the same structures
    /// («similar games»). Exact positions are left out: past the opening two games
    /// rarely share them, and they would dilute the shared structures.
    public static let similarGames = GameSetOptions(firstPly: 8, includesPositions: false, includesPawnStructures: true)

    /// The set of 64-bit keys of a game.
    public func elements(of line: GameLine) -> [UInt64] {
        var out = Set<UInt64>()
        for i in line.positions.indices where i >= firstPly {
            let p = line.positions[i]
            if includesPositions { out.insert(PositionKey.key(p)) }
            // Pawn keys are tagged so they never equal a position key.
            if includesPawnStructures { out.insert(PositionKey.pawnKey(p) ^ 0xA5A5_5A5A_C3C3_3C3C) }
        }
        return Array(out)
    }
}

/// MinHash (Broder 1997) with b-bit signatures (Li and König 2010): each of the
/// `hashCount` slots keeps the low 16 bits of the minimum of an independent hash
/// over the set. The share of equal slots estimates the Jaccard similarity.
public struct MinHasher: Hashable, Sendable {
    public let hashCount: Int
    let seeds: [UInt64]

    public init(hashCount: Int = 32, seed: UInt64 = 0x5EED_C0DE_2026_1117) {
        precondition(hashCount > 0)
        self.hashCount = hashCount
        var state = seed
        seeds = (0 ..< hashCount).map { _ in PositionKey.splitMix(&state) | 1 }
    }

    @inline(__always)
    static func mix(_ x: UInt64) -> UInt64 {
        var z = x
        z = (z ^ (z >> 33)) &* 0xFF51_AFD7_ED55_8CCD
        z = (z ^ (z >> 33)) &* 0xC4CE_B9FE_1A85_EC53
        return z ^ (z >> 33)
    }

    /// The signature of a set of keys. An empty set gives all slots `UInt16.max`.
    public func signature(_ elements: [UInt64]) -> [UInt16] {
        var mins = [UInt64](repeating: .max, count: hashCount)
        seeds.withUnsafeBufferPointer { s in
            mins.withUnsafeMutableBufferPointer { m in
                for e in elements {
                    for i in 0 ..< s.count {
                        let h = Self.mix(e &* s[i])
                        if h < m[i] { m[i] = h }
                    }
                }
            }
        }
        return mins.map { UInt16(truncatingIfNeeded: $0) }
    }

    public func signature(_ line: GameLine, options: GameSetOptions) -> [UInt16] {
        signature(options.elements(of: line))
    }

    /// Estimated Jaccard similarity: share of equal slots, corrected for chance
    /// collisions of 16-bit values (`(m − 2⁻¹⁶) / (1 − 2⁻¹⁶)`).
    public static func estimatedJaccard(_ a: [UInt16], _ b: [UInt16]) -> Double {
        precondition(a.count == b.count)
        var equal = 0
        for i in a.indices where a[i] == b[i] { equal += 1 }
        let m = Double(equal) / Double(a.count)
        let c = 1.0 / 65536.0
        return max(0, (m - c) / (1 - c))
    }

    /// The exact Jaccard similarity of two sets of keys.
    public static func jaccard(_ a: [UInt64], _ b: [UInt64]) -> Double {
        let sa = Set(a), sb = Set(b)
        let union = sa.union(sb).count
        return union == 0 ? 1 : Double(sa.intersection(sb).count) / Double(union)
    }
}

/// LSH banding: the signature is cut into `bands` bands of `rows` slots; two games
/// become candidates when one band is identical. The probability for Jaccard `s`
/// is `1 − (1 − s^rows)^bands`, with its steepest point near `(1/bands)^(1/rows)`.
public struct LSHConfiguration: Hashable, Sendable {
    public var bands: Int
    public var rows: Int

    public init(bands: Int, rows: Int) {
        precondition(bands > 0 && rows > 0)
        self.bands = bands
        self.rows = rows
    }

    public var hashCount: Int { bands * rows }

    /// Probability that two sets with Jaccard `s` share a band.
    public func candidateProbability(_ s: Double) -> Double {
        1 - pow(1 - pow(s, Double(rows)), Double(bands))
    }

    /// The Jaccard similarity where the probability is about 1/2.
    public var threshold: Double { pow(1 / Double(bands), 1 / Double(rows)) }

    /// 8 bands × 4 rows (32 slots): threshold ≈ 0.59, for near duplicates.
    public static let nearDuplicates = LSHConfiguration(bands: 8, rows: 4)
    /// 16 bands × 2 rows (32 slots): threshold ≈ 0.25, for similar games.
    public static let similarGames = LSHConfiguration(bands: 16, rows: 2)
}

