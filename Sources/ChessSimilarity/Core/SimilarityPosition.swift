//
//  SimilarityPosition.swift
//  ChessSimilarity
//

import FischerCore

/// Errors when reading a position or a line of moves.
public enum SimilarityInputError: Error, Equatable, Sendable {
    case invalidFEN(String)
    /// The move at this zero-based index has no piece of the side to move on its start square.
    case invalidMove(index: Int)
    /// SAN that FischerCore could not resolve at this zero-based index.
    case unresolvedSAN(index: Int, san: String)
}

/// The piece placement and side to move, as 12 bitboards.
///
/// Lane `color * 6 + kind` (``PieceColor`` and ``PieceKind`` raw values):
/// white pawn 0 … white king 5, black pawn 6 … black king 11. Castling rights
/// and the en passant square are left out on purpose: similarity ignores them,
/// and transpositions then always get the same key.
public struct SimilarityPosition: Hashable, Sendable {
    public var lanes: SIMD16<UInt64>
    public var sideToMove: PieceColor

    public init(lanes: SIMD16<UInt64>, sideToMove: PieceColor) {
        self.lanes = lanes
        self.sideToMove = sideToMove
    }

    /// The standard start position.
    public static let start: SimilarityPosition = {
        var l = SIMD16<UInt64>(repeating: 0)
        l[0] = 0xFF00
        l[1] = 0x42
        l[2] = 0x24
        l[3] = 0x81
        l[4] = 0x08
        l[5] = 0x10
        l[6] = 0x00FF_0000_0000_0000
        l[7] = 0x4200_0000_0000_0000
        l[8] = 0x2400_0000_0000_0000
        l[9] = 0x8100_0000_0000_0000
        l[10] = 0x0800_0000_0000_0000
        l[11] = 0x1000_0000_0000_0000
        return SimilarityPosition(lanes: l, sideToMove: .white)
    }()

    /// Reads the placement and side to move of a FEN (the placement field alone means white to move).
    public init(fen: String) throws {
        let fields = fen.split(separator: " ", omittingEmptySubsequences: true)
        guard let placement = fields.first else { throw SimilarityInputError.invalidFEN(fen) }
        var l = SIMD16<UInt64>(repeating: 0)
        var rank = 7, file = 0
        for c in placement.utf8 {
            switch c {
            case UInt8(ascii: "/"):
                guard file == 8, rank > 0 else { throw SimilarityInputError.invalidFEN(fen) }
                rank -= 1
                file = 0
            case UInt8(ascii: "1") ... UInt8(ascii: "8"):
                file += Int(c - UInt8(ascii: "0"))
                guard file <= 8 else { throw SimilarityInputError.invalidFEN(fen) }
            default:
                guard file < 8, let lane = Self.lane(fenLetter: c) else { throw SimilarityInputError.invalidFEN(fen) }
                l[lane] |= 1 << UInt64(rank * 8 + file)
                file += 1
            }
        }
        guard rank == 0, file == 8 else { throw SimilarityInputError.invalidFEN(fen) }
        guard l[5].nonzeroBitCount == 1, l[11].nonzeroBitCount == 1 else { throw SimilarityInputError.invalidFEN(fen) }
        lanes = l
        sideToMove = fields.count > 1 && fields[1] == "b" ? .black : .white
    }

    /// Converts a FischerCore position.
    public init(_ position: Position) {
        self.init(board: position.board, sideToMove: position.playerTurn == .white ? .white : .black)
    }

    /// Converts a FischerCore board.
    public init(board: Board, sideToMove: PieceColor) {
        var l = SIMD16<UInt64>(repeating: 0)
        for color in PieceColor.allCases {
            let fc: PlayerColor = color == .white ? .white : .black
            for kind in PieceKind.allCases {
                var raw: UInt64 = 0
                for square in board.bitboard(for: Piece(kind: Self.fischerKind(kind), color: fc)) {
                    raw |= 1 << UInt64(square.rawValue)
                }
                l[color.rawValue * 6 + kind.rawValue] = raw
            }
        }
        lanes = l
        self.sideToMove = sideToMove
    }

    static func fischerKind(_ kind: PieceKind) -> Piece.Kind {
        switch kind {
        case .pawn: .pawn
        case .knight: .knight
        case .bishop: .bishop
        case .rook: .rook
        case .queen: .queen
        case .king: .king
        }
    }

    static func lane(fenLetter c: UInt8) -> Int? {
        switch c {
        case UInt8(ascii: "P"): 0
        case UInt8(ascii: "N"): 1
        case UInt8(ascii: "B"): 2
        case UInt8(ascii: "R"): 3
        case UInt8(ascii: "Q"): 4
        case UInt8(ascii: "K"): 5
        case UInt8(ascii: "p"): 6
        case UInt8(ascii: "n"): 7
        case UInt8(ascii: "b"): 8
        case UInt8(ascii: "r"): 9
        case UInt8(ascii: "q"): 10
        case UInt8(ascii: "k"): 11
        default: nil
        }
    }

    // MARK: Access

    @inlinable
    public subscript(color: PieceColor, kind: PieceKind) -> UInt64 {
        get { lanes[color.rawValue &* 6 &+ kind.rawValue] }
        set { lanes[color.rawValue &* 6 &+ kind.rawValue] = newValue }
    }

