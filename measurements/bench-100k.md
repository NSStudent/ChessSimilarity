# ChessSimilarity bench

- Source: LumbrasGigabase_OTB_2025.pgn, first 100000 games; 99998 indexed, 2 unreadable or empty.
- Queries: games 100000…100099 (held out).
- Times are CPU time of one thread (the machine is shared). Parse (SAN → positions, 4 threads) took 15.1 s of wall time and is not part of the build times.

## Build

| Part | CPU per game | Size | Per game |
|---|--:|--:|--:|
| S-a terms (214553 docs, 2.15 per game, 160 terms per doc) | 31.7 µs | — | — |
| S-a FTS5 insert | 78.8 µs | 209.1 MB | 2091 B |
| S-a compact FTS5 (no reach or links): terms + insert | 44.2 µs | 93.9 MB | 939 B |
| S-a FTS5 optimize (once) | 1.7 s | | |
| S-b endings (48593 with an ending) | 5.4 µs | 2.4 MB packed | 24 B |
| S-b similar games (MinHash 16×2) | 9.0 µs | 12.8 MB | 128 B |
| S-b near duplicates (MinHash 8×4) | 13.4 µs | 9.6 MB | 96 B |
| E6 distinct structures (570485, plies ≥ 14) | 2.5 µs | 20.5 MB | 205 B |

## Queries

| Query | Median | p90 | Max |
|---|--:|--:|--:|
| S-a FTS5, same material, all terms (91 queries, 7 without hits) | 198.08 ms | 412.71 ms | 870.81 ms |
| S-a FTS5, same material, 24 terms (top-10 games shared with all terms: 50 %) | 2.57 ms | 13.32 ms | 36.19 ms |
| S-a FTS5, same material, 48 terms (top-10 games shared with all terms: 80 %) | 12.95 ms | 44.42 ms | 80.47 ms |
| S-a FTS5, same material, 64 terms (top-10 games shared with all terms: 85 %) | 23.96 ms | 65.74 ms | 114.01 ms |
| S-a compact FTS5, same material, 48 terms (top-10 games shared with the full index, all terms: 68 %) | 52.84 ms | 109.63 ms | 333.50 ms |
| S-a FTS5, pawns ±1, 48 terms | 16.80 ms | 73.44 ms | 125.30 ms |
| S-b endings, same pieces (39 queries, 39 with hits) | 0.58 ms | 1.11 ms | 1.31 ms |
| S-b endings, all 48593 | 8.93 ms | 9.30 ms | 10.73 ms |
| S-b similar games, first preset (positions + structures from ply 16): 2 of 91 queries with hits | | | |
| S-b similar games (91 queries, 44 with hits) | 0.01 ms | 0.06 ms | 0.74 ms |
| E6 nearest concrete structures (of 570485) | 2.96 ms | 8.13 ms | 8.44 ms |
| E6 nearest catalog structures | 0.01 ms | 0.01 ms | 0.04 ms |

Near duplicates (estimated Jaccard ≥ 0.8 over all positions): 2062 pairs in 0.0 s CPU; ≥ 0.95: 1829.

