//
//  main.swift
//  chess-similarity-tool
//
//  Measures the indexes on the first N games of a PGN file and writes a report
//  with the hand-check queries.
//
//  chess-similarity-tool bench <file.pgn> [--games 100000] [--queries 100] [--checks 10]
//                              [--work <dir>] [--report <file.md>] [--threads 4]
//

import ChessPawnStructures
import ChessSimilarity
import FischerCore
import Foundation

// MARK: Arguments

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "terms", arguments.count >= 2 {
    // chess-similarity-tool terms "<fen>": the terms and the FTS5 query of a position.
    let p = try SimilarityPosition(fen: arguments[1])
    let terms = PositionTerms(p)
    for column in TermColumn.allCases { print("\(column.name): \(terms[column].joined(separator: " "))") }
    print("MATCH: " + PositionFTS5Schema.matchExpression(terms, materialKeys: MaterialFilter.exact.keys(for: p)))
    exit(0)
}
guard arguments.first == "bench", arguments.count >= 2 else {
    print("usage: chess-similarity-tool bench <file.pgn> [--games N] [--queries Q] [--checks C] [--work DIR] [--report FILE] [--threads T]")
    exit(2)
}
let pgnPath = arguments[1]
func option(_ name: String, _ fallback: String) -> String {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return fallback }
    return arguments[i + 1]
}
let gameLimit = Int(option("--games", "100000"))!
let queryCount = Int(option("--queries", "100"))!
let checkCount = Int(option("--checks", "10"))!
let threads = Int(option("--threads", "4"))!
let workDir = URL(fileURLWithPath: option("--work", FileManager.default.temporaryDirectory.appendingPathComponent("chess-similarity").path))
let reportPath = option("--report", workDir.appendingPathComponent("report.md").path)
try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

// MARK: Timing (CPU of the calling thread: the machine is shared, wall time is noisy)

func threadCPU() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
}

func wall() -> Double { Date().timeIntervalSinceReferenceDate }

struct Stopwatch {
    var cpu = 0.0
    var wall = 0.0
    mutating func measure<T>(_ body: () throws -> T) rethrows -> T {
        let c = threadCPU(), w = ChessSimilarityTool.wall()
        defer { cpu += threadCPU() - c; wall += ChessSimilarityTool.wall() - w }
        return try body()
    }
}

enum ChessSimilarityTool {
    static func wall() -> Double { Date().timeIntervalSinceReferenceDate }
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let s = values.sorted()
    return s[min(s.count - 1, Int(Double(s.count - 1) * p + 0.5))]
}

func ms(_ s: Double) -> String { String(format: "%.2f ms", s * 1000) }
func us(_ s: Double) -> String { String(format: "%.1f µs", s * 1e6) }

// MARK: Reading games

struct GameInfo {
    var label: String
    var eco: String
}

struct ParsedGame {
    var index: Int
    var info: GameInfo
    var line: GameLine?
}

func parse(_ chunk: PGNGameChunk) -> ParsedGame {
    guard let basic = try? chunk.basicGame() else {
        return ParsedGame(index: chunk.index, info: GameInfo(label: "?", eco: ""), line: nil)
    }
    var tags: [String: String] = [:]
    for (tag, value) in basic.tags { tags[tag.rawValue] = value }
    let label = "\(tags["White"] ?? "?") – \(tags["Black"] ?? "?"), \(tags["Event"] ?? "?") \(tags["Date"]?.prefix(4) ?? "?") (\(tags["Result"] ?? "*"))"
    let info = GameInfo(label: label, eco: tags["ECO"] ?? "")
    let fen = tags["FEN"].flatMap { $0.isEmpty ? nil : $0 }
    let san = GameLine.sanTokens(basic.movetext)
    // Cut at the first move that does not resolve, as an importer would.
    var resolved: [ResolvedMove] = []
    if let moves = try? GameLine.resolve(san: san, startFEN: fen) {
        resolved = moves
    } else {
        var lo = 0, hi = san.count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if (try? GameLine.resolve(san: Array(san.prefix(mid)), startFEN: fen)) != nil { lo = mid } else { hi = mid - 1 }
        }
        resolved = (try? GameLine.resolve(san: Array(san.prefix(lo)), startFEN: fen)) ?? []
    }
    return ParsedGame(index: chunk.index, info: info, line: try? GameLine(moves: resolved, startFEN: fen))
}

