//
//  StructureIndex.swift
//  ChessSimilarity
//

import ChessPawnStructures

/// A concrete structure close to the query.
public struct SimilarStructure: Hashable, Sendable {
    public var structure: PawnStructure
    public var distance: Double
    /// Games of the index that reached this structure.
    public var games: Int
    /// The structure was matched with its colours reversed.
    public var reversed: Bool
}

/// Distinct pawn structures of a base with the number of games that reached each one,
/// searched with ``StructureDistance``.
///
/// The search sorts the candidates by Hamming distance (two popcounts each) and computes
/// the full distance only while `hamming × weight` can still beat the k-th best: the
/// weighted traits only add to the Hamming part, so that bound is exact.
public struct StructureIndex: Sendable {
    public var distance: StructureDistance
    /// Plies before this one are not indexed by ``add(gameID:line:)`` (the opening structures).
    public var firstPly: Int
    /// ``add(gameID:line:)`` skips structures that last fewer plies than this (the half-finished
    /// exchanges between a capture and its recapture). The last structure of the game always counts.
    public var minimumPlies: Int

    private var slot: [PawnStructure: Int32] = [:]
    private var whites: [UInt64] = []
    private var blacks: [UInt64] = []
    private var gameCounts: [Int32] = []
    private var traits: [CompactTraits] = []
    private var lastGame: [Int64] = []

    public init(distance: StructureDistance = StructureDistance(), firstPly: Int = 14, minimumPlies: Int = 4) {
        self.distance = distance
        self.firstPly = firstPly
        self.minimumPlies = minimumPlies
    }

    /// Distinct structures.
    public var count: Int { whites.count }

    /// 16 bytes of pawns, 16 of traits and 4 of game count per structure.
    public var payloadBytes: Int { count * 36 }

    /// Counts `structure` once for `gameID` (repeated calls for the same game count once
    /// while they are consecutive, as when a game is added ply by ply).
    public mutating func add(_ structure: PawnStructure, gameID: Int64) {
        if let i = slot[structure] {
            let k = Int(i)
            if lastGame[k] != gameID {
                gameCounts[k] += 1
                lastGame[k] = gameID
            }
            return
        }
        slot[structure] = Int32(whites.count)
        whites.append(structure.white)
        blacks.append(structure.black)
        traits.append(CompactTraits(structure))
        gameCounts.append(1)
        lastGame.append(gameID)
    }

    /// Adds every distinct structure of the game from ``firstPly`` on that lasts at least ``minimumPlies``.
    public mutating func add(gameID: Int64, line: GameLine) {
        var current: PawnStructure?
        var run = 0
        for (i, p) in line.positions.enumerated() where i >= firstPly {
            let s = StructureSimilarity.structure(p)
            if s == current {
                run += 1
                continue
            }
            if let current, run >= minimumPlies { add(current, gameID: gameID) }
            current = s
            run = 1
        }
        if let current { add(current, gameID: gameID) }
    }

    /// Number of games of a structure (0 if absent).
    public func games(of structure: PawnStructure) -> Int {
        slot[structure].map { Int(gameCounts[Int($0)]) } ?? 0
    }

