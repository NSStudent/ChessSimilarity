//
//  Attacks.swift
//  ChessSimilarity
//

/// Attack tables on raw `UInt64` bitboards (a1 = bit 0).
///
/// Sliding pieces use classical rays: the first blocker in a positive
/// direction is the lowest set bit, in a negative direction the highest.
public enum Attacks {
    public static let fileA: UInt64 = 0x0101_0101_0101_0101
    public static let rank1: UInt64 = 0xFF

    @inlinable public static func file(_ f: Int) -> UInt64 { fileA << UInt64(f) }
    @inlinable public static func rank(_ r: Int) -> UInt64 { rank1 << UInt64(8 * r) }

    static let knightTable: [UInt64] = (0 ..< 64).map { sq in
        jumps(sq, [(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)])
    }

    static let kingTable: [UInt64] = (0 ..< 64).map { sq in
        jumps(sq, [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)])
    }

    /// Pawn captures by colour (0 white, 1 black) and square.
    static let pawnTable: [[UInt64]] = [
        (0 ..< 64).map { jumps($0, [(-1, 1), (1, 1)]) },
        (0 ..< 64).map { jumps($0, [(-1, -1), (1, -1)]) },
    ]

    /// Directions: N, E, NE, NW (positive), S, W, SW, SE (negative).
    static let directions: [(Int, Int)] = [(0, 1), (1, 0), (1, 1), (-1, 1), (0, -1), (-1, 0), (-1, -1), (1, -1)]

    /// `rays[d * 64 + sq]`.
    static let rays: [UInt64] = {
        var out = [UInt64](repeating: 0, count: 8 * 64)
        for (d, (df, dr)) in directions.enumerated() {
            for sq in 0 ..< 64 {
                var f = sq & 7 + df, r = sq >> 3 + dr
                var bits: UInt64 = 0
                while (0 ..< 8).contains(f), (0 ..< 8).contains(r) {
                    bits |= 1 << UInt64(r * 8 + f)
                    f += df
                    r += dr
                }
                out[d * 64 + sq] = bits
            }
        }
        return out
    }()

    private static func jumps(_ sq: Int, _ deltas: [(Int, Int)]) -> UInt64 {
        var bits: UInt64 = 0
        for (df, dr) in deltas {
            let f = sq & 7 + df, r = sq >> 3 + dr
            if (0 ..< 8).contains(f), (0 ..< 8).contains(r) { bits |= 1 << UInt64(r * 8 + f) }
        }
        return bits
    }

    public static func knight(_ sq: Int) -> UInt64 { knightTable[sq] }
    public static func king(_ sq: Int) -> UInt64 { kingTable[sq] }
    public static func pawn(_ sq: Int, _ color: PieceColor) -> UInt64 { pawnTable[color.rawValue][sq] }

    @inline(__always)
    static func ray(_ d: Int, _ sq: Int, _ occupied: UInt64) -> UInt64 {
        let r = rays[d &* 64 &+ sq]
        let blockers = r & occupied
        guard blockers != 0 else { return r }
        let b = d < 4 ? blockers.trailingZeroBitCount : 63 - blockers.leadingZeroBitCount
        return r ^ rays[d &* 64 &+ b]
    }

    public static func rook(_ sq: Int, _ occupied: UInt64) -> UInt64 {
        ray(0, sq, occupied) | ray(1, sq, occupied) | ray(4, sq, occupied) | ray(5, sq, occupied)
    }

    public static func bishop(_ sq: Int, _ occupied: UInt64) -> UInt64 {
        ray(2, sq, occupied) | ray(3, sq, occupied) | ray(6, sq, occupied) | ray(7, sq, occupied)
    }

    /// Squares attacked by a piece of `kind` and `color` on `sq`.
    public static func of(_ kind: PieceKind, _ color: PieceColor, _ sq: Int, _ occupied: UInt64) -> UInt64 {
        switch kind {
        case .pawn: pawn(sq, color)
        case .knight: knight(sq)
        case .bishop: bishop(sq, occupied)
        case .rook: rook(sq, occupied)
        case .queen: rook(sq, occupied) | bishop(sq, occupied)
        case .king: king(sq)
        }
    }

    /// Chebyshev distance between two squares.
    @inlinable public static func distance(_ a: Int, _ b: Int) -> Int {
        max(abs(a & 7 - b & 7), abs(a >> 3 - b >> 3))
    }
}

extension UInt64 {
    /// Calls `body` with the index of each set bit, lowest first.
    @inline(__always)
    func forEachBit(_ body: (Int) -> Void) {
        var rest = self
        while rest != 0 {
            body(rest.trailingZeroBitCount)
            rest &= rest &- 1
        }
    }
}
