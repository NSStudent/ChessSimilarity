//
//  Pieces.swift
//  ChessSimilarity
//

/// The two sides.
public enum PieceColor: Int, Hashable, Sendable, CaseIterable {
    case white = 0
    case black = 1

    @inlinable public var opponent: PieceColor { self == .white ? .black : .white }

    /// `w` or `b`, used in the term strings.
    public var letter: Character { self == .white ? "w" : "b" }
}

/// The six piece kinds, in the order of ``SimilarityPosition`` lanes.
public enum PieceKind: Int, Hashable, Sendable, CaseIterable {
    case pawn = 0
    case knight
    case bishop
    case rook
    case queen
    case king

    /// `p n b r q k`, used in the term strings.
    public var letter: Character {
        switch self {
        case .pawn: "p"
        case .knight: "n"
        case .bishop: "b"
        case .rook: "r"
        case .queen: "q"
        case .king: "k"
        }
    }

    /// Usual material value (pawn 1, minor 3, rook 5, queen 9, king 0).
    @inlinable public var value: Int {
        switch self {
        case .pawn: 1
        case .knight, .bishop: 3
        case .rook: 5
        case .queen: 9
        case .king: 0
        }
    }

    /// The non-pawn, non-king kinds.
    public static let officers: [PieceKind] = [.knight, .bishop, .rook, .queen]
}

/// Square helpers. Squares are `0...63` with a1 = 0, b1 = 1, …, h8 = 63, as in
/// FischerCore and ChessPawnStructures.
public enum SquareName {
    static let files = Array("abcdefgh")

    /// `e4` for 28.
    public static func name(_ square: Int) -> String {
        String(files[square & 7]) + String((square >> 3) + 1)
    }

    /// 28 for `e4`.
    public static func index(_ name: some StringProtocol) -> Int? {
        let u = Array(name.utf8)
        guard u.count == 2, (97 ... 104).contains(u[0]), (49 ... 56).contains(u[1]) else { return nil }
        return Int(u[0] - 97) + Int(u[1] - 49) * 8
    }

    /// Precomputed names, faster than ``name(_:)`` in the term builder.
    static let names: [String] = (0 ..< 64).map { name($0) }
}