func parseParallel(_ chunks: [PGNGameChunk]) -> [ParsedGame] {
    var out = [ParsedGame?](repeating: nil, count: chunks.count)
    let lock = NSLock()
    let per = (chunks.count + threads - 1) / max(threads, 1)
    DispatchQueue.concurrentPerform(iterations: threads) { t in
        let range = (t * per) ..< min(chunks.count, (t + 1) * per)
        guard !range.isEmpty else { return }
        let parsed = range.map { parse(chunks[$0]) }
        lock.lock()
        for (k, p) in zip(range, parsed) { out[k] = p }
        lock.unlock()
    }
    return out.compactMap { $0 }
}

// MARK: Indexes

let dbURL = workDir.appendingPathComponent("positions-\(gameLimit).sqlite")
for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbURL.path + suffix) }
let fts = try FTS5PositionIndex(path: dbURL.path)
// A second index without the reach and links columns, to compare size and results.
let compactURL = workDir.appendingPathComponent("positions-compact-\(gameLimit).sqlite")
for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: compactURL.path + suffix) }
let compactOptions = TermOptions(reach: false, links: false)
let compact = try FTS5PositionIndex(path: compactURL.path, termOptions: compactOptions)
var compactWatch = Stopwatch()
var endings = EndingIndex()
var similarGames = GameSimilarityIndex()
// The first preset tried (positions and structures from ply 16), kept for comparison.
var similarPositions = GameSimilarityIndex(lsh: .similarGames, setOptions: GameSetOptions(firstPly: 16, includesPositions: true, includesPawnStructures: true))
var duplicates = GameSimilarityIndex.nearDuplicates()
var structures = StructureIndex()

var termWatch = Stopwatch(), insertWatch = Stopwatch(), endingWatch = Stopwatch()
var minhashWatch = Stopwatch(), duplicateWatch = Stopwatch(), structureWatch = Stopwatch()
var parseWall = 0.0
var documents = 0, termTotal = 0, gamesIndexed = 0, gamesWithEnding = 0, unreadable = 0
var infos: [GameInfo] = []
var momentPositions: [Int: [Int: SimilarityPosition]] = [:]   // game → ply → position (moments and ending)
var heldOut: [ParsedGame] = []
let policy = MomentPolicy()

func index(_ game: ParsedGame) throws {
    infos.append(game.info)
    guard let line = game.line, line.positions.count > 1 else { unreadable += 1; return }
    let id = Int64(game.index)
    gamesIndexed += 1
    let moments = policy.moments(of: line)
    var keep: [Int: SimilarityPosition] = [:]
    for m in moments {
        let terms = termWatch.measure { PositionTerms(line.positions[m.ply]) }
        termTotal += terms.count
        try insertWatch.measure { try fts.add(gameID: id, ply: m.ply, terms: terms) }
        try compactWatch.measure { try compact.add(gameID: id, ply: m.ply, position: line.positions[m.ply]) }
        documents += 1
        keep[m.ply] = line.positions[m.ply]
    }
    if let ply = endingWatch.measure({ endings.add(gameID: id, line: line) }) {
        gamesWithEnding += 1
        keep[ply] = line.positions[ply]
    }
    minhashWatch.measure { similarGames.add(gameID: id, line: line) }
    similarPositions.add(gameID: id, line: line)
    duplicateWatch.measure { duplicates.add(gameID: id, line: line) }
    structureWatch.measure { structures.add(gameID: id, line: line) }
    momentPositions[game.index] = keep
}

