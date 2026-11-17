//
//  PositionTerms.swift
//  ChessSimilarity
//

import ChessPawnStructures

/// The columns of a position document. Each term belongs to exactly one column
/// (its prefix says which), and each column holds each term at most once, so a
/// SQLite FTS5 table and ``InMemoryPositionIndex`` score the same way.
public enum TermColumn: Int, CaseIterable, Sendable {
    /// Piece on square: `wnf3`, `bpe5` (colour, piece, square).
    case pieces
    /// Squares a piece reaches in one move, «term propagation» of Ganguly et al.: `rwnd5`.
    case reach
    /// Attacks on enemy pieces and defence of own pieces: `xwnf3bpe5`, `dwbe2wnf3`.
    case links
    /// Pawn structure: catalog kinds (`s04`, `s04r`) and traits (`wisod`, `wpasc`, `opne`).
    case pawns
    /// King safety: flank, pawn shield, open files and attackers near the king.
    case king
    /// Material counts and balance, bishops, mobility classes, side to move.
    case balance
    /// One exact material token (`m` + counts), used as a hard filter. Weight 0 by default.
    case material

    /// FTS5 column name.
    public var name: String {
        switch self {
        case .pieces: "pieces"
        case .reach: "reach"
        case .links: "links"
        case .pawns: "pawns"
        case .king: "king"
        case .balance: "balance"
        case .material: "material"
        }
    }
}

/// A position as a document of terms, ready for BM25.
public struct PositionTerms: Hashable, Sendable {
    /// Terms of each ``TermColumn``, without repeats inside a column.
    public var columns: [[String]]

    public subscript(column: TermColumn) -> [String] { columns[column.rawValue] }

    /// The exact material token (the only term of ``TermColumn/material``).
    public var materialKey: String { columns[TermColumn.material.rawValue].first ?? "" }

    /// All terms of all columns.
    public var allTerms: [String] { columns.flatMap { $0 } }

    public var count: Int { columns.reduce(0) { $0 + $1.count } }

    /// Each column as one space-separated string, in ``TermColumn`` order, for an FTS5 `INSERT`.
    public var columnTexts: [String] { columns.map { $0.joined(separator: " ") } }

    public init(columns: [[String]]) {
        precondition(columns.count == TermColumn.allCases.count)
        self.columns = columns
    }

    /// Builds the terms of `position`.
    public init(_ position: SimilarityPosition, options: TermOptions = TermOptions()) {
        var builder = TermBuilder(position, options: options)
        columns = builder.build()
    }

    /// Builds the terms of a FEN.
    public init(fen: String, options: TermOptions = TermOptions()) throws {
        self.init(try SimilarityPosition(fen: fen), options: options)
    }

    /// The material token of a position with the pawn counts changed by `whitePawns` and `blackPawns`;
    /// `nil` when a count would leave `0...8`. Used to widen the material filter.
    public static func materialKey(_ p: SimilarityPosition, whitePawns: Int = 0, blackPawns: Int = 0) -> String? {
        var out = "m"
        for color in PieceColor.allCases {
            for kind in [PieceKind.queen, .rook, .bishop, .knight, .pawn] {
                var n = p[color, kind].nonzeroBitCount
                if kind == .pawn { n += color == .white ? whitePawns : blackPawns }
                guard (0 ... 9).contains(n) else { return nil }
                out.append(Character(String(n)))
            }
        }
        return out
    }
}

/// Which terms to build.
public struct TermOptions: Hashable, Sendable {
    public var reach = true
    public var links = true
    /// Include pawns among the attackers in ``TermColumn/links`` (a pawn attacking a piece is a strong motif).
    public var pawnLinks = true

    public init(reach: Bool = true, links: Bool = true, pawnLinks: Bool = true) {
        self.reach = reach
        self.links = links
        self.pawnLinks = pawnLinks
    }
}

struct TermBuilder {
    let p: SimilarityPosition
    let options: TermOptions
    let occ: UInt64
    var columns = [[String]](repeating: [], count: TermColumn.allCases.count)

    init(_ p: SimilarityPosition, options: TermOptions) {
        self.p = p
        self.options = options
        occ = p.occupied
    }

    static let pieceTokens: [[String]] = (0 ..< 12).map { lane in
        let color: Character = lane < 6 ? "w" : "b"
        let kind = PieceKind(rawValue: lane % 6)!.letter
        return (0 ..< 64).map { String(color) + String(kind) + SquareName.names[$0] }
    }

