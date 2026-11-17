//
//  StructureTests.swift
//  ChessSimilarityTests
//

import ChessPawnStructures
@testable import ChessSimilarity
import Testing

struct StructureTests {
    let similarity = StructureSimilarity()

    @Test func carlsbadIsNearestToItself() {
        let s = StructureSimilarity.structure(Fixtures.qgdD4.line.positions.last!)
        let top = similarity.nearestCatalog(s, limit: 3)
        #expect(top.first?.id == StructureID(.carlsbad))
        #expect(top.first?.matches == true)
    }

    @Test func caroKannExchangeIsTheReversedCarlsbad() {
        let s = StructureSimilarity.structure(Fixtures.caroKann.line.positions.last!)
        let top = similarity.nearestCatalog(s, limit: 3)
        #expect(top.first?.id == StructureID(.carlsbad, reversed: true))
        #expect(top.first?.matches == true)
    }

    @Test func panovGivesAnIsolatedQueenPawn() {
        let s = StructureSimilarity.structure(Fixtures.panov.line.positions.last!)
        let top = similarity.nearestCatalog(s, limit: 3)
        #expect(top.first?.id == StructureID(.isolatedQueenPawn))
    }

    @Test func oneStepFromACatalogStructure() throws {
        // Carlsbad, but White's d-pawn has not reached d4 yet: one pawn on the right file, wrong rank.
        let near = try #require(PawnStructure(fen: "8/pp3ppp/2p5/3p4/8/3PP3/PP3PPP/8 w - - 0 1"))
        let top = similarity.nearestCatalog(near, limit: 64)
        let carlsbad = try #require(top.first { $0.id == StructureID(.carlsbad) })
        #expect(!carlsbad.matches)
        #expect(carlsbad.distance >= 1 && carlsbad.distance < 2)
    }

    @Test func distanceIsZeroOnlyForTheSameStructure() {
        let positions = Fixtures.games.flatMap(\.line.positions)
        for (a, b) in zip(positions, positions.dropFirst(3)) {
            let sa = StructureSimilarity.structure(a), sb = StructureSimilarity.structure(b)
            #expect((similarity.distance.distance(sa, sb) == 0) == (sa == sb))
            #expect(similarity.distance.distance(sa, sb) == similarity.distance.distance(sb, sa))
        }
    }

    @Test func contextAddsPieceMotifs() throws {
        // Same pawns; in the second position White's rook stands on the open c-file.
        let a = try SimilarityPosition(fen: "r4rk1/pp3ppp/2p5/3p4/3P4/4P3/PP3PPP/R4RK1 w")
        let b = try SimilarityPosition(fen: "r4rk1/pp3ppp/2p5/3p4/3P4/4P3/PP3PPP/2R2RK1 w")
        #expect(similarity.distance(a, a) == 0)
        #expect(similarity.distance(a, b) == StructureContextWeights().rookOnOpenFile)
    }

    @Test func indexMatchesBruteForce() {
        var index = StructureIndex(firstPly: 0, minimumPlies: 1)
        var all = Set<PawnStructure>()
        for (g, game) in Fixtures.games.enumerated() {
            index.add(gameID: Int64(g), line: game.line)
            for p in game.line.positions { all.insert(StructureSimilarity.structure(p)) }
        }
        #expect(index.count == all.count)
        let d = StructureDistance()
        for query in all.prefix(40) {
            let fast = index.nearest(query, limit: 5)
            let brute = all.map { (s: $0, d: d.distance(query, $0)) }.sorted { $0.d < $1.d }
            #expect(fast.first?.distance == 0)
            #expect(fast.first?.structure == query)
            #expect(fast.map(\.distance) == Array(brute.prefix(5).map(\.d)))
            let other = index.nearest(query, limit: 3, excludingQuery: true)
            #expect(!other.contains { $0.structure == query })
            #expect(other.first.map { $0.distance >= fast[1].distance } ?? true)
        }
    }

    @Test func gameCountsCountGamesNotPlies() {
        var index = StructureIndex(firstPly: 0)
        index.add(gameID: 0, line: Fixtures.qgdD4.line)
        index.add(gameID: 1, line: Fixtures.qgdC4.line)
        index.add(gameID: 2, line: Fixtures.qgdLonger.line)
        let carlsbad = StructureSimilarity.structure(Fixtures.qgdD4.line.positions.last!)
        #expect(index.games(of: carlsbad) == 3)
    }

    @Test func transientStructuresAreSkipped() {
        var every = StructureIndex(firstPly: 0, minimumPlies: 1)
        var stable = StructureIndex(firstPly: 0)
        for (g, game) in Fixtures.games.enumerated() {
            every.add(gameID: Int64(g), line: game.line)
            stable.add(gameID: Int64(g), line: game.line)
        }
        #expect(stable.count < every.count)
        // The Carlsbad of the QGD lasts many plies and stays.
        #expect(stable.games(of: StructureSimilarity.structure(Fixtures.qgdD4.line.positions.last!)) == 3)
    }

    @Test func reversedColoursFindTheCaroKann() {
        var index = StructureIndex(firstPly: 0)
        index.add(gameID: 0, line: Fixtures.caroKann.line)
        let carlsbad = StructureSimilarity.structure(Fixtures.qgdD4.line.positions.last!)
        let plain = index.nearest(carlsbad, limit: 1)
        let both = index.nearest(carlsbad, limit: 1, allowingReversedColors: true)
        #expect(both.first!.distance <= plain.first!.distance)
        #expect(both.first?.reversed == true)
    }
}