    /// The `limit` nearest structures to `query`, nearest first (ties: more games first).
    /// With `allowingReversedColors`, each candidate also counts with its colours reversed.
    /// `excludingQuery` leaves the query structure itself out.
    public func nearest(_ query: PawnStructure, limit: Int = 10, allowingReversedColors: Bool = false,
                        excludingQuery: Bool = false) -> [SimilarStructure] {
        guard limit > 0, !whites.isEmpty else { return [] }
        var targets = [(structure: query, reversed: false)]
        if allowingReversedColors { targets.append((query.colorsReversed, true)) }
        let targetTraits = targets.map { CompactTraits($0.structure) }
        let w = distance.weights
        let n = whites.count
        // Pass 1: Hamming distance of every candidate to every target (at most 64).
        var hamming = [UInt8](repeating: 0, count: n * targets.count)
        var histogram = [Int](repeating: 0, count: 66)
        for (ti, t) in targets.enumerated() {
            for i in 0 ..< n {
                var h = (whites[i] ^ t.structure.white).nonzeroBitCount + (blacks[i] ^ t.structure.black).nonzeroBitCount
                if excludingQuery, whites[i] == query.white, blacks[i] == query.black { h = 65 }
                hamming[ti * n + i] = UInt8(h)
                histogram[h] += 1
            }
        }
        var bound = 0, cumulative = 0
        while bound < 64 {
            cumulative += histogram[bound]
            if cumulative >= limit { break }
            bound += 1
        }
        // Bounded top k, sorted by (distance, more games, pawns); one entry per stored structure.
        var best: [(distance: Double, index: Int, reversed: Bool)] = []
        func before(_ a: (distance: Double, index: Int, reversed: Bool), _ b: (distance: Double, index: Int, reversed: Bool)) -> Bool {
            if a.distance != b.distance { return a.distance < b.distance }
            if gameCounts[a.index] != gameCounts[b.index] { return gameCounts[a.index] > gameCounts[b.index] }
            return (whites[a.index], blacks[a.index]) < (whites[b.index], blacks[b.index])
        }
        func consider(_ entry: (distance: Double, index: Int, reversed: Bool)) {
            if let k = best.firstIndex(where: { $0.index == entry.index }) {
                guard entry.distance < best[k].distance else { return }
                best.remove(at: k)
            } else if best.count == limit, let last = best.last, !before(entry, last) {
                return
            }
            let at = best.firstIndex { before(entry, $0) } ?? best.count
            best.insert(entry, at: at)
            if best.count > limit { best.removeLast() }
        }
        func evaluate(above low: Int, upTo high: Int) {
            for (ti, t) in targets.enumerated() {
                let base = ti * n
                for i in 0 ..< n {
                    let h = Int(hamming[base + i])
                    guard h > low, h <= high else { continue }
                    let d = w.hamming * Double(h) + targetTraits[ti].distance(traits[i], w)
                    if best.count == limit, d > best[limit - 1].distance { continue }
                    consider((d, i, t.reversed))
                }
            }
        }
        evaluate(above: -1, upTo: bound)
        if best.count >= limit, w.hamming > 0 {
            // Anything with Hamming × weight above the k-th distance cannot enter the top k.
            let next = min(64, Int((best[limit - 1].distance / w.hamming).rounded(.down)))
            if next > bound { evaluate(above: bound, upTo: next) }
        } else if best.count < limit {
            evaluate(above: bound, upTo: 64)
        }
        return best.map { e in
            SimilarStructure(structure: PawnStructure(white: whites[e.index], black: blacks[e.index]), distance: e.distance,
                             games: Int(gameCounts[e.index]), reversed: e.reversed)
        }
    }

}

/// The traits that ``StructureDistance`` compares, in 16 bytes: per side isolated, doubled,
/// passed, backward and hanging counts, islands and semi-open files; then open files and
/// the majority on each flank.
struct CompactTraits: Hashable, Sendable {
    var v: SIMD16<UInt8>

    init(_ s: PawnStructure) {
        let t = PawnTraits(s)
        var v = SIMD16<UInt8>(repeating: 0)
        for (o, st) in [(0, t.white), (7, t.black)] {
            v[o] = UInt8(st.isolated.nonzeroBitCount)
            v[o + 1] = UInt8(st.doubledCount)
            v[o + 2] = UInt8(st.passed.nonzeroBitCount)
            v[o + 3] = UInt8(st.backward.nonzeroBitCount)
            v[o + 4] = UInt8(st.islands)
            v[o + 5] = UInt8(st.hanging.nonzeroBitCount)
            v[o + 6] = st.semiOpenFiles
        }
        v[14] = t.openFiles
        func code(_ side: Side?) -> UInt8 { side == nil ? 0 : (side == .white ? 1 : 2) }
        v[15] = code(t.majority(on: .queenside)) | code(t.majority(on: .kingside)) << 2
        self.v = v
    }

    /// The trait part of ``StructureDistance`` (everything but the Hamming term).
    @inline(__always)
    func distance(_ o: CompactTraits, _ w: StructureDistance.Weights) -> Double {
        var d = 0.0
        for base in [0, 7] {
            func diff(_ k: Int) -> Double { Double(abs(Int(v[base + k]) - Int(o.v[base + k]))) }
            d += w.isolated * diff(0) + w.doubled * diff(1) + w.passed * diff(2) + w.backward * diff(3)
            d += w.islands * diff(4) + w.hanging * diff(5)
            d += w.semiOpenFile * Double((v[base + 6] ^ o.v[base + 6]).nonzeroBitCount)
        }
        d += w.openFile * Double((v[14] ^ o.v[14]).nonzeroBitCount)
        if v[15] & 3 != o.v[15] & 3 { d += w.majority }
        if v[15] >> 2 != o.v[15] >> 2 { d += w.majority }
        return d
    }
}