let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: pgnPath))
var chunker = PGNByteChunker()
var pending: [PGNGameChunk] = []
var read = 0
let needed = gameLimit + queryCount
try fts.beginBatch()
try compact.beginBatch()
var finished = false
while !finished {
    let block = try handle.read(upToCount: 8 << 20) ?? Data()
    if block.isEmpty { pending += chunker.finish(); finished = true } else { pending += chunker.consume(block) }
    if pending.count >= 4000 || finished {
        let take = Array(pending.prefix(needed - read))
        pending = []
        read += take.count
        let w = wall()
        let parsed = parseParallel(take)
        parseWall += wall() - w
        for g in parsed {
            if g.index < gameLimit { try index(g) } else { heldOut.append(g) }
        }
        FileHandle.standardError.write("\(read) games\n".data(using: .utf8)!)
        if read >= needed { finished = true }
    }
}
try fts.commit()
try compact.commit()
var optimizeWatch = Stopwatch()
try optimizeWatch.measure { try fts.optimize() }
try fts.execute("PRAGMA wal_checkpoint(TRUNCATE)")
try compact.optimize()
try compact.execute("PRAGMA wal_checkpoint(TRUNCATE)")
let compactBytes = (try? FileManager.default.attributesOfItem(atPath: compactURL.path)[.size] as? Int) ?? 0
let dbBytes = (try? FileManager.default.attributesOfItem(atPath: dbURL.path)[.size] as? Int) ?? 0

// MARK: Queries

struct QueryCase {
    var gameIndex: Int
    var ply: Int
    var position: SimilarityPosition
    var line: GameLine
    var info: GameInfo
}

var positionQueries: [QueryCase] = []
var endingQueries: [QueryCase] = []
var gameQueries: [QueryCase] = []
for g in heldOut {
    guard let line = g.line, line.positions.count > 30 else { continue }
    let moments = policy.moments(of: line)
    if let m = moments.first(where: { $0.kind == .middlegame }) ?? moments.first {
        positionQueries.append(QueryCase(gameIndex: g.index, ply: m.ply, position: line.positions[m.ply], line: line, info: g.info))
    }
    if let e = EndingIndex.endingPly(of: line) {
        endingQueries.append(QueryCase(gameIndex: g.index, ply: e, position: line.positions[e], line: line, info: g.info))
    }
    gameQueries.append(QueryCase(gameIndex: g.index, ply: 0, position: line.positions[0], line: line, info: g.info))
}

func timed<T>(_ body: () throws -> T) rethrows -> (T, Double) {
    let c = threadCPU()
    let r = try body()
    return (r, threadCPU() - c)
}

var report = ""
func say(_ s: String = "") { report += s + "\n"; print(s) }

func describe(_ p: SimilarityPosition) -> String { p.fen }
func position(_ game: Int64, _ ply: Int) -> String {
    momentPositions[Int(game)]?[ply].map(describe) ?? "?"
}

let sim = StructureSimilarity()