    static let names = SquareName.names

    mutating func build() -> [[String]] {
        var attacked = [UInt64](repeating: 0, count: 2)
        var mobility = [[Int]](repeating: [Int](repeating: 0, count: 6), count: 2)
        // Pieces, reach and links.
        for lane in 0 ..< 12 {
            let color: PieceColor = lane < 6 ? .white : .black
            let kind = PieceKind(rawValue: lane % 6)!
            let own = p.occupied(color), theirs = p.occupied(color.opponent)
            p.lanes[lane].forEachBit { sq in
                let token = Self.pieceTokens[lane][sq]
                columns[TermColumn.pieces.rawValue].append(token)
                let att = Attacks.of(kind, color, sq, occ)
                attacked[color.rawValue] |= att
                if kind != .pawn {
                    let moves = att & ~own
                    mobility[color.rawValue][kind.rawValue] += moves.nonzeroBitCount
                    if options.reach {
                        let prefix = "r" + token.prefix(2)
                        moves.forEachBit { columns[TermColumn.reach.rawValue].append(prefix + Self.names[$0]) }
                    }
                }
                if options.links, kind != .pawn || options.pawnLinks {
                    (att & theirs).forEachBit { target in
                        columns[TermColumn.links.rawValue].append("x" + token + pieceToken(at: target))
                    }
                    (att & own & ~p[color, .king]).forEachBit { target in
                        columns[TermColumn.links.rawValue].append("d" + token + pieceToken(at: target))
                    }
                }
            }
        }
        pawnTerms()
        kingTerms(attacked: attacked)
        balanceTerms(mobility: mobility)
        columns[TermColumn.material.rawValue] = [PositionTerms.materialKey(p) ?? "m"]
        for i in columns.indices where i == TermColumn.reach.rawValue || i == TermColumn.links.rawValue {
            columns[i] = Self.unique(columns[i])
        }
        return columns
    }

    func pieceToken(at sq: Int) -> String {
        let bit: UInt64 = 1 << UInt64(sq)
        for lane in 0 ..< 12 where p.lanes[lane] & bit != 0 { return Self.pieceTokens[lane][sq] }
        return Self.names[sq]
    }

    static func unique(_ terms: [String]) -> [String] {
        var seen = Set<String>(minimumCapacity: terms.count)
        return terms.filter { seen.insert($0).inserted }
    }

    static let fileLetters = Array("abcdefgh")

    mutating func pawnTerms() {
        let s = PawnStructure(white: p[.white, .pawn], black: p[.black, .pawn])
        var out: [String] = []
        for id in StructureCatalog.mask(s) {
            out.append(String(format: "s%02d", id.kind.rawValue) + (id.reversed ? "r" : ""))
        }
        let t = PawnTraits(s)
        func files(_ bits: UInt64) -> UInt8 {
            var f: UInt8 = 0
            bits.forEachBit { f |= 1 << UInt8($0 & 7) }
            return f
        }
        func add(_ prefix: String, _ mask: UInt8) {
            for f in 0 ..< 8 where mask & (1 << UInt8(f)) != 0 { out.append(prefix + String(Self.fileLetters[f])) }
        }
        for (c, st) in [("w", t.white), ("b", t.black)] {
            add(c + "iso", files(st.isolated))
            add(c + "dbl", files(st.doubled))
            add(c + "pas", files(st.passed))
            add(c + "bck", files(st.backward))
            add(c + "hng", files(st.hanging))
            add(c + "so", st.semiOpenFiles)
            out.append(c + "isl" + String(min(st.islands, 4)))
            out.append(c + "pqs" + String(min(st.queenside, 5)))
            out.append(c + "pks" + String(min(st.kingside, 5)))
        }
        add("opn", t.openFiles)
        for (flank, name) in [(Flank.queenside, "q"), (.kingside, "k")] {
            switch s.majority(on: flank) {
            case .white?: out.append("mj" + name + "w")
            case .black?: out.append("mj" + name + "b")
            case nil: out.append("mj" + name + "0")
            }
        }
        columns[TermColumn.pawns.rawValue] = out
    }

