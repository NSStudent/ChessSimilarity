# ChessSimilarity

Find «similar» things in chess databases, in Swift and without neural networks:

- **Similar positions (S-a)**: each position becomes a document of terms (piece on square, reachable squares, attacks and defences, pawn structure, king safety, material and mobility) ranked with BM25, either in SQLite FTS5 or in an in-memory index that gives the same scores. Each game contributes 2–3 «moments».
- **Similar endings (S-b)**: an ending feature vector (material, pawn islands, passed pawns, king activity) with a weighted distance.
- **Similar games and near duplicates (S-b)**: MinHash signatures of the game's positions or pawn structures, in LSH buckets.
- **Similar pawn structures (E6, phase 1)**: a rule-based distance to the catalog of [ChessPawnStructures](https://github.com/NSStudent/ChessPawnStructures) and to the concrete structures of a database.

Every entry point takes `[ResolvedMove]` from [fischer-core](https://github.com/NSStudent/fischer-core) or a FEN.

- Swift 6, iOS 18 / macOS 15. Depends on `fischer-core` (≥ 0.4.0) and `ChessPawnStructures` (≥ 0.1.0).
- FTS5 uses the system SQLite (`import SQLite3`); the in-memory index needs no SQLite.

```swift
.package(url: "https://github.com/NSStudent/ChessSimilarity.git", from: "0.1.0")
```

## Usage

```swift
import ChessSimilarity

// Input: fischer-core moves (or SAN, or a FEN).
let line = try GameLine(moves: resolvedMoves, startFEN: nil)      // the position after each ply
let line2 = try GameLine(san: ["d4", "d5", "c4", "e6"])
let position = try SimilarityPosition(fen: "r1bq1rk1/pp2bppp/2n1pn2/8/3P4/2NB1N2/PP3PPP/R1BQ1RK1 w")

// S-a · similar positions in SQLite FTS5 (its own file, or the app's connection).
let fts = try FTS5PositionIndex(path: "similar.sqlite")
try fts.beginBatch()
try fts.add(gameID: 42, line: line)                 // 2–3 moments of the game
try fts.commit()
try fts.optimize()
let hits = try fts.search(position, options: PositionQueryOptions(limit: 10, material: .exact))
// [SimilarPosition(gameID:, ply:, score:)], one per game, best first

// … or in memory, with the same scores.
var memory = InMemoryPositionIndex()
memory.add(gameID: 42, line: line)
memory.search(position)

// S-b · endings.
var endings = EndingIndex()
endings.add(gameID: 42, line: line)                 // the first quiet ending position of the game
endings.search(position, limit: 10)                 // [SimilarEnding(gameID:, ply:, distance:)]

// S-b · similar games and near duplicates.
var games = GameSimilarityIndex()                   // pawn structures from ply 8, LSH 16×2
games.add(gameID: 42, line: line)
games.search(line2, limit: 10)                      // [SimilarGame(gameID:, similarity:)]
var dups = GameSimilarityIndex.nearDuplicates()     // every position, LSH 8×4
dups.pairs(minimumSimilarity: 0.8)                  // [SimilarGamePair]

// E6 · pawn structures.
let sim = StructureSimilarity()
sim.nearestCatalog(position, limit: 3)              // [CatalogMatch(id:, distance:, matches:)]
var structures = StructureIndex()                   // distinct structures of the base (plies ≥ 14)
structures.add(gameID: 42, line: line)
structures.nearest(StructureSimilarity.structure(position), limit: 10, excludingQuery: true)
sim.distance(positionA, positionB)                  // structure plus piece motifs
```

To keep the FTS5 table inside an app's own database, use the SQL of `PositionFTS5Schema` (`createTable`, `insert`, `ranking`, `matchExpression`) and `PositionTerms(position).columnTexts`.

## Design

### S-a · Terms + BM25 (Ganguly, Leveling and Jones, SIGIR 2014)

The idea comes from *Retrieval of Similar Chess Positions*: a position is a document, and similarity is what a search engine computes. Terms are lowercase ASCII strings, unique per column, and each column is an FTS5 column with its own weight in `bm25()`:

| Column | Examples | What it holds | Weight |
|---|---|---|--:|
| `pieces` | `wnf3`, `bpe5` | piece on square (colour, piece, square) | 1 |
| `reach` | `rwnd5` | squares each piece (not pawns) reaches in one move: the paper's «term propagation», without decay | 0.5 |
| `links` | `xwnf3bpe5`, `dwbe2wnf3` | attacks (`x`) / defends (`d`) piece on square: the paper's connectivity terms | 0.75 |
| `pawns` | `s04`, `s04r`, `wisod`, `bpasc`, `opne`, `mjqw` | catalog structures (ChessPawnStructures, also colour-reversed), isolated, doubled, passed, backward and hanging pawns, half-open and open files, islands, majorities | 1 |
| `king` | `wkfk`, `wsh2`, `bko1`, `wkz3`, `bka2`, `chk` | king flank and rank, pawn shield, files without own pawns next to the king, attacked squares of the king zone, enemy pieces aiming at it, check | 0.75 |
| `balance` | `cwr2`, `balw1`, `wbpair`, `ocb`, `wmob3`, `wmobn2`, `stmw` | material counts, balance, bishop pair, opposite-coloured bishops, mobility classes, side to move | 0.5 |
| `material` | `m1222812228` | exact material (Q R B N P of each side); a hard filter with weight 0 | 0 |

- **Material filter first**, as ChessBase does («Search for similar middlegame»: same material relation). `MaterialFilter.exact` requires the same material; `.pawnTolerance(n)` accepts ±n pawns per side (up to 9 keys). The FTS5 query is `(m… OR m…) AND (t1 OR t2 OR …)`; since no term appears in two columns, no column filter is needed.
- **BM25 as in FTS5**: `BM25Parameters` reproduces FTS5's `bm25()` (k1 = 1.2, b = 0.75, IDF floored at 1e-6, frequency = sum of column weights). A test compares FTS5 with the in-memory index position by position.
- **Re-ranking**: one position per game, the best one (the paper's last step, and what ChessBase shows).
- **Query pruning**: `PositionQueryOptions.maximumTerms` (48 by default, out of about 160) keeps the terms with the largest `IDF × column weight`. This is what makes FTS5 usable on large bases (see Measurements); `nil` gives exact BM25 over every term.
- **Moments**: end of the opening (ply 24), middlegame (ply 50) and the start of the ending, each at the first *quiet* ply from its target (no capture on the previous move, no check), at least 10 plies apart; the ending wins over a nearby middlegame ply. Short games keep their final position. That gives 2–3 documents per game instead of 80.
- **Contentless FTS5 table** (`content=''`): only the index is stored, not the text. It keeps `detail=full`: with `detail=column` a contentless table cannot tell which columns hold a hit, and `bm25()` returns 0 for every row (checked with SQLite 3.54).
- Not taken from the paper: ray (x-ray) terms, which did not help on their own, and the distance decay of reachable squares (one step only).

### S-b · Endings: features and distance

`EndingFeatures` (about 50 bytes packed): Q R B N P counts per side, bishop square colours, pawn bitboards, islands, passed, isolated and doubled pawns, rank of the most advanced passed pawn, king distance to the centre, king rank, and king distance to the nearest own and enemy passed pawn. `EndingDistance` is a weighted L1 distance; material weighs more than any feature (a different piece is never closer than a pawn on another square), and it also compares with colours reversed and mirrored a↔h. `EndingIndex` stores the first quiet ending position of each game (`EndingPhase`: no queens and at most 11 points of pieces per side, or at most 9 with queens) and searches the bucket with the same pieces (a hard filter; pawns may differ).

### S-b · Similar games: MinHash + LSH (Broder 1997; Li and König 2010)

For **near duplicates** the set of a game is the Zobrist keys of all its positions (placement and side to move, no castling or en passant, so transpositions match). For **similar games** it is the game's pawn structures from ply 8 on (pawn-only keys, the «pawn hash» of chess engines): two games of the same line share structures through the opening and middlegame, but past the opening they almost never share exact positions (see Measurements). The signature keeps the low 16 bits of the minimum of 32 hashes (b-bit MinHash): 64 bytes per game. The estimated Jaccard similarity is corrected for 16-bit collisions. LSH: 16 bands × 2 rows (threshold ≈ 0.25) for similar games and 8 × 4 (≈ 0.59) for duplicates; `pairs(minimumSimilarity:)` walks the buckets for deduplication.

### E6 · Similar structures by rules (phase 1)

- **Against the catalog**: each ChessPawnStructures structure is a pattern (required squares, alternatives, files that must be empty or occupied). `PatternDistance` counts what is missing to meet it, in Hamming units: a required square with an own pawn on the same file 1, without one 2; a group of alternatives, its cheapest square; a pawn on a file that must be empty 1.5; a file that must have a pawn 2; the majority rule 3; «typical» squares that are not required 0.25 (tie-break). Distance 0 means the rule and its typical squares are met.
- **Against concrete structures**: `StructureDistance` from ChessPawnStructures 0.1.0 (pawn Hamming distance plus traits: isolated, doubled, passed and backward pawns, islands, hanging pawns, files, majorities). `StructureIndex` keeps the distinct structures of a base with their number of games (skipping structures that last fewer than 4 plies, such as the half-finished exchange between a capture and its recapture) and searches with an exact bound: it sorts by Hamming distance (two popcounts) and computes the full distance only while `Hamming × weight` can still beat the k-th best. The traits of each structure are stored in 16 bytes.
- **Piece motifs** from ChessBase's «Similar structures»: `StructureSimilarity.distance(_:_:)` adds a rook on an open or half-open file, kings on the same flank and opposite-coloured bishops.
- Phase 2 (binarised embeddings, for example ChessLM or the penultimate layer of Maia-2) is out of scope.

## Measurements

First 100,000 games of Lumbras Gigabase OTB 2025 (99,998 readable), queried with the next 100 games (outside the index). Mac M2 Pro, Release build, **CPU time of one thread** (the machine was shared, so wall time is unreliable). Full report: [`measurements/bench-100k.md`](measurements/bench-100k.md). Turning SAN into positions with fischer-core is not part of these figures.

### Build and size

| Part | CPU per game | Size (100 k) | Per game |
|---|--:|--:|--:|
| S-a terms (2.15 moments per game, 160 terms per document) | 31.7 µs | — | — |
| S-a FTS5 insert | 78.8 µs | 209.1 MB | 2,091 B |
| S-a compact FTS5 (no `reach` or `links`), terms + insert | 44.2 µs | 93.9 MB | 939 B |
| S-a FTS5 `optimize` (once) | 1.7 s in total | | |
| S-b endings (48,593 games with an ending) | 5.4 µs | 2.4 MB packed | 24 B |
| S-b similar games (MinHash 32 × 16 bits, LSH 16 × 2) | 9.0 µs | 12.8 MB | 128 B |
| S-b near duplicates (MinHash 32 × 16 bits, LSH 8 × 4) | 13.3 µs | 9.6 MB | 96 B |
| E6 distinct structures (570,485; plies ≥ 14, lasting ≥ 4 plies) | 2.5 µs | 20.5 MB | 205 B |

All parts together take about 140 µs of CPU per game (14 s for 100 k games on one thread).

**Index size of S-a**: 2.1 KB per game means about **28 GB for 13.4 M games** (12.6 GB for the compact variant), and 4.2 GB (1.9 GB compact) for a 2 M-game master base. Plan storage for that before indexing large reference bases; on a phone only small bases fit.

### Queries

| Query | Median | p90 | Max |
|---|--:|--:|--:|
| S-a FTS5, same material, every term (~160) | 198 ms | 413 ms | 871 ms |
| S-a FTS5, same material, 24 terms (50 % of the full query's top 10) | 2.6 ms | 13.3 ms | 36.2 ms |
| **S-a FTS5, same material, 48 terms (default; 80 % of the top 10)** | **13.0 ms** | **44.4 ms** | **80.5 ms** |
| S-a FTS5, same material, 64 terms (85 % of the top 10) | 24.0 ms | 65.7 ms | 114 ms |
| S-a compact FTS5, 48 terms (68 % of the full index's top 10) | 52.8 ms | 110 ms | 334 ms |
| S-a FTS5, pawns ±1, 48 terms | 16.8 ms | 73.4 ms | 125 ms |
| S-b endings, same pieces (39 of 39 queries with hits) | 0.52 ms | 1.09 ms | 1.50 ms |
| S-b endings, all 48,593 | 8.9 ms | 9.1 ms | 9.2 ms |
| S-b similar games (44 of 91 queries with hits) | 0.01 ms | 0.09 ms | 0.72 ms |
| E6 nearest concrete structures (of 570,485) | 2.9 ms | 8.1 ms | 8.4 ms |
| E6 nearest catalog structures | 0.01 ms | 0.01 ms | 0.04 ms |
| Near duplicates of the whole base (`pairs(minimumSimilarity: 0.8)`) | < 0.1 s | | |

- **Why S-a prunes terms**: FTS5's cost grows with the summed length of the posting lists of the query terms (11.8 M entries for ~200 terms in an opening position). Both `MATCH` and the IDF of `bm25()` walk them in full, even when the material filter leaves only 18,787 rows. `maximumTerms` keeps the terms with the largest `IDF × column weight`, which weigh most in BM25, and reads the frequencies from the vocabulary once (60 k terms, 0.8 s). Querying `fts5vocab` term by term costs about 1 ms per term.
- 7 of 91 queries have no position with the same material in 100 k games; `.pawnTolerance(1)` widens the filter.
- The first design of «similar games» (positions plus structures from ply 16) found hits for only 2 of 91 queries: past the opening two games rarely share exact positions. With pawn structures from ply 8 it is 44 of 91.
- Near duplicates: 2,062 pairs with estimated Jaccard ≥ 0.8 (1,829 with ≥ 0.95) in 100 k games.

### Hand check (10 queries per part)

A hit is relevant if a player would accept it as «similar» in the sense of that part. The queries and hits are not in the repository (the source database is CC BY-NC).

| Part | Relevant | Notes |
|---|--:|---|
| S-a positions (top 5, 48 terms) | 26 of 50; top 1: 7 of 10 | At the end of the opening (ply 24) 12 of 15 share the piece and pawn placement (a Slav with Bf4/Be2/Nc3/Nf3 returns five Slav/Queen's Gambit positions with the same set-up). At ply 50, 14 of 35: they share material and some motifs, but late middlegame positions hardly repeat in 100 k games. |
| S-b endings (top 5) | 33 of 50; top 1: 8 of 10 | Always the same pieces (hard filter); the best hits share the number and kind of passed pawns and the pawn placement. Weaker in endings with many pawns (6 v 6), where the vector says little. |
| S-b similar games (top 5) | 21 of 39 with the same opening (ECO) | 10 of the 39 hits have no ECO tag. Very good on theoretical lines (B33, D35–D37, B10, C56); weak on irregular openings. |
| S-b near duplicates (10 pairs) | 10 of 10 | The same game stored twice under two event names. |
| E6 concrete structures (top 5) | 27 of 50 at distance ≤ 4 | 7 of 10 queries have their first hit at ≤ 4 (one or two pawns moved); for 3 rare structures the nearest is at 8–12. |
| E6 catalog (first) | 3 of 4 right when the distance is ≤ 1 | Open King's Indian exact (0); closed Ruy Lopez and reversed Caro-Kann at 1. «French Type III» for a Slav structure with …b5 is debatable. Above distance 2 the catalog does not describe the structure, and it is better not to show a name. |

## Tool

```sh
swift build -c release --product chess-similarity-tool
.build/release/chess-similarity-tool bench games.pgn --games 100000 --queries 100 --checks 10 \
    --work /tmp/chess-similarity --report report.md
.build/release/chess-similarity-tool terms "<fen>"     # the terms and FTS5 query of a position
```

`bench` reads the first N games, builds every index, queries them with the next Q games (outside the index) and writes a report with times, sizes and the queries to check by hand. Times are thread CPU time, not wall time.

## References

- D. Ganguly, J. Leveling, G. J. F. Jones. *Retrieval of Similar Chess Positions*. SIGIR 2014, 687–696. DOI 10.1145/2600428.2609605.
- ChessBase. *Search for similar middlegame* / *Similar structures* (ChessBase 13–18 help).
- A. Z. Broder. *On the resemblance and containment of documents*. SEQUENCES 1997.
- P. Li, A. C. König. *b-Bit Minwise Hashing*. WWW 2010.
- Chess Programming Wiki. *Pawn Hash Table*.
- M. Flores Rios. *Chess Structures: A Grandmaster Guide*. Quality Chess, 2015 (the catalog of ChessPawnStructures).
- S. Robertson, H. Zaragoza. *The Probabilistic Relevance Framework: BM25 and Beyond*. 2009; SQLite FTS5, the `bm25()` function.

## License

MIT. The test games are public-domain classics (Morphy 1858, Anderssen 1851) and hand-written opening lines; there is no third-party database content.
