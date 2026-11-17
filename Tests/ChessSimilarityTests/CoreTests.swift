//
//  CoreTests.swift
//  ChessSimilarityTests
//

@testable import ChessSimilarity
import FischerCore
import Testing

struct CoreTests {
    @Test func startPositionMatchesFEN() throws {
        let p = try SimilarityPosition(fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
        #expect(p == .start)
        #expect(p.fen == "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w")
    }

    @Test func invalidFENThrows() {
        #expect(throws: SimilarityInputError.self) { try SimilarityPosition(fen: "8/8/8/8/8/8/8/8 w") }
        #expect(throws: SimilarityInputError.self) { try SimilarityPosition(fen: "rnbqkbnr/ppppppp/8") }
    }

    /// Every position of every fixture game matches FischerCore's own replay
    /// (castling both ways, captures, checks and mates).
    @Test func replayMatchesFischerCore() throws {
        #expect(Fixtures.games.count == 11)
        for game in Fixtures.games {
            var reference = Game()
            let moves = try GameLine.resolve(san: game.san)
            #expect(game.line.positions.count == game.san.count + 1)
            for (i, move) in moves.enumerated() {
                try reference.execute(uncheckedMove: move.move) { move.promotion ?? .queen }
                let expected = SimilarityPosition(reference.position)
                #expect(game.line.positions[i + 1] == expected, "\(game.event) ply \(i + 1)")
            }
        }
    }

    @Test func enPassantAndPromotion() throws {
        let ep = try GameLine(san: ["e4", "a6", "e5", "d5", "exd6"])
        #expect(ep.positions.last!.fen == "rnbqkbnr/1pp1pppp/p2P4/8/8/8/PPPP1PPP/RNBQKBNR b")
        let promo = try GameLine(san: ["a8=N"], startFEN: "8/P7/8/8/8/8/k7/7K w - - 0 1")
        #expect(promo.positions.last!.fen == "N7/8/8/8/8/8/k7/7K b")
        #expect(promo.captures == [false, false])
    }

    @Test func sanTokensSkipCommentsAndVariations() {
        let tokens = GameLine.sanTokens("1. e4 {best by test} e5 (1... c5 2. Nf3) 2. Nf3 $1 Nc6 3... a6 1-0")
        #expect(tokens == ["e4", "e5", "Nf3", "Nc6", "a6"])
    }

    @Test func attacksOnTheEmptyBoard() {
        #expect(Attacks.rook(0, 0).nonzeroBitCount == 14)
        #expect(Attacks.bishop(27, 0).nonzeroBitCount == 13)
        #expect(Attacks.knight(0).nonzeroBitCount == 2)
        #expect(Attacks.king(27).nonzeroBitCount == 8)
        // A blocker on a4 stops the rook on a1 there.
        #expect(Attacks.rook(0, 1 << 24) & (1 << 32) == 0)
        #expect(Attacks.rook(0, 1 << 24) & (1 << 24) != 0)
    }

    @Test func positionKeysIgnoreMoveOrder() {
        let a = Fixtures.qgdD4.line.positions, b = Fixtures.qgdC4.line.positions
        #expect(PositionKey.key(a[6]) == PositionKey.key(b[6]))
        #expect(PositionKey.key(a.last!) == PositionKey.key(b.last!))
        #expect(PositionKey.key(a[3]) != PositionKey.key(b[3]))
    }
}
