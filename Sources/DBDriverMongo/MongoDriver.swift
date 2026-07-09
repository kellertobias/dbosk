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
        identifierQuote: ""
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
        }
        return try await state.execute(shellQuery, pageSize: pageSize)
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

    func execute(_ query: MongoShellQuery, pageSize: Int) async throws -> QueryExecution {
        let connected = try requireDatabase()
        // "otherdb.users" targets a collection in another database. Ambiguous
        // for collections whose names contain a dot, but that's rare and the
        // connected-database form still works for them.
        let collection: MongoCollection
        if let dot = query.collection.firstIndex(of: "."),
           query.collection.index(after: dot) < query.collection.endIndex {
            let databaseName = String(query.collection[..<dot])
            let collectionName = String(query.collection[query.collection.index(after: dot)...])
            collection = connected.pool[databaseName][collectionName]
        } else {
            collection = connected[query.collection]
        }

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