say("# ChessSimilarity bench")
say()
say("- Source: \(URL(fileURLWithPath: pgnPath).lastPathComponent), first \(gameLimit) games; \(gamesIndexed) indexed, \(unreadable) unreadable or empty.")
say("- Queries: games \(gameLimit)…\(gameLimit + queryCount - 1) (held out).")
say("- Times are CPU time of one thread (the machine is shared). Parse (SAN → positions, \(threads) threads) took \(String(format: "%.1f", parseWall)) s of wall time and is not part of the build times.")
say()
say("## Build")
say()
say("| Part | CPU per game | Size | Per game |")
say("|---|--:|--:|--:|")
let g = Double(gamesIndexed)
say("| S-a terms (\(documents) docs, \(String(format: "%.2f", Double(documents) / g)) per game, \(String(format: "%.0f", Double(termTotal) / Double(max(documents, 1)))) terms per doc) | \(us(termWatch.cpu / g)) | — | — |")
say("| S-a FTS5 insert | \(us(insertWatch.cpu / g)) | \(String(format: "%.1f", Double(dbBytes) / 1e6)) MB | \(String(format: "%.0f", Double(dbBytes) / g)) B |")
say("| S-a compact FTS5 (no reach or links): terms + insert | \(us(compactWatch.cpu / g)) | \(String(format: "%.1f", Double(compactBytes) / 1e6)) MB | \(String(format: "%.0f", Double(compactBytes) / g)) B |")
say("| S-a FTS5 optimize (once) | \(String(format: "%.1f s", optimizeWatch.cpu)) | | |")
say("| S-b endings (\(gamesWithEnding) with an ending) | \(us(endingWatch.cpu / g)) | \(String(format: "%.1f", Double(endings.count * EndingIndex.packedEntryBytes) / 1e6)) MB packed | \(String(format: "%.0f", Double(endings.count * EndingIndex.packedEntryBytes) / g)) B |")
say("| S-b similar games (MinHash 16×2) | \(us(minhashWatch.cpu / g)) | \(String(format: "%.1f", Double(similarGames.payloadBytes) / 1e6)) MB | \(similarGames.payloadBytes / max(gamesIndexed, 1)) B |")
say("| S-b near duplicates (MinHash 8×4) | \(us(duplicateWatch.cpu / g)) | \(String(format: "%.1f", Double(duplicates.payloadBytes) / 1e6)) MB | \(duplicates.payloadBytes / max(gamesIndexed, 1)) B |")
say("| E6 distinct structures (\(structures.count), plies ≥ 14) | \(us(structureWatch.cpu / g)) | \(String(format: "%.1f", Double(structures.payloadBytes) / 1e6)) MB | \(structures.payloadBytes / max(gamesIndexed, 1)) B |")
say()

// S-a
var exactTimes: [Double] = [], tolerantTimes: [Double] = []
var prunedTimes: [Int: [Double]] = [:], prunedOverlap: [Int: Double] = [:]
var positionResults: [(QueryCase, [SimilarPosition])] = []
var compactTimes: [Double] = [], compactOverlap = 0.0
let termLimits = [24, 48, 64]
let defaultTerms = 48
_ = try fts.search(SimilarityPosition.start, options: PositionQueryOptions(limit: 1, maximumTerms: 8))  // loads the frequencies once
for q in positionQueries {
    let (r, t) = try timed { try fts.search(q.position, options: PositionQueryOptions(limit: 10, material: .exact, maximumTerms: nil)) }
    exactTimes.append(t)
    let full = Set(r.map(\.gameID))
    for n in termLimits {
        let (p, t3) = try timed { try fts.search(q.position, options: PositionQueryOptions(limit: 10, material: .exact, maximumTerms: n)) }
        prunedTimes[n, default: []].append(t3)
        let b = Set(p.map(\.gameID))
        prunedOverlap[n, default: 0] += full.isEmpty ? 1 : Double(full.intersection(b).count) / Double(full.count)
        if n == defaultTerms { positionResults.append((q, p)) }
    }
    let (_, t2) = try timed { try fts.search(q.position, options: PositionQueryOptions(limit: 10, material: .pawnTolerance(1), maximumTerms: defaultTerms)) }
    tolerantTimes.append(t2)
    let (c, t4) = try timed { try compact.search(q.position, options: PositionQueryOptions(limit: 10, material: .exact, maximumTerms: defaultTerms)) }
    compactTimes.append(t4)
    let cb = Set(c.map(\.gameID))
    compactOverlap += full.isEmpty ? 1 : Double(full.intersection(cb).count) / Double(full.count)
}
let emptyExact = positionResults.filter { $0.1.isEmpty }.count
say("## Queries")
say()
say("| Query | Median | p90 | Max |")
say("|---|--:|--:|--:|")
say("| S-a FTS5, same material, all terms (\(positionQueries.count) queries, \(emptyExact) without hits) | \(ms(percentile(exactTimes, 0.5))) | \(ms(percentile(exactTimes, 0.9))) | \(ms(exactTimes.max() ?? 0)) |")
for n in termLimits {
    let times = prunedTimes[n] ?? []
    say("| S-a FTS5, same material, \(n) terms (top-10 games shared with all terms: \(String(format: "%.0f", 100 * (prunedOverlap[n] ?? 0) / Double(max(positionQueries.count, 1)))) %) | \(ms(percentile(times, 0.5))) | \(ms(percentile(times, 0.9))) | \(ms(times.max() ?? 0)) |")
}
say("| S-a compact FTS5, same material, \(defaultTerms) terms (top-10 games shared with the full index, all terms: \(String(format: "%.0f", 100 * compactOverlap / Double(max(positionQueries.count, 1)))) %) | \(ms(percentile(compactTimes, 0.5))) | \(ms(percentile(compactTimes, 0.9))) | \(ms(compactTimes.max() ?? 0)) |")
say("| S-a FTS5, pawns ±1, \(defaultTerms) terms | \(ms(percentile(tolerantTimes, 0.5))) | \(ms(percentile(tolerantTimes, 0.9))) | \(ms(tolerantTimes.max() ?? 0)) |")