    mutating func kingTerms(attacked: [UInt64]) {
        var out: [String] = []
        let pawnFiles = [p[.white, .pawn], p[.black, .pawn]]
        for color in PieceColor.allCases {
            let c = String(color.letter)
            let k = p[color, .king]
            guard k != 0 else { continue }
            let sq = k.trailingZeroBitCount
            let file = sq & 7, rank = sq >> 3
            let flank = file <= 2 ? "q" : (file >= 5 ? "k" : "c")
            out.append(c + "kf" + flank)
            let relRank = color == .white ? rank : 7 - rank
            out.append(c + "kr" + String(min(relRank, 3)))
            // Shield: own pawns on the king's file and its neighbours, one or two ranks ahead.
            var zoneFiles: UInt64 = 0
            for f in max(0, file - 1) ... min(7, file + 1) { zoneFiles |= Attacks.file(f) }
            var ahead: UInt64 = 0
            for dr in 1 ... 2 {
                let r = color == .white ? rank + dr : rank - dr
                if (0 ..< 8).contains(r) { ahead |= Attacks.rank(r) }
            }
            let shield = (p[color, .pawn] & zoneFiles & ahead).nonzeroBitCount
            out.append(c + "sh" + String(min(shield, 3)))
            // Files near the king without own pawns.
            var open = 0
            for f in max(0, file - 1) ... min(7, file + 1) where pawnFiles[color.rawValue] & Attacks.file(f) == 0 { open += 1 }
            out.append(c + "ko" + String(open))
            // Enemy pressure on the king zone.
            let zone = Attacks.king(sq) | k
            let hit = (attacked[color.opponent.rawValue] & zone).nonzeroBitCount
            out.append(c + "kz" + String(min(hit, 4)))
            var attackers = 0
            for kind in PieceKind.officers {
                p[color.opponent, kind].forEachBit { from in
                    if Attacks.of(kind, color.opponent, from, occ) & (zone | Attacks.king(sq).expandedKingZone) != 0 {
                        attackers += 1
                    }
                }
            }
            out.append(c + "ka" + String(min(attackers, 3)))
        }
        if p.isCheck { out.append("chk") }
        columns[TermColumn.king.rawValue] = out
    }

    mutating func balanceTerms(mobility: [[Int]]) {
        var out: [String] = []
        var value = [0, 0]
        for color in PieceColor.allCases {
            let c = String(color.letter)
            for kind in [PieceKind.queen, .rook, .bishop, .knight, .pawn] {
                let n = p[color, kind].nonzeroBitCount
                out.append("c" + c + String(kind.letter) + String(min(n, 9)))
                value[color.rawValue] += n * kind.value
            }
            let bishops = p[color, .bishop]
            if bishops & Self.light != 0, bishops & Self.dark != 0 { out.append(c + "bpair") }
            let officers = PieceKind.officers.reduce(0) { $0 + p[color, $1].nonzeroBitCount * $1.value }
            out.append(c + "off" + String(min(officers / 5, 8)))
            // Mobility classes: total, and per piece kind present.
            let total = mobility[color.rawValue].reduce(0, +)
            out.append(c + "mob" + String(min(total / 10, 6)))
            for kind in PieceKind.officers {
                let n = p[color, kind].nonzeroBitCount
                guard n > 0 else { continue }
                let avg = mobility[color.rawValue][kind.rawValue] / n
                out.append(c + "mob" + String(kind.letter) + String(min(avg / 3, 4)))
            }
        }
        let diff = value[0] - value[1]
        let bucket = diff == 0 ? "0" : (diff > 0 ? "w" : "b") + String(min(abs(diff), 3))
        out.append("bal" + bucket)
        let wb = p[.white, .bishop], bb = p[.black, .bishop]
        if wb.nonzeroBitCount == 1, bb.nonzeroBitCount == 1 {
            out.append((wb & Self.light != 0) == (bb & Self.light != 0) ? "scb" : "ocb")
        }
        if p[.white, .queen] == 0, p[.black, .queen] == 0 { out.append("noq") }
        out.append(p.sideToMove == .white ? "stmw" : "stmb")
        columns[TermColumn.balance.rawValue] = out
    }

    static let light: UInt64 = 0x55AA_55AA_55AA_55AA
    static let dark: UInt64 = ~light
}

extension UInt64 {
    /// The king zone grown by one square in every direction.
    var expandedKingZone: UInt64 {
        var out = self
        forEachBit { out |= Attacks.king($0) }
        return out
    }
}
