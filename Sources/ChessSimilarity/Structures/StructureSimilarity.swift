//
//  StructureSimilarity.swift
//  ChessSimilarity
//

import ChessPawnStructures

/// A catalog structure close to a concrete one.
public struct CatalogMatch: Hashable, Sendable {
    public var id: StructureID
    /// 0 when the structure meets the catalog rule and its «typical» squares; see ``PatternDistance``.
    public var distance: Double
    /// The catalog rule is met (the typical squares may still be missing).
    public var matches: Bool
}

/// How far a concrete structure is from a catalog rule (E6, phase 1).
///
/// The rule of each catalog structure is a ``StructurePattern``: required squares, groups
/// of alternatives and files that must be empty or occupied. The cost counts what it takes
/// to meet the rule, in the units of the Hamming distance of ``StructureDistance``:
///
/// | Unmet part of the rule | Cost |
/// |---|--:|
/// | Required square, with an own pawn on the same file | 1 (the pawn is on another rank) |
/// | Required square, no own pawn on that file | 2 |
/// | Group of alternatives | the cheapest square of the group |
/// | Pawn on a file that must be empty | 1.5 per pawn |
/// | File that must have a pawn | 2 |
/// | Queenside majority rule | 3 |
/// | Typical square (not required) | 0.25 |
public struct PatternDistance: Hashable, Sendable {
    public var sameFile = 1.0
    public var otherFile = 2.0
    public var pawnOnEmptyFile = 1.5
    public var missingFile = 2.0
    public var majority = 3.0
    public var typical = 0.25

    public init() {}

    func squareCost(_ square: UInt64, _ pawns: UInt64) -> Double {
        let file = Attacks.file(square.trailingZeroBitCount & 7)
        return pawns & file != 0 ? sameFile : otherFile
    }

    func groupCost(_ group: UInt64, _ pawns: UInt64) -> Double {
        guard group != 0, group & pawns == 0 else { return 0 }
        var best = Double.infinity
        group.forEachBit { best = min(best, squareCost(1 << UInt64($0), pawns)) }
        return best
    }

    /// Cost of one side's rule.
    public func cost(_ p: SidePattern, _ pawns: UInt64) -> Double {
        var d = 0.0
        (p.required & ~pawns).forEachBit { d += squareCost(1 << UInt64($0), pawns) }
        d += groupCost(p.alternative0, pawns) + groupCost(p.alternative1, pawns)
        for f in 0 ..< 8 {
            let fileMask = Attacks.file(f)
            if p.emptyFiles & (1 << UInt8(f)) != 0 { d += pawnOnEmptyFile * Double((pawns & fileMask).nonzeroBitCount) }
            if p.occupiedFiles & (1 << UInt8(f)) != 0, pawns & fileMask == 0 { d += missingFile }
        }
        return d
    }

    /// Cost of the «typical» squares of a side.
    func typicalCost(_ p: SidePattern, _ pawns: UInt64) -> Double {
        var missing = (p.required & ~pawns).nonzeroBitCount
        for g in [p.alternative0, p.alternative1] where g != 0 && g & pawns == 0 { missing += 1 }
        return typical * Double(missing)
    }

    /// Distance from `s` to a catalog structure in the given orientation.
    public func distance(_ s: PawnStructure, to definition: StructureDefinition, reversed: Bool) -> (distance: Double, matches: Bool) {
        let t = reversed ? s.colorsReversed : s
        var d: Double
        switch definition.condition {
        case let .pattern(p):
            d = cost(p.white, t.white) + cost(p.black, t.black)
        case .queensideMajority:
            d = definition.matches(t) ? 0 : majority
        }
        let matches = d == 0
        d += typicalCost(definition.typical.white, t.white) + typicalCost(definition.typical.black, t.black)
        return (d, matches)
    }
}

/// The weights of the piece motifs that ChessBase cites for «similar structures»
/// («Similar structures»), added to ``StructureDistance`` when whole positions are compared.
public struct StructureContextWeights: Hashable, Sendable {
    /// Per side, when one position has a rook on an open or half-open file and the other not.
    public var rookOnOpenFile = 1.0
    /// When the kings are on the same flank in one position and not in the other.
    public var kingsOnSameFlank = 1.5
    /// When one position has opposite-coloured bishops and the other not.
    public var oppositeBishops = 1.5