var endingTimes: [Double] = [], endingAllTimes: [Double] = []
var endingResults: [(QueryCase, [SimilarEnding])] = []
for q in endingQueries {
    let (r, t) = timed { endings.search(q.position, limit: 10) }
    endingTimes.append(t)
    endingResults.append((q, r))
    let (_, t2) = timed { endings.search(q.position, limit: 10, candidates: .all) }
    endingAllTimes.append(t2)
}
say("| S-b endings, same pieces (\(endingQueries.count) queries, \(endingResults.filter { !$0.1.isEmpty }.count) with hits) | \(ms(percentile(endingTimes, 0.5))) | \(ms(percentile(endingTimes, 0.9))) | \(ms(endingTimes.max() ?? 0)) |")
say("| S-b endings, all \(endings.count) | \(ms(percentile(endingAllTimes, 0.5))) | \(ms(percentile(endingAllTimes, 0.9))) | \(ms(endingAllTimes.max() ?? 0)) |")

var gameTimes: [Double] = []
var gameResults: [(QueryCase, [SimilarGame])] = []
for q in gameQueries {
    let (r, t) = timed { similarGames.search(q.line, limit: 10) }
    gameTimes.append(t)
    gameResults.append((q, r))
}
let oldHits = gameQueries.filter { !similarPositions.search($0.line, limit: 10).isEmpty }.count
say("| S-b similar games, first preset (positions + structures from ply 16): \(oldHits) of \(gameQueries.count) queries with hits | | | |")
say("| S-b similar games (\(gameQueries.count) queries, \(gameResults.filter { !$0.1.isEmpty }.count) with hits) | \(ms(percentile(gameTimes, 0.5))) | \(ms(percentile(gameTimes, 0.9))) | \(ms(gameTimes.max() ?? 0)) |")

var structureTimes: [Double] = [], catalogTimes: [Double] = []
var structureResults: [(QueryCase, [SimilarStructure], [CatalogMatch])] = []
for q in positionQueries {
    let s = StructureSimilarity.structure(q.position)
    let (r, t) = timed { structures.nearest(s, limit: 10, excludingQuery: true) }
    structureTimes.append(t)
    let (c, t2) = timed { sim.nearestCatalog(s, limit: 3) }
    catalogTimes.append(t2)
    structureResults.append((q, r, c))
}
say("| E6 nearest concrete structures (of \(structures.count)) | \(ms(percentile(structureTimes, 0.5))) | \(ms(percentile(structureTimes, 0.9))) | \(ms(structureTimes.max() ?? 0)) |")
say("| E6 nearest catalog structures | \(ms(percentile(catalogTimes, 0.5))) | \(ms(percentile(catalogTimes, 0.9))) | \(ms(catalogTimes.max() ?? 0)) |")
say()

