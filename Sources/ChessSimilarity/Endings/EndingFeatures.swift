//
//  EndingFeatures.swift
//  ChessSimilarity
//

import ChessPawnStructures

/// The features of an ending position, packed in 32 bytes.
///
/// - **Material**: queens, rooks, bishops, knights and pawns of each side, and the
///   square colours of the bishops.
/// - **Pawns**: the pawn bitboards themselves (for a Hamming term), islands, passed,
///   isolated and doubled pawns, and the relative rank of the most advanced passed pawn.
/// - **Kings**: distance to the centre, relative rank, and distance to the nearest
///   passed pawn of each side (own and enemy).
public struct EndingFeatures: Hashable, Sendable {
    /// `[color][kind]` counts for queen, rook, bishop, knight, pawn: `color * 5 + slot`.
    public var counts: SIMD16<UInt8>
    /// Per side: islands, passed, isolated, doubled, best passed relative rank (0 = none),
    /// king centre distance (0–3), king relative rank, king distance to own passed, to enemy passed
    /// (7 = none), bishop colours (bit 0 light, bit 1 dark). Index `color * 10 + slot`.
    public var traits: SIMD32<UInt8>
    public var whitePawns: UInt64
    public var blackPawns: UInt64
    public var sideToMove: PieceColor

    public init(_ p: SimilarityPosition) {
        var c = SIMD16<UInt8>(repeating: 0)
        for color in PieceColor.allCases {
            for (slot, kind) in Self.kinds.enumerated() {
                c[color.rawValue * 5 + slot] = UInt8(p[color, kind].nonzeroBitCount)
            }
        }
        counts = c
        whitePawns = p[.white, .pawn]
        blackPawns = p[.black, .pawn]
        sideToMove = p.sideToMove
        let s = PawnStructure(white: whitePawns, black: blackPawns)
        let t = PawnTraits(s)
        var v = SIMD32<UInt8>(repeating: 0)
        for color in PieceColor.allCases {
            let st = color == .white ? t.white : t.black
            let o = color.rawValue * 10
            v[o] = UInt8(st.islands)
            v[o + 1] = UInt8(st.passed.nonzeroBitCount)
            v[o + 2] = UInt8(st.isolated.nonzeroBitCount)
            v[o + 3] = UInt8(st.doubledCount)
            var best = 0
            st.passed.forEachBit { sq in
                let rel = color == .white ? sq >> 3 : 7 - sq >> 3
                best = max(best, rel)
            }
            v[o + 4] = UInt8(best)
            let k = p.kingSquare(color)
            let f = k & 7, r = k >> 3
            v[o + 5] = UInt8(max(f < 4 ? 3 - f : f - 4, r < 4 ? 3 - r : r - 4))
            v[o + 6] = UInt8(color == .white ? r : 7 - r)
            v[o + 7] = UInt8(Self.nearest(k, st.passed))
            let enemy = color == .white ? t.black : t.white
            v[o + 8] = UInt8(Self.nearest(k, enemy.passed))
            let bishops = p[color, .bishop]
            v[o + 9] = (bishops & Self.light != 0 ? 1 : 0) | (bishops & ~Self.light != 0 ? 2 : 0)
        }
        traits = v
    }

    public init(fen: String) throws {
        self.init(try SimilarityPosition(fen: fen))
    }

    static let kinds: [PieceKind] = [.queen, .rook, .bishop, .knight, .pawn]
    static let light: UInt64 = 0x55AA_55AA_55AA_55AA

    static func nearest(_ king: Int, _ targets: UInt64) -> Int {
        var best = 7
        targets.forEachBit { best = min(best, Attacks.distance(king, $0)) }
        return best
    }

    public func count(_ color: PieceColor, _ kind: PieceKind) -> Int {
        guard let slot = Self.kinds.firstIndex(of: kind) else { return 1 }
        return Int(counts[color.rawValue * 5 + slot])
    }

    /// The pieces without pawns, `KRBvKR`-style: identical keys have the same pieces.
    public var pieceKey: String {
        var out = ""
        for color in PieceColor.allCases {
            out += "K"
            for (slot, kind) in Self.kinds.enumerated() where kind != .pawn {
                out += String(repeating: String(kind.letter).uppercased(), count: Int(counts[color.rawValue * 5 + slot]))
            }
            if color == .white { out += "v" }
        }
        return out
    }

    /// `KRPPvKRP`-style material class.
    public var materialClass: String {
        var out = ""
        for color in PieceColor.allCases {
            out += "K"
            for (slot, kind) in Self.kinds.enumerated() {
                out += String(repeating: String(kind.letter).uppercased(), count: Int(counts[color.rawValue * 5 + slot]))
            }
            if color == .white { out += "v" }
        }
        return out
    }

