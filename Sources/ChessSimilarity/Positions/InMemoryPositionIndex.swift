//
//  InMemoryPositionIndex.swift
//  ChessSimilarity
//

/// A pure-Swift inverted index with the same BM25 as ``FTS5PositionIndex``.
///
/// Meant for tests, small bases and platforms without FTS5. Postings hold document
/// numbers only, because no term repeats inside a column.
public struct InMemoryPositionIndex: Sendable {
    public var parameters: BM25Parameters
    public var termOptions: TermOptions

    private var termIDs: [String: Int32] = [:]
    private var termColumns: [UInt8] = []
    private var postings: [[Int32]] = []
    private var documentIDs: [Int64] = []
    private var lengths: [UInt16] = []
    private var materialDocuments: [String: [Int32]] = [:]
    private var totalLength = 0

    public init(parameters: BM25Parameters = .standard, termOptions: TermOptions = TermOptions()) {
        self.parameters = parameters
        self.termOptions = termOptions
    }

    public var documentCount: Int { documentIDs.count }
    public var termCount: Int { termIDs.count }
    public var postingCount: Int { postings.reduce(0) { $0 + $1.count } }
    public var averageLength: Double { documentIDs.isEmpty ? 0 : Double(totalLength) / Double(documentIDs.count) }

    /// Documents containing `term`.
    public func documentFrequency(_ term: String) -> Int {
        termIDs[term].map { postings[Int($0)].count } ?? 0
    }

    /// Adds one position.
    public mutating func add(gameID: Int64, ply: Int, terms: PositionTerms) {
        let doc = Int32(documentIDs.count)
        documentIDs.append(PositionDocumentID.make(gameID: gameID, ply: ply))
        let length = terms.count
        lengths.append(UInt16(min(length, Int(UInt16.max))))
        totalLength += length
        for column in TermColumn.allCases {
            for term in terms[column] {
                let id: Int32
                if let existing = termIDs[term] {
                    id = existing
                } else {
                    id = Int32(postings.count)
                    termIDs[term] = id
                    termColumns.append(UInt8(column.rawValue))
                    postings.append([])
                }
                postings[Int(id)].append(doc)
            }
        }
        materialDocuments[terms.materialKey, default: []].append(doc)
    }

    /// Adds one position.
    public mutating func add(gameID: Int64, ply: Int, position: SimilarityPosition) {
        add(gameID: gameID, ply: ply, terms: PositionTerms(position, options: termOptions))
    }

    /// Adds the moments of a game and returns them.
    @discardableResult
    public mutating func add(gameID: Int64, line: GameLine, policy: MomentPolicy = MomentPolicy()) -> [Moment] {
        let moments = policy.moments(of: line)
        for m in moments { add(gameID: gameID, ply: m.ply, position: line.positions[m.ply]) }
        return moments
    }

    /// The most similar indexed positions to `position`.
    public func search(_ position: SimilarityPosition, options: PositionQueryOptions = PositionQueryOptions()) -> [SimilarPosition] {
        search(PositionTerms(position, options: termOptions), materialKeys: options.material.keys(for: position), options: options)
    }

    /// The most similar indexed positions to the query terms.
    public func search(_ terms: PositionTerms, materialKeys: [String]?, options: PositionQueryOptions = PositionQueryOptions()) -> [SimilarPosition] {
        let n = documentIDs.count
        guard n > 0 else { return [] }
        let terms = terms.pruned(documents: n, frequency: documentFrequency, weights: parameters, options: options)
        var candidate: [Bool]?
        if let keys = materialKeys {
            var mask = [Bool](repeating: false, count: n)
            var any = false
            for key in keys { for d in materialDocuments[key] ?? [] { mask[Int(d)] = true; any = true } }
            guard any else { return [] }
            candidate = mask
        }
        let avg = averageLength
        var scores = [Double](repeating: 0, count: n)
        var touched = [Bool](repeating: false, count: n)
        var seen = Set<String>()
        // As in the FTS5 query, the material token only filters: it neither scores nor matches.
        for column in TermColumn.allCases where column != .material {
            for term in terms[column] where seen.insert(term).inserted {
                guard let id = termIDs[term] else { continue }
                let list = postings[Int(id)]
                let idf = BM25Parameters.idf(documents: n, containing: list.count)
                let f = parameters.columnWeights[Int(termColumns[Int(id)])]
                for d in list {
                    let doc = Int(d)
                    if let candidate, !candidate[doc] { continue }
                    touched[doc] = true
                    guard f > 0 else { continue }
                    scores[doc] += parameters.termScore(idf: idf, frequency: f, length: Double(lengths[doc]), averageLength: avg)
                }
            }
        }
        var hits: [SimilarPosition] = []
        for doc in 0 ..< n where touched[doc] {
            let id = documentIDs[doc]
            hits.append(SimilarPosition(gameID: PositionDocumentID.gameID(id), ply: PositionDocumentID.ply(id), score: scores[doc]))
        }
        return hits.ranked(options)
    }
}
