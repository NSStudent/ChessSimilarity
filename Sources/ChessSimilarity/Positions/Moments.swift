//
//  Moments.swift
//  ChessSimilarity
//

/// Why a ply was chosen as a moment of the game.
public enum MomentKind: String, Hashable, Sendable, CaseIterable {
    /// The end of the opening, around move 10–15.
    case openingEnd
    /// The middlegame, around move 25.
    case middlegame
    /// The first quiet position of the ending.
    case endingStart
}

/// A position chosen to represent a game in the index.
public struct Moment: Hashable, Sendable {
    public var kind: MomentKind
    public var ply: Int
}

/// Chooses 2–3 «moments» per game (end of the opening, middlegame
/// and ending), so the index holds about 3 documents per game instead of 80.
///
/// A moment is the first *quiet* ply at or after its target: the move that led to it
/// was not a capture and the side to move is not in check. That avoids indexing
/// the half-finished exchange between a capture and its recapture.
public struct MomentPolicy: Hashable, Sendable {
    /// Target ply of ``MomentKind/openingEnd``.
    public var openingEnd = 24
    /// Target ply of ``MomentKind/middlegame``.
    public var middlegame = 50
    /// How far past a target to look for a quiet ply before giving up.
    public var window = 8
    /// Moments closer than this to an earlier one are dropped.
    public var minimumGap = 10
    /// Include the first quiet position of the ending.
    public var includesEnding = true

    public init(openingEnd: Int = 24, middlegame: Int = 50, window: Int = 8, minimumGap: Int = 10, includesEnding: Bool = true) {
        self.openingEnd = openingEnd
        self.middlegame = middlegame
        self.window = window
        self.minimumGap = minimumGap
        self.includesEnding = includesEnding
    }

    /// The moments of a game, in ply order.
    public func moments(of line: GameLine) -> [Moment] {
        let positions = line.positions
        let captures = line.captures
        func isQuiet(_ i: Int) -> Bool { !captures[i] && !positions[i].isCheck }
        func quiet(from target: Int) -> Int? {
            guard target < positions.count else { return nil }
            for i in target ..< min(positions.count, target + window + 1) where isQuiet(i) { return i }
            return nil
        }
        var opening = quiet(from: openingEnd)
        var middle = quiet(from: middlegame)
        let ending = includesEnding
            ? positions.indices.first { $0 >= openingEnd && EndingPhase.isEnding(positions[$0]) && isQuiet($0) }
            : nil
        // The ending is the most telling moment: it wins over a nearby middlegame ply.
        if let e = ending, let m = middle, abs(e - m) < minimumGap || e < m { middle = nil }
        if let e = ending, let o = opening, e - o < minimumGap { opening = nil }
        if let m = middle, let o = opening, m - o < minimumGap { middle = nil }
        var out: [Moment] = []
        if let opening { out.append(Moment(kind: .openingEnd, ply: opening)) }
        if let middle { out.append(Moment(kind: .middlegame, ply: middle)) }
        if let ending { out.append(Moment(kind: .endingStart, ply: ending)) }
        // Short games keep their final position.
        if out.isEmpty, positions.count > 1 { out.append(Moment(kind: .openingEnd, ply: positions.count - 1)) }
        return out
    }
}

/// When a position counts as an ending.
public enum EndingPhase {
    /// No queens and at most 11 points of pieces per side (two rooks, rook and two minors…),
    /// or at most 9 points per side with queens (a queen alone). Kings and pawns don't count.
    public static func isEnding(_ p: SimilarityPosition) -> Bool {
        let w = officerValue(p, .white), b = officerValue(p, .black)
        if p[.white, .queen] == 0, p[.black, .queen] == 0 { return w <= 11 && b <= 11 }
        return w <= 9 && b <= 9
    }

    public static func officerValue(_ p: SimilarityPosition, _ color: PieceColor) -> Int {
        PieceKind.officers.reduce(0) { $0 + p[color, $1].nonzeroBitCount * $1.value }
    }
}
