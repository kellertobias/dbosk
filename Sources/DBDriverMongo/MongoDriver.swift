import BSON
import DBCore
import Foundation
import MongoCore
import MongoKitten

public final class MongoDriver: DatabaseDriver, Sendable {
    public static let descriptor = DriverDescriptor(
        id: "mongodb",
        displayName: "MongoDB",
        queryLanguage: .mongo,
        defaultPort: 27017,
        supportsStreaming: true,
        supportsServerSideCancel: false,
        identifierQuote: "",
        // "analyze" maps to executionStats verbosity; find/aggregate/count
        // are read-only, so it is always safe to run.
        explainSupport: .planAndAnalyze
    )

    private let state: ConnectionActor

    public init(config: ResolvedConnectionConfig) throws {
        self.state = ConnectionActor(uri: Self.buildURI(config))
    }

    public func connect() async throws {
        try await state.connect()
    }

    public func disconnect() async {
        await state.disconnect()
    }

    public func listNamespaces(parent: Namespace?) async throws -> [Namespace] {
        switch parent?.kind {
        case nil:
            let names = try await state.listDatabases()
            return names.map {
                Namespace(path: [$0], kind: .database, isExpandable: true)
            }
        case .database:
            let names = try await state.listCollections(database: parent!.name)
            return names.sorted().map {
                Namespace(
                    path: parent!.path + [$0],
                    kind: .table(.collection),
                    isExpandable: false)
            }
        default:
            return []
        }
    }

    public func listColumns(of table: Namespace) async throws -> [ColumnMeta] {
        // Collections are schemaless; sample one document for its top-level keys.
        guard table.path.count == 2 else { return [] }
        return try await state.sampleFields(
            database: table.path[0], collection: table.path[1])
    }

    public func describeTable(_ table: Namespace) async throws -> TableStructure {
        guard table.path.count == 2 else {
            return TableStructure(columns: [], indexes: [])
        }
        let fields = try await state.sampleFields(
            database: table.path[0], collection: table.path[1])
        let indexes = try await state.listIndexes(
            database: table.path[0], collection: table.path[1])
        return TableStructure(
            columns: fields.map {
                ColumnDetail(name: $0.name, dbTypeName: $0.dbTypeName)
            },
            indexes: indexes)
    }

    public func execute(_ query: DriverQuery, pageSize: Int) async throws -> QueryExecution {
        let shellQuery: MongoShellQuery
        switch query {
        case .sql(let text):
            shellQuery = try MongoQueryParser.parse(text)
        case .mongo(let collection, let operation, let body):
            shellQuery = MongoShellQuery(
                collection: collection, operation: operation, body: body)
        case .tableBrowse:
            throw DBError(
                kind: .unsupported,
                message: "MongoDB does not support structured table browsing")
        }
        return try await state.execute(shellQuery, pageSize: pageSize)
    }

    public func explain(_ query: DriverQuery, analyze: Bool) async throws -> ExplainPlan {
        let shellQuery: MongoShellQuery
        switch query {
        case .sql(let text):
            shellQuery = try MongoQueryParser.parse(text)
        case .mongo(let collection, let operation, let body):
            shellQuery = MongoShellQuery(
                collection: collection, operation: operation, body: body)
        case .tableBrowse:
            throw DBError(
                kind: .unsupported,
                message: "MongoDB does not support structured table browsing")
        }
        let reply = try await state.explain(shellQuery, analyze: analyze)
        return try ExplainPlanParser.parseMongo(reply: reply, isAnalyze: analyze)
    }

    private static func buildURI(_ config: ResolvedConnectionConfig) -> String {
        if let uri = config.uri { return uri }
        var components = URLComponents()
        components.scheme = "mongodb"
        components.host = config.host ?? "localhost"
        components.port = config.port ?? 27017
        components.user = config.user
        components.password = config.password
        components.path = "/" + (config.database ?? "admin")
        if config.user != nil {
            components.queryItems = [URLQueryItem(name: "authSource", value: "admin")]
        }
        if config.tls == .required {
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "tls", value: "true"))
            components.queryItems = items
        }
        return components.string ?? "mongodb://localhost:27017"
    }
}

// MARK: - Connection actor