// Duplicates over the base.
let (pairs, pairTime) = timed { duplicates.pairs(minimumSimilarity: 0.8) }
say("Near duplicates (estimated Jaccard ≥ 0.8 over all positions): \(pairs.count) pairs in \(String(format: "%.1f", pairTime)) s CPU; ≥ 0.95: \(pairs.filter { $0.similarity >= 0.95 }.count).")
say()

// MARK: Hand checks

func board(_ fen: String) -> String { fen }

say("## Hand checks")
say()
say("### S-a similar positions (query = middlegame moment of a held-out game; same material, \(defaultTerms) terms; top 5)")
for (q, hits) in positionResults.filter({ !$0.1.isEmpty }).prefix(checkCount) {
    say()
    say("**Q \(q.gameIndex) ply \(q.ply)** `\(q.position.fen)` — \(q.info.eco) \(q.info.label)")
    let cat = sim.nearestCatalog(q.position, limit: 1).first
    say("structure: \(cat.map { "\($0.id) d=\($0.distance)" } ?? "-")")
    for h in hits.prefix(5) {
        say("- \(String(format: "%.2f", h.score)) g\(h.gameID) ply \(h.ply) `\(position(h.gameID, h.ply))` — \(infos[Int(h.gameID)].eco)")
    }
}
say()
say("### S-b similar endings (top 5)")
for (q, hits) in endingResults.filter({ !$0.1.isEmpty }).prefix(checkCount) {
    say()
    let f = EndingFeatures(q.position)
    say("**Q \(q.gameIndex) ply \(q.ply)** \(f.materialClass) `\(q.position.fen)`")
    for h in hits.prefix(5) {
        let fen = position(h.gameID, h.ply)
        let cls = (try? EndingFeatures(fen: fen).materialClass) ?? "?"
        say("- d=\(String(format: "%.2f", h.distance)) g\(h.gameID) ply \(h.ply) \(cls) `\(fen)`")
    }
}
say()
say("### S-b similar games (top 5)")
for (q, hits) in gameResults.filter({ !$0.1.isEmpty }).prefix(checkCount) {
    say()
    say("**Q \(q.gameIndex)** \(q.info.eco) \(q.info.label), \(q.line.positions.count - 1) plies")
    for h in hits.prefix(5) {
        say("- J≈\(String(format: "%.2f", h.similarity)) g\(h.gameID) \(infos[Int(h.gameID)].eco) \(infos[Int(h.gameID)].label)")
    }
}
say()
say("### Near-duplicate pairs (first 10 with J < 1)")
for p in pairs.filter({ $0.similarity < 1 }).prefix(checkCount) {
    say("- J≈\(String(format: "%.2f", p.similarity)) g\(p.first) \(infos[Int(p.first)].label) | g\(p.second) \(infos[Int(p.second)].label)")
}
say()
say("### E6 similar structures (top 5 concrete, top 3 catalog)")
for (q, hits, catalog) in structureResults.prefix(checkCount) {
    say()
    let s = StructureSimilarity.structure(q.position)
    say("**Q \(q.gameIndex) ply \(q.ply)** `\(s.fenPlacement)` — catalog: " + catalog.map { "\($0.id) \(String(format: "%.2f", $0.distance))" }.joined(separator: "; "))
    for h in hits.prefix(5) {
        say("- d=\(String(format: "%.1f", h.distance)) \(h.games) games `\(h.structure.fenPlacement)`")
    }
}

try report.write(toFile: reportPath, atomically: true, encoding: .utf8)
FileHandle.standardError.write("report: \(reportPath)\n".data(using: .utf8)!)
