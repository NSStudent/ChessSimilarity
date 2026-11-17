//
//  Support.swift
//  ChessSimilarityTests
//

import ChessSimilarity
import FischerCore
import Foundation

struct FixtureGame {
    var event: String
    var san: [String]
    var line: GameLine
}

enum Fixtures {
    /// The games of `classics.pgn`, replayed.
    static let games: [FixtureGame] = {
        let url = Bundle.module.url(forResource: "classics", withExtension: "pgn", subdirectory: "Fixtures")!
        let text = try! String(contentsOf: url, encoding: .utf8)
        return PGNGameSplitter.split(text).map { chunk in
            let chunkValue = PGNGameChunk(index: 0, text: chunk, startByteOffset: 0, endByteOffset: 0)
            let basic = try! chunkValue.basicGame()
            var event = ""
            for (tag, value) in basic.tags where tag.rawValue == "Event" { event = value }
            let san = GameLine.sanTokens(basic.movetext)
            return FixtureGame(event: event, san: san, line: try! GameLine(san: san))
        }
    }()

    static func game(_ prefix: String) -> FixtureGame {
        games.first { $0.event.hasPrefix(prefix) }!
    }

    static var qgdD4: FixtureGame { game("Fixture: QGD Exchange, d4 order") }
    static var qgdC4: FixtureGame { game("Fixture: QGD Exchange, c4 order") }
    static var qgdLonger: FixtureGame { game("Fixture: QGD Exchange, d4 order, longer") }
    static var panov: FixtureGame { game("Fixture: Panov") }
    static var caroKann: FixtureGame { game("Fixture: Caro-Kann") }
}
