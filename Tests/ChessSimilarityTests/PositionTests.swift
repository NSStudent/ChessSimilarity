//
//  PositionTests.swift
//  ChessSimilarityTests
//

@testable import ChessSimilarity
import Testing

struct PositionTests {
    static func allPositions() -> [SimilarityPosition] {
        Fixtures.games.flatMap(\.line.positions)
    }

    @Test func termsHaveNoRepeatsAndBelongToOneColumn() {
        var columnOf: [String: TermColumn] = [:]
        for p in Self.allPositions() {
            let terms = PositionTerms(p)
            for column in TermColumn.allCases {
                let list = terms[column]
                #expect(Set(list).count == list.count, "repeat in \(column)")
                for t in list {
                    #expect(t.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) && !$0.isUppercase }, "\(t)")
                    if let other = columnOf[t] { #expect(other == column, "\(t) in \(other) and \(column)") }
                    columnOf[t] = column
                }
            }
            #expect(terms[.material].count == 1)
        }
    }

    @Test func startPositionTerms() {
        let terms = PositionTerms(.start)
        #expect(terms[.pieces].count == 32)
        #expect(terms[.pieces].contains("wnb1"))
        #expect(terms[.pieces].contains("bke8"))
        #expect(terms[.reach].contains("rwnf3"))
        #expect(terms[.reach].contains("rbnc6"))
        #expect(!terms[.reach].contains("rwbc4"), "the bishop is blocked")
        #expect(terms[.balance].contains("stmw"))
        #expect(terms[.balance].contains("wbpair"))
        #expect(terms.materialKey == "m1222812228")
        #expect(terms[.king].contains("wkfc"))
    }

    @Test func catalogStructureBecomesATerm() {
        // The final position of the QGD Exchange is a Carlsbad (catalog kind 4).
        let terms = PositionTerms(Fixtures.qgdD4.line.positions.last!)
        #expect(terms[.pawns].contains("s04"))
        // The Caro-Kann Exchange is the Carlsbad with colours reversed.
        #expect(PositionTerms(Fixtures.caroKann.line.positions.last!)[.pawns].contains("s04r"))
    }

    @Test func momentsAreQuietAndSpaced() {
        let policy = MomentPolicy()
        for game in Fixtures.games {
            let moments = policy.moments(of: game.line)
            #expect(!moments.isEmpty)
            #expect(moments.count <= 3)
            let captures = game.line.captures
            for m in moments where m.ply != game.line.positions.count - 1 {
                #expect(!captures[m.ply], "\(game.event) ply \(m.ply)")
                #expect(!game.line.positions[m.ply].isCheck)
            }
            for (a, b) in zip(moments, moments.dropFirst()) { #expect(b.ply - a.ply >= policy.minimumGap) }
        }
        // The Immortal (45 plies): opening end only, ply 24 or the first quiet ply after it.
        let immortal = policy.moments(of: Fixtures.game("London").line)
        #expect(immortal.first?.kind == .openingEnd)
        #expect((24 ... 32).contains(immortal.first!.ply))
    }

    @Test func endingMomentIsFound() throws {
        // A rook ending after a few moves: the ending moment is the first quiet ply.
        let line = try GameLine(
            san: ["Kd2", "Kd7", "Kc3", "Kc7", "Rb5", "Rb6", "Rxb6", "axb6", "Kb4", "Kc6", "a4", "Kb7",
                  "a5", "bxa5+", "Kxa5", "Ka7", "f3", "f6", "g4", "g5", "h3", "h6", "Kb5", "Kb7"],
            startFEN: "1r2k3/p4ppp/8/8/8/8/P4PPP/1R2K3 w - - 0 1"
        )
        let moments = MomentPolicy().moments(of: line)
        #expect(moments.contains { $0.kind == .endingStart })
        #expect(EndingPhase.isEnding(line.positions[0]))
    }

    /// Builds the in-memory index over every ply of every fixture game.
    static func everyPlyIndex() -> InMemoryPositionIndex {
        var index = InMemoryPositionIndex()
        for (g, game) in Fixtures.games.enumerated() {
            for (ply, p) in game.line.positions.enumerated() {
                index.add(gameID: Int64(g), ply: ply, position: p)
            }
        }
        return index
    }

    @Test func aPositionIsMostSimilarToItself() {
        let index = Self.everyPlyIndex()
        for (g, game) in Fixtures.games.enumerated() {
            for ply in stride(from: 8, to: game.line.positions.count, by: 7) {
                let hits = index.search(game.line.positions[ply], options: PositionQueryOptions(limit: 3, onePerGame: false, maximumTerms: nil))
                let top = try! #require(hits.first)
                // The same position can occur in another fixture game (the QGD transpositions):
                // then it must tie with the query's own document.
                let own = hits.first { $0.gameID == Int64(g) && $0.ply == ply }
                #expect(own != nil, "\(game.event) ply \(ply)")
                #expect(abs((own?.score ?? 0) - top.score) < 1e-9)
                // With the default 48 terms the position is still among the first hits.
                let pruned = index.search(game.line.positions[ply], options: PositionQueryOptions(limit: 3, onePerGame: false))
                #expect(pruned.contains { $0.gameID == Int64(g) && $0.ply == ply }, "\(game.event) ply \(ply), 48 terms")
            }
        }
    }

    @Test func transpositionsScoreLikeTheSamePosition() {
        let index = Self.everyPlyIndex()
        let d4 = Fixtures.games.firstIndex { $0.event.hasPrefix("Fixture: QGD Exchange, d4 order") }!
        let c4 = Fixtures.games.firstIndex { $0.event.hasPrefix("Fixture: QGD Exchange, c4 order") }!
        let query = Fixtures.qgdD4.line.positions[18]
        let hits = index.search(query, options: PositionQueryOptions(limit: 5, maximumTerms: nil))
        let scores = Dictionary(uniqueKeysWithValues: hits.map { ($0.gameID, $0.score) })
        #expect(Set(hits.prefix(3).map(\.gameID)).isSuperset(of: [Int64(d4), Int64(c4)]))
        #expect(abs(scores[Int64(d4)]! - scores[Int64(c4)]!) < 1e-9)
    }

    @Test func pruningKeepsTheMostInformativeTerms() {
        let index = Self.everyPlyIndex()
        let query = Fixtures.qgdD4.line.positions[20]
        let terms = PositionTerms(query)
        let pruned = terms.pruned(documents: index.documentCount, frequency: index.documentFrequency,
                                  weights: .standard, options: PositionQueryOptions(maximumTerms: 10))
        #expect(pruned.count == 10 + 1, "ten terms and the material token")
        #expect(pruned[.material] == terms[.material])
        // Every kept term weighs at least as much as every dropped one.
        func value(_ t: String, _ c: TermColumn) -> Double {
            BM25Parameters.idf(documents: index.documentCount, containing: index.documentFrequency(t)) * BM25Parameters.standard.weight(c)
        }
        let kept = TermColumn.allCases.filter { $0 != .material }.flatMap { c in pruned[c].map { value($0, c) } }
        let dropped = TermColumn.allCases.filter { $0 != .material }.flatMap { c in
            terms[c].filter { !pruned[c].contains($0) && index.documentFrequency($0) > 0 }.map { value($0, c) }
        }
        #expect(kept.min()! >= dropped.max()!)
        let hits = index.search(query, options: PositionQueryOptions(limit: 1, maximumTerms: 30))
        #expect(hits.first?.score ?? 0 > 0)
    }

    @Test func exactMaterialFilter() {
        let index = Self.everyPlyIndex()
        let query = Fixtures.qgdD4.line.positions[20]
        let key = PositionTerms(query).materialKey
        let hits = index.search(query, options: PositionQueryOptions(limit: 50, material: .exact, onePerGame: false, maximumTerms: nil))
        #expect(!hits.isEmpty)
        for h in hits {
            #expect(PositionTerms(Fixtures.games[Int(h.gameID)].line.positions[h.ply]).materialKey == key)
        }
        let loose = index.search(query, options: PositionQueryOptions(limit: 500, material: .none, onePerGame: false, maximumTerms: nil))
        #expect(loose.count > hits.count)
    }

    @Test func pawnToleranceAcceptsOneMorePawn() throws {
        let p = try SimilarityPosition(fen: "4k3/pppp4/8/8/8/8/PPP5/4K3 w")
        let keys = try #require(MaterialFilter.pawnTolerance(1).keys(for: p))
        #expect(keys.count == 9)
        #expect(keys.contains(PositionTerms.materialKey(p, whitePawns: 1, blackPawns: -1)!))
    }

    @Test func bm25MatchesTheFormula() {
        // One document per position; a hand computation for one term.
        var index = InMemoryPositionIndex(parameters: BM25Parameters(columnWeights: [1, 0, 0, 0, 0, 0, 0]))
        let a = PositionTerms(columns: [["wpe4", "bpe5"], [], [], [], [], [], ["m1"]])
        let b = PositionTerms(columns: [["wpe4", "bpd5", "wnf3"], [], [], [], [], [], ["m1"]])
        let c = PositionTerms(columns: [["wpd4"], [], [], [], [], [], ["m1"]])
        index.add(gameID: 0, ply: 0, terms: a)
        index.add(gameID: 1, ply: 0, terms: b)
        index.add(gameID: 2, ply: 0, terms: c)
        let q = PositionTerms(columns: [["bpe5"], [], [], [], [], [], ["m1"]])
        let hits = index.search(q, materialKeys: nil, options: PositionQueryOptions(limit: 3, material: .none, maximumTerms: nil))
        let idf = BM25Parameters.idf(documents: 3, containing: 1)
        let avg = (3.0 + 4.0 + 2.0) / 3.0
        let expected = idf * 1 * 2.2 / (1 + 1.2 * (1 - 0.75 + 0.75 * 3 / avg))
        #expect(hits.first?.gameID == 0)
        #expect(abs(hits.first!.score - expected) < 1e-12)
    }

    #if canImport(SQLite3)
    /// FTS5's `bm25()` and the Swift index give the same scores and order.
    @Test func fts5MatchesTheInMemoryIndex() throws {
        let fts = try FTS5PositionIndex()
        var memory = InMemoryPositionIndex()
        try fts.beginBatch()
        for (g, game) in Fixtures.games.enumerated() {
            for (ply, p) in game.line.positions.enumerated() {
                let terms = PositionTerms(p)
                try fts.add(gameID: Int64(g), ply: ply, terms: terms)
                memory.add(gameID: Int64(g), ply: ply, terms: terms)
            }
        }
        try fts.commit()
        #expect(fts.documentCount == memory.documentCount)
        #expect(try fts.documentFrequency("wke1") == memory.documentFrequency("wke1"))
        for (g, game) in Fixtures.games.enumerated() {
            for ply in stride(from: 5, to: game.line.positions.count, by: 9) {
                let p = game.line.positions[ply]
                for (material, maximumTerms) in [(MaterialFilter.exact, nil), (.pawnTolerance(1), nil), (.exact, 24), (.none, 16)] {
                    let options = PositionQueryOptions(limit: 8, material: material, onePerGame: false, maximumTerms: maximumTerms)
                    let a = try fts.search(p, options: options)
                    let b = memory.search(p, options: options)
                    #expect(a.count == b.count, "game \(g) ply \(ply)")
                    for (x, y) in zip(a, b) {
                        #expect(abs(x.score - y.score) < 1e-6, "game \(g) ply \(ply): \(x) vs \(y)")
                    }
                }
            }
        }
        try fts.optimize()
        let after = try fts.search(Fixtures.qgdD4.line.positions[18], options: PositionQueryOptions(limit: 3))
        #expect(after.count == 3)
    }

    @Test func fts5MomentsAndPruning() throws {
        let fts = try FTS5PositionIndex()
        for (g, game) in Fixtures.games.enumerated() { try fts.add(gameID: Int64(g), line: game.line) }
        let d4 = Int64(Fixtures.games.firstIndex { $0.event.hasPrefix("Fixture: QGD Exchange, d4 order") }!)
        let moments = MomentPolicy().moments(of: Fixtures.qgdD4.line)
        let query = Fixtures.qgdD4.line.positions[moments[0].ply]
        let hits = try fts.search(query, options: PositionQueryOptions(limit: 3, maximumDocumentShare: 0.9))
        #expect(hits.contains { $0.gameID == d4 && $0.ply == moments[0].ply })
        let pruned = try fts.search(query, options: PositionQueryOptions(limit: 3, maximumTerms: 20))
        #expect(pruned.contains { $0.gameID == d4 && $0.ply == moments[0].ply })
        let excluded = try fts.search(query, options: PositionQueryOptions(limit: 3, excludedGame: d4))
        #expect(!excluded.contains { $0.gameID == d4 })
    }
    #endif
}