    /// The same ending with colours swapped (so «KRvKRP» is compared with «KRPvKR»).
    public var colorsReversed: EndingFeatures {
        var copy = self
        for i in 0 ..< 5 {
            copy.counts[i] = counts[i + 5]
            copy.counts[i + 5] = counts[i]
        }
        for i in 0 ..< 10 {
            copy.traits[i] = traits[i + 10]
            copy.traits[i + 10] = traits[i]
        }
        copy.whitePawns = blackPawns.byteSwapped
        copy.blackPawns = whitePawns.byteSwapped
        copy.sideToMove = sideToMove.opponent
        copy.swapBishopColors()
        return copy
    }

    /// Flipping the board vertically or mirroring it swaps light and dark squares.
    mutating func swapBishopColors() {
        for i in [9, 19] {
            let v = traits[i]
            traits[i] = (v & 1) << 1 | (v & 2) >> 1
        }
    }

    /// The same ending mirrored a↔h (pawn bitboards only; the other features don't change).
    public var mirrored: EndingFeatures {
        var copy = self
        copy.whitePawns = Self.mirror(whitePawns)
        copy.blackPawns = Self.mirror(blackPawns)
        copy.swapBishopColors()
        return copy
    }

    static func mirror(_ b: UInt64) -> UInt64 {
        var x = b
        x = ((x >> 1) & 0x5555_5555_5555_5555) | ((x & 0x5555_5555_5555_5555) << 1)
        x = ((x >> 2) & 0x3333_3333_3333_3333) | ((x & 0x3333_3333_3333_3333) << 2)
        x = ((x >> 4) & 0x0F0F_0F0F_0F0F_0F0F) | ((x & 0x0F0F_0F0F_0F0F_0F0F) << 4)
        return x
    }
}

/// Weighted L1 distance between endings.
///
/// | Component | Weight |
/// |---|--:|
/// | Queen / rook / minor / pawn count, per unit | 8 / 6 / 4 / 2 |
/// | Bishop colours (same vs opposite), per side | 1.5 |
/// | Pawn squares (Hamming, per square) | 0.25 |
/// | Islands, isolated, doubled, per unit | 0.5 |
/// | Passed pawns, per unit | 2 |
/// | Best passed pawn rank, per rank | 0.5 |
/// | King centre distance, per step | 0.5 |
/// | King relative rank, per rank | 0.25 |
/// | King to passed pawns (own and enemy), per step | 0.25 |
/// | Side to move | 0.5 |
///
/// Material weighs most, so a different piece is never closer than a pawn
/// standing elsewhere. The pawn files can be mirrored (a↔h) when the
/// structure is the same on the other wing.
public struct EndingDistance: Hashable, Sendable {
    public var queen = 8.0, rook = 6.0, minor = 4.0, pawn = 2.0
    public var bishopColors = 1.5
    public var pawnSquare = 0.25
    public var structure = 0.5
    public var passed = 2.0
    public var passedRank = 0.5
    public var kingCentre = 0.5
    public var kingRank = 0.25
    public var kingToPassed = 0.25
    public var sideToMove = 0.5
    /// Also compare with the colours reversed and with the board mirrored a↔h, and keep the smallest.
    public var allowsSymmetries = true

    public init() {}

    public static let standard = EndingDistance()

    public func callAsFunction(_ a: EndingFeatures, _ b: EndingFeatures) -> Double { distance(a, b) }

    public func distance(_ a: EndingFeatures, _ b: EndingFeatures) -> Double {
        guard allowsSymmetries else { return raw(a, b) }
        let r = b.colorsReversed
        return min(raw(a, b), raw(a, b.mirrored), raw(a, r), raw(a, r.mirrored))
    }

    func raw(_ a: EndingFeatures, _ b: EndingFeatures) -> Double {
        let unit = [queen, rook, minor, minor, pawn]
        var d = 0.0
        for i in 0 ..< 10 {
            d += unit[i % 5] * Double(abs(Int(a.counts[i]) - Int(b.counts[i])))
        }
        d += pawnSquare * Double((a.whitePawns ^ b.whitePawns).nonzeroBitCount + (a.blackPawns ^ b.blackPawns).nonzeroBitCount)
        for side in 0 ..< 2 {
            let o = side * 10
            func diff(_ k: Int) -> Double { Double(abs(Int(a.traits[o + k]) - Int(b.traits[o + k]))) }
            d += structure * (diff(0) + diff(2) + diff(3))
            d += passed * diff(1) + passedRank * diff(4)
            d += kingCentre * diff(5) + kingRank * diff(6) + kingToPassed * (diff(7) + diff(8))
            if a.traits[o + 9] != b.traits[o + 9] { d += bishopColors }
        }
        if a.sideToMove != b.sideToMove { d += sideToMove }
        return d
    }
}