    public init() {}
}

/// The piece motifs of a position that matter for structure similarity.
public struct StructureContext: Hashable, Sendable {
    public var whiteRookOnOpenFile: Bool
    public var blackRookOnOpenFile: Bool
    public var kingsOnSameFlank: Bool
    public var oppositeBishops: Bool

    public init(_ p: SimilarityPosition) {
        let wp = p[.white, .pawn], bp = p[.black, .pawn]
        func rookOnFile(_ color: PieceColor) -> Bool {
            let own = color == .white ? wp : bp
            var found = false
            p[color, .rook].forEachBit { if own & Attacks.file($0 & 7) == 0 { found = true } }
            return found
        }
        whiteRookOnOpenFile = rookOnFile(.white)
        blackRookOnOpenFile = rookOnFile(.black)
        func flank(_ sq: Int) -> Int { sq & 7 <= 2 ? 0 : (sq & 7 >= 5 ? 2 : 1) }
        kingsOnSameFlank = flank(p.kingSquare(.white)) == flank(p.kingSquare(.black))
        let light: UInt64 = 0x55AA_55AA_55AA_55AA
        let wb = p[.white, .bishop], bb = p[.black, .bishop]
        oppositeBishops = wb.nonzeroBitCount == 1 && bb.nonzeroBitCount == 1 && (wb & light != 0) != (bb & light != 0)
    }
}

/// Similar pawn structures, by rules: the nearest catalog structures (ChessPawnStructures)
/// and the nearest concrete structures with ``StructureDistance``.
public struct StructureSimilarity: Sendable {
    public var distance: StructureDistance
    public var pattern: PatternDistance
    public var context: StructureContextWeights

    public init(distance: StructureDistance = StructureDistance(), pattern: PatternDistance = PatternDistance(),
                context: StructureContextWeights = StructureContextWeights()) {
        self.distance = distance
        self.pattern = pattern
        self.context = context
    }

    /// The pawn structure of a position.
    public static func structure(_ p: SimilarityPosition) -> PawnStructure {
        PawnStructure(white: p[.white, .pawn], black: p[.black, .pawn])
    }

    /// The `limit` nearest catalog structures, in both orientations, nearest first.
    /// Ties go to the book structures, then to the more specific rule, then to the catalog order.
    public func nearestCatalog(_ s: PawnStructure, limit: Int = 3, includesGeneric: Bool = false) -> [CatalogMatch] {
        var out: [CatalogMatch] = []
        for definition in StructureCatalog.definitions where includesGeneric || !definition.kind.isGeneric {
            for reversed in [false, true] {
                let (d, m) = pattern.distance(s, to: definition, reversed: reversed)
                out.append(CatalogMatch(id: StructureID(definition.kind, reversed: reversed), distance: d, matches: m))
            }
        }
        out.sort {
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            let a = $0.id.kind.definition, b = $1.id.kind.definition
            if a.kind.isGeneric != b.kind.isGeneric { return !a.kind.isGeneric }
            if a.specificity != b.specificity { return a.specificity > b.specificity }
            return $0.id < $1.id
        }
        return Array(out.prefix(limit))
    }

    public func nearestCatalog(_ p: SimilarityPosition, limit: Int = 3, includesGeneric: Bool = false) -> [CatalogMatch] {
        nearestCatalog(Self.structure(p), limit: limit, includesGeneric: includesGeneric)
    }

    /// Structure distance plus the piece motifs (rook on an open file, kings' flanks, opposite bishops).
    public func distance(_ a: SimilarityPosition, _ b: SimilarityPosition) -> Double {
        var d = distance.distance(Self.structure(a), Self.structure(b))
        let ca = StructureContext(a), cb = StructureContext(b)
        if ca.whiteRookOnOpenFile != cb.whiteRookOnOpenFile { d += context.rookOnOpenFile }
        if ca.blackRookOnOpenFile != cb.blackRookOnOpenFile { d += context.rookOnOpenFile }
        if ca.kingsOnSameFlank != cb.kingsOnSameFlank { d += context.kingsOnSameFlank }
        if ca.oppositeBishops != cb.oppositeBishops { d += context.oppositeBishops }
        return d
    }
}