private actor ConnectionActor {
    private let uri: String
    private var database: MongoDatabase?

    init(uri: String) {
        self.uri = uri
    }

    func connect() async throws {
        guard database == nil else { return }
        do {
            database = try await MongoDatabase.connect(to: uri)
        } catch {
            throw DBError(
                kind: .connectionFailed,
                message: "Could not connect to MongoDB",
                underlying: String(reflecting: error))
        }
    }

    func disconnect() async {
        database = nil
    }

    private func requireDatabase() throws -> MongoDatabase {
        guard let database else {
            throw DBError(kind: .connectionFailed, message: "Not connected")
        }
        return database
    }

    func listDatabases() async throws -> [String] {
        let database = try requireDatabase()
        do {
            return try await database.pool.listDatabases()
                .map { $0.name }
                .sorted()
        } catch {
            // Restricted users may not be allowed to run listDatabases;
            // fall back to the connected database.
            return [database.name]
        }
    }

    func listCollections(database name: String) async throws -> [String] {
        let database = try requireDatabase()
        do {
            let collections = try await database.pool[name].listCollections()
            return collections.map(\.name)
        } catch {
            throw DBError(
                kind: .queryFailed,
                message: "Could not list collections",
                underlying: String(reflecting: error))
        }
    }

    func sampleFields(
        database name: String, collection: String
    ) async throws -> [ColumnMeta] {
        let database = try requireDatabase()
        guard let sample = try? await database.pool[name][collection].findOne()
        else { return [] }
        return sample.keys.map { key in
            ColumnMeta(name: key, dbTypeName: bsonTypeName(sample[key]))
        }
    }

    func listIndexes(
        database name: String, collection: String
    ) async throws -> [IndexInfo] {
        let database = try requireDatabase()
        do {
            let raw = try await database.pool[name][collection].listIndexes().drain()
            return raw.map { index in
                // Key spec maps field → direction/type (1, -1, "text", "2dsphere"…).
                let columns = index.key.keys.map { field -> String in
                    switch index.key[field] {
                    case let direction as Int where direction < 0:
                        return "\(field) (desc)"
                    case let direction as Int32 where direction < 0:
                        return "\(field) (desc)"
                    case let kind as String:
                        return "\(field) (\(kind))"
                    default:
                        return field
                    }
                }
                return IndexInfo(
                    name: index.name,
                    columns: columns,
                    isUnique: index.unique ?? (index.name == "_id_"),
                    isPrimary: index.name == "_id_")
            }
        } catch {
            throw DBError(
                kind: .queryFailed,
                message: "Could not list indexes",
                underlying: String(reflecting: error))
        }
    }

    /// Splits "otherdb.users" into database + collection. Ambiguous for
    /// collections whose names contain a dot, but that's rare and the
    /// connected-database form still works for them.
    private func resolveTarget(
        _ target: String, connected: MongoDatabase
    ) -> (database: String, collection: String) {
        if let dot = target.firstIndex(of: "."),
           target.index(after: dot) < target.endIndex {
            return (
                String(target[..<dot]),
                String(target[target.index(after: dot)...]))
        }
        return (connected.name, target)
    }

    func execute(_ query: MongoShellQuery, pageSize: Int) async throws -> QueryExecution {
        let connected = try requireDatabase()
        let target = resolveTarget(query.collection, connected: connected)
        let collection = connected.pool[target.database][target.collection]

        switch query.operation {
        case .count:
            let filter = try BSONBridge.document(fromJSON: query.body)
            let count: Int
            do {
                count = try await collection.count(filter)
            } catch {
                throw Self.queryError(error)
            }
            return Self.singleRowExecution(
                columns: [ColumnMeta(name: "count", dbTypeName: "int")],
                values: [.int(Int64(count))])

        case .find:
            let filter = try BSONBridge.document(fromJSON: query.body)
            var find = collection.find(filter)
            if let skip = query.skip { find = find.skip(skip) }
            if let limit = query.limit { find = find.limit(limit) }
            return Self.streamDocuments(find, pageSize: pageSize)

        case .aggregate:
            var stages = try BSONBridge.pipeline(fromJSON: query.body)
            if let skip = query.skip { stages.append(["$skip": skip]) }
            if let limit = query.limit { stages.append(["$limit": limit]) }
            let pipeline = AggregateBuilderPipeline(
                stages: stages.map { RawStage(stage: $0) },
                collection: collection)
            return Self.streamDocuments(pipeline, pageSize: pageSize)
        }
    }

    /// Runs the query wrapped in the `explain` database command and returns
    /// the reply document. `analyze` requests executionStats verbosity
    /// (executes the query for real counts and timings).
    func explain(_ query: MongoShellQuery, analyze: Bool) async throws -> DBValue {
        let connected = try requireDatabase()
        let target = resolveTarget(query.collection, connected: connected)

        var inner = Document()
        switch query.operation {
        case .find:
            inner["find"] = target.collection
            inner["filter"] = try BSONBridge.document(fromJSON: query.body)
            if let skip = query.skip { inner["skip"] = skip }
            if let limit = query.limit { inner["limit"] = limit }
        case .aggregate:
            var stages = try BSONBridge.pipeline(fromJSON: query.body)
            if let skip = query.skip { stages.append(["$skip": skip]) }
            if let limit = query.limit { stages.append(["$limit": limit]) }
            inner["aggregate"] = target.collection
            inner["pipeline"] = try Document(array: stages)
            inner["cursor"] = Document()
        case .count:
            inner["count"] = target.collection
            inner["query"] = try BSONBridge.document(fromJSON: query.body)
        }

        var command = Document()
        command["explain"] = inner
        command["verbosity"] = analyze ? "executionStats" : "queryPlanner"

        do {
            let connection = try await connected.pool.next(for: .basic)
            let reply = try await connection.execute(
                command,
                namespace: MongoNamespace(to: "$cmd", inDatabase: target.database))
            guard let document = reply.documents.first else {
                throw DBError(
                    kind: .queryFailed, message: "Empty explain reply")
            }
            let ok = BSONBridge.dbValue(primitive: document["ok"]).doubleValue
            if let ok, ok != 1 {
                throw DBError(
                    kind: .queryFailed,
                    message: (document["errmsg"] as? String) ?? "Explain failed")
            }
            return BSONBridge.dbValue(document)
        } catch let error as DBError {
            throw error
        } catch {
            throw Self.queryError(error)
        }
    }

    // MARK: Streaming

    private static func streamDocuments<Cursor: QueryCursor & AsyncSequence>(
        _ cursor: Cursor, pageSize: Int
    ) -> QueryExecution where Cursor.Element == Document {
        let (stream, continuation) = AsyncThrowingStream<QueryResultChunk, Error>
            .makeStream()

        let producer = Task {
            var buffer: [ResultRow] = []
            var index = 0
            do {
                for try await document in cursor {
                    buffer.append(ResultRow(
                        id: index, values: [BSONBridge.dbValue(document)]))
                    index += 1
                    if buffer.count >= pageSize {
                        continuation.yield(QueryResultChunk(rows: buffer, isFinal: false))
                        buffer = []
                    }
                    try Task.checkCancellation()
                }
                continuation.yield(QueryResultChunk(rows: buffer, isFinal: true))
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: DBError(kind: .cancelled, message: "Query cancelled"))
            } catch {
                continuation.finish(throwing: queryError(error))
            }
        }
        continuation.onTermination = { _ in producer.cancel() }

        return QueryExecution(
            columns: [ColumnMeta(name: "document", dbTypeName: "document")],
            chunks: stream,
            cancel: { producer.cancel() })
    }

    private static func singleRowExecution(
        columns: [ColumnMeta], values: [DBValue]
    ) -> QueryExecution {
        let (stream, continuation) = AsyncThrowingStream<QueryResultChunk, Error>
            .makeStream()
        continuation.yield(QueryResultChunk(
            rows: [ResultRow(id: 0, values: values)], isFinal: true))
        continuation.finish()
        return QueryExecution(columns: columns, chunks: stream, cancel: {})
    }

    private static func queryError(_ error: Error) -> DBError {
        if let dbError = error as? DBError { return dbError }
        return DBError(
            kind: .queryFailed,
            message: (error as? CustomStringConvertible).map(\.description)
                ?? "Query failed",
            underlying: String(reflecting: error))
    }

    private func bsonTypeName(_ primitive: Primitive?) -> String {
        BSONBridge.typeName(primitive)
    }
}

/// Wraps a raw pipeline-stage document for MongoKitten's aggregate API.
private struct RawStage: AggregateBuilderStage {
    let stage: Document
    var minimalVersionRequired: WireVersion? { nil }
}
