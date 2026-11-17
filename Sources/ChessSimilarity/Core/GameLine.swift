//
//  GameLine.swift
//  ChessSimilarity
//

import FischerCore

/// The positions of one game: the start position and the position after each move.
public struct GameLine: Sendable {
    /// `moves + 1` positions.
    public var positions: [SimilarityPosition]

    public init(positions: [SimilarityPosition]) {
        self.positions = positions
    }

    /// Replays FischerCore moves from the start position or from `startFEN`.
    public init(moves: [ResolvedMove], startFEN: String? = nil) throws {
        var position = try startFEN.map { try SimilarityPosition(fen: $0) } ?? .start
        var out = [SimilarityPosition]()
        out.reserveCapacity(moves.count + 1)
        out.append(position)
        for (i, move) in moves.enumerated() {
            do {
                try position.play(move)
            } catch {
                throw SimilarityInputError.invalidMove(index: i)
            }
            out.append(position)
        }
        positions = out
    }

    /// Resolves SAN with FischerCore and replays it. Convenience for tests and tools.
    public init(san: [String], startFEN: String? = nil) throws {
        try self.init(moves: Self.resolve(san: san, startFEN: startFEN), startFEN: startFEN)
    }

    /// Resolves SAN moves into FischerCore moves, stopping with an error at the first one that fails.
    public static func resolve(san: [String], startFEN: String? = nil) throws -> [ResolvedMove] {
        var game: Game
        if let startFEN {
            guard let position = Position(fen: startFEN), let g = try? Game(position: position) else {
                throw SimilarityInputError.invalidFEN(startFEN)
            }
            game = g
        } else {
            game = Game()
        }
        var out: [ResolvedMove] = []
        out.reserveCapacity(san.count)
        for (i, text) in san.enumerated() {
            guard case let .success(resolved) = game.resolveResult(san: text) else {
                throw SimilarityInputError.unresolvedSAN(index: i, san: text)
            }
            do {
                try game.execute(uncheckedMove: resolved.move) { resolved.promotion ?? .queen }
            } catch {
                throw SimilarityInputError.unresolvedSAN(index: i, san: text)
            }
            out.append(resolved)
        }
        return out
    }

    /// Splits a movetext such as `1. e4 e5 2. Nf3` into SAN tokens (no comments or variations).
    public static func sanTokens(_ movetext: String) -> [String] {
        var out: [String] = []
        var depth = 0, inBrace = false
        for raw in movetext.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }) {
            var token = Substring(raw)
            if inBrace { if token.contains("}") { inBrace = false }; continue }
            if token.hasPrefix("{") { if !token.contains("}") { inBrace = true }; continue }
            if token.hasPrefix("(") { depth += token.filter { $0 == "(" }.count - token.filter { $0 == ")" }.count; continue }
            if depth > 0 { depth += token.filter { $0 == "(" }.count - token.filter { $0 == ")" }.count; continue }
            if token.hasPrefix("$") { continue }
            if ["1-0", "0-1", "1/2-1/2", "*"].contains(token) { break }
            if let dot = token.lastIndex(of: ".") { token = token[token.index(after: dot)...] }
            if token.isEmpty { continue }
            out.append(String(token))
        }
        return out
    }

    /// `true` at ply `i` when the move that led to `positions[i]` captured (or promoted a pawn into a piece
    /// count drop); always `false` at ply 0.
    public var captures: [Bool] {
        var out = [Bool](repeating: false, count: positions.count)
        for i in positions.indices.dropFirst() where positions[i].pieceCount < positions[i - 1].pieceCount {
            out[i] = true
        }
        return out
    }
}

/// A 64-bit Zobrist key of placement and side to move (no castling, no en passant).
public enum PositionKey {
    static let table: [UInt64] = {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        return (0 ..< 12 * 64 + 1).map { _ in splitMix(&state) }
    }()

    @inline(__always)
    static func splitMix(_ state: inout UInt64) -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public static func key(_ p: SimilarityPosition) -> UInt64 {
        var h: UInt64 = p.sideToMove == .black ? table[12 * 64] : 0
        table.withUnsafeBufferPointer { t in
            for lane in 0 ..< 12 {
                let base = lane * 64
                p.lanes[lane].forEachBit { h ^= t[base + $0] }
            }
        }
        return h
    }

    /// Key of the pawns only (the «pawn hash» of chess engines).
    public static func pawnKey(_ p: SimilarityPosition) -> UInt64 {
        var h: UInt64 = 0
        p.lanes[0].forEachBit { h ^= table[$0] }
        p.lanes[6].forEachBit { h ^= table[6 * 64 + $0] }
        return h
    }
}