    /// All pieces of one side.
    @inlinable
    public func occupied(_ color: PieceColor) -> UInt64 {
        let o = color.rawValue &* 6
        return lanes[o] | lanes[o + 1] | lanes[o + 2] | lanes[o + 3] | lanes[o + 4] | lanes[o + 5]
    }

    @inlinable public var occupied: UInt64 { occupied(.white) | occupied(.black) }

    @inlinable public var pieceCount: Int { occupied.nonzeroBitCount }

    /// The piece on `square`, if any.
    public func piece(at square: Int) -> (color: PieceColor, kind: PieceKind)? {
        let bit: UInt64 = 1 << UInt64(square)
        for lane in 0 ..< 12 where lanes[lane] & bit != 0 {
            return (lane < 6 ? .white : .black, PieceKind(rawValue: lane % 6)!)
        }
        return nil
    }

    public func kingSquare(_ color: PieceColor) -> Int {
        let k = self[color, .king]
        return k == 0 ? 0 : k.trailingZeroBitCount
    }

    /// Every square attacked by `color`.
    public func attacks(by color: PieceColor) -> UInt64 {
        let occ = occupied
        var out: UInt64 = 0
        for kind in PieceKind.allCases {
            self[color, kind].forEachBit { out |= Attacks.of(kind, color, $0, occ) }
        }
        return out
    }

    /// Pieces of `color` that attack `square`.
    public func attackers(of square: Int, by color: PieceColor) -> UInt64 {
        let occ = occupied
        let them = color.opponent
        var out = Attacks.pawn(square, them) & self[color, .pawn]
        out |= Attacks.knight(square) & self[color, .knight]
        out |= Attacks.king(square) & self[color, .king]
        out |= Attacks.bishop(square, occ) & (self[color, .bishop] | self[color, .queen])
        out |= Attacks.rook(square, occ) & (self[color, .rook] | self[color, .queen])
        return out
    }

    public var isCheck: Bool {
        self[sideToMove, .king] != 0 && attackers(of: kingSquare(sideToMove), by: sideToMove.opponent) != 0
    }

    /// The placement field of the FEN followed by the side to move.
    public var fen: String {
        var out = ""
        for rank in stride(from: 7, through: 0, by: -1) {
            var empty = 0
            for file in 0 ..< 8 {
                if let p = piece(at: rank * 8 + file) {
                    if empty > 0 { out += String(empty); empty = 0 }
                    let c = p.kind.letter
                    out.append(p.color == .white ? Character(c.uppercased()) : c)
                } else {
                    empty += 1
                }
            }
            if empty > 0 { out += String(empty) }
            if rank > 0 { out += "/" }
        }
        return out + (sideToMove == .white ? " w" : " b")
    }

    // MARK: Moves

    /// Plays a move given by its squares. Castling (the king moves two files),
    /// en passant and promotion are recognised from the board. Legality is not checked.
    public mutating func play(from: Int, to: Int, promotion: PieceKind? = nil) throws {
        let us = sideToMove, them = us.opponent
        let fromBit: UInt64 = 1 << UInt64(from), toBit: UInt64 = 1 << UInt64(to)
        guard let kind = PieceKind.allCases.first(where: { self[us, $0] & fromBit != 0 }) else {
            throw SimilarityInputError.invalidMove(index: 0)
        }
        // Chess960-style castling: the king "captures" its own rook.
        if kind == .king, self[us, .rook] & toBit != 0 {
            let kingside = to > from
            let rank = from & ~7
            self[us, .king] = 1 << UInt64(rank + (kingside ? 6 : 2))
            self[us, .rook] = (self[us, .rook] & ~toBit) | 1 << UInt64(rank + (kingside ? 5 : 3))
            sideToMove = them
            return
        }
        let wasEmpty = occupied & toBit == 0
        for k in PieceKind.allCases { self[them, k] &= ~toBit }
        self[us, kind] &= ~fromBit
        if kind == .pawn, wasEmpty, (to - from) % 8 != 0 {
            // En passant: the captured pawn is beside the start square.
            let captured = to + (us == .white ? -8 : 8)
            self[them, .pawn] &= ~(1 << UInt64(captured))
        }
        if kind == .pawn, to >> 3 == (us == .white ? 7 : 0) {
            self[us, promotion ?? .queen] |= toBit
        } else {
            self[us, kind] |= toBit
        }
        if kind == .king, abs(to - from) == 2 {
            let rank = from & ~7
            let (rookFrom, rookTo) = to > from ? (rank + 7, rank + 5) : (rank, rank + 3)
            self[us, .rook] = (self[us, .rook] & ~(1 << UInt64(rookFrom))) | 1 << UInt64(rookTo)
        }
        sideToMove = them
    }

    /// Plays a FischerCore move.
    public mutating func play(_ move: ResolvedMove) throws {
        try play(from: move.move.start.rawValue, to: move.move.end.rawValue, promotion: move.promotion.map(Self.kind))
    }

    static func kind(_ p: PromotionPiece) -> PieceKind {
        switch p {
        case .queen: .queen
        case .rook: .rook
        case .bishop: .bishop
        case .knight: .knight
        }
    }

    /// The same position with colours swapped and the board flipped vertically.
    public var colorsReversed: SimilarityPosition {
        var l = SIMD16<UInt64>(repeating: 0)
        for i in 0 ..< 6 {
            l[i] = lanes[i + 6].byteSwapped
            l[i + 6] = lanes[i].byteSwapped
        }
        return SimilarityPosition(lanes: l, sideToMove: sideToMove.opponent)
    }
}
