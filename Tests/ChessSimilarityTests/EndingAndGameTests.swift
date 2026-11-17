//
//  EndingAndGameTests.swift
//  ChessSimilarityTests
//

@testable import ChessSimilarity
import Testing

struct EndingTests {
    // Rook endings and a queen ending, written by hand.
    static let rookPawnA = "8/8/3k4/8/3P4/3K4/8/r6R w"       // KRP v KR, d-pawn
    static let rookPawnB = "8/8/2k5/8/2P5/2K5/8/r6R w"       // KRP v KR, c-pawn, same pattern one file left
    static let rookPawnFar = "8/8/k7/8/7P/7K/8/r6R w"        // KRP v KR, h-pawn, kings far apart
    static let rookTwoPawns = "8/8/3k4/8/3P4/3K1P2/8/r6R w"  // KRPP v KR
    static let queens = "8/8/3k4/8/3P4/3K4/8/q6Q w"          // KQP v KQ

    @Test func featuresOfARookEnding() throws {
        let f = try EndingFeatures(fen: Self.rookPawnA)
        #expect(f.materialClass == "KRPvKR")
        #expect(f.pieceKey == "KRvKR")
        #expect(f.count(.white, .pawn) == 1)
        #expect(f.traits[1] == 1, "one white passed pawn")
        #expect(f.traits[4] == 3, "on the 4th rank (relative index 3)")
    }

    @Test func distanceProperties() throws {
        let d = EndingDistance.standard
        let a = try EndingFeatures(fen: Self.rookPawnA)
        let b = try EndingFeatures(fen: Self.rookPawnB)
        let far = try EndingFeatures(fen: Self.rookPawnFar)
        let two = try EndingFeatures(fen: Self.rookTwoPawns)
        let q = try EndingFeatures(fen: Self.queens)
        #expect(d(a, a) == 0)
        #expect(d(a, b) == d(b, a))
        #expect(d(a, b) < d(a, far))
        #expect(d(a, far) < d(a, two), "a pawn more is further than the same pawn elsewhere")
        #expect(d(a, two) < d(a, q), "a different piece is further than a pawn more")
        // Colours reversed: the same ending seen from the other side.
        #expect(d(a, a.colorsReversed) == 0)
        var strict = d
        strict.allowsSymmetries = false
        #expect(strict(a, a.colorsReversed) > 0)
        // Mirrored a↔h keeps every feature but the pawn squares.
        #expect(d(a, a.mirrored) == 0)
    }

    @Test func indexFindsTheSameEndingFirst() throws {
        var index = EndingIndex()
        let fens = [Self.rookPawnA, Self.rookPawnB, Self.rookPawnFar, Self.rookTwoPawns, Self.queens]
        for (i, fen) in fens.enumerated() {
            index.add(gameID: Int64(i), line: GameLine(positions: [try SimilarityPosition(fen: fen)]))
        }
        #expect(index.count == 5)
        let hits = index.search(try SimilarityPosition(fen: Self.rookPawnA), limit: 5)
        #expect(hits.map(\.gameID) == [0, 1, 2, 3], "same pieces only, nearest first")
        #expect(hits[0].distance == 0)
        let all = index.search(try SimilarityPosition(fen: Self.rookPawnA), limit: 5, candidates: .all)
        #expect(all.count == 5)
        #expect(all.last?.gameID == 4)
        // Reversed colours land in the same bucket.
        let reversed = try SimilarityPosition(fen: Self.rookPawnA).colorsReversed
        #expect(index.search(reversed, limit: 1).first?.gameID == 0)
    }

    @Test func gamesWithoutAnEnding() {
        var index = EndingIndex()
        let ply = index.add(gameID: 0, line: Fixtures.game("Paris").line)
        #expect(ply == nil)
    }
}

struct GameSimilarityTests {
    @Test func aGameIsMostSimilarToItself() {
        var index = GameSimilarityIndex()
        for (i, g) in Fixtures.games.enumerated() { index.add(gameID: Int64(i), line: g.line) }
        for (i, g) in Fixtures.games.enumerated() {
            let top = index.search(g.line, limit: 3).first
            #expect(top?.similarity == 1, "\(g.event)")
            // The QGD games are identical from ply 16 on: they may come first instead.
            if !g.event.contains("QGD") { #expect(top?.gameID == Int64(i), "\(g.event)") }
        }
    }

    @Test func transpositionsAreTheSameGame() {
        let hasher = MinHasher(hashCount: 64)
        let options = GameSetOptions.similarGames
        let a = hasher.signature(Fixtures.qgdD4.line, options: options)
        let b = hasher.signature(Fixtures.qgdC4.line, options: options)
        #expect(MinHasher.estimatedJaccard(a, b) == 1)
        // With every position the sets differ only in the first plies.
        let ea = GameSetOptions.nearDuplicates.elements(of: Fixtures.qgdD4.line)
        let eb = GameSetOptions.nearDuplicates.elements(of: Fixtures.qgdC4.line)
        let exact = MinHasher.jaccard(ea, eb)
        #expect(exact > 0.6 && exact < 1)
    }

    @Test func estimateIsCloseToTheExactJaccard() {
        let hasher = MinHasher(hashCount: 256)
        let lines = [Fixtures.qgdD4.line, Fixtures.qgdLonger.line, Fixtures.panov.line, Fixtures.caroKann.line]
        for x in lines {
            for y in lines {
                let ex = GameSetOptions.nearDuplicates.elements(of: x), ey = GameSetOptions.nearDuplicates.elements(of: y)
                let exact = MinHasher.jaccard(ex, ey)
                let estimate = MinHasher.estimatedJaccard(hasher.signature(ex), hasher.signature(ey))
                #expect(abs(exact - estimate) < 0.12, "exact \(exact) estimate \(estimate)")
            }
        }
    }

    @Test func nearDuplicatePairs() {
        var index = GameSimilarityIndex.nearDuplicates()
        for (i, g) in Fixtures.games.enumerated() { index.add(gameID: Int64(i), line: g.line) }
        let pairs = index.pairs(minimumSimilarity: 0.8)
        let d4 = Int64(Fixtures.games.firstIndex { $0.event.hasPrefix("Fixture: QGD Exchange, d4 order") }!)
        let longer = Int64(Fixtures.games.firstIndex { $0.event.hasPrefix("Fixture: QGD Exchange, d4 order, longer") }!)
        #expect(pairs.contains { $0.first == min(d4, longer) && $0.second == max(d4, longer) })
        #expect(pairs.allSatisfy { $0.similarity >= 0.8 })
        // No pair of unrelated openings.
        let qgd = Set(Fixtures.games.indices.filter { Fixtures.games[$0].event.contains("QGD") }.map(Int64.init))
        #expect(pairs.allSatisfy { qgd.contains($0.first) && qgd.contains($0.second) })
    }

    @Test func lshCurve() {
        let lsh = LSHConfiguration.similarGames
        #expect(lsh.hashCount == 32)
        #expect(abs(lsh.threshold - 0.25) < 1e-9)
        #expect(lsh.candidateProbability(0.8) > 0.99)
        #expect(lsh.candidateProbability(0.05) < 0.05)
        #expect(LSHConfiguration.nearDuplicates.candidateProbability(0.3) < 0.07)
    }
}
