import DBCore
import Foundation
import SotoDynamoDB

/// DynamoDB via PartiQL. Configuration mapping:
/// - host      → AWS region (e.g. "eu-central-1")
/// - user      → access key id (optional; default AWS credential chain otherwise)
/// - password  → secret access key
/// - uri       → custom endpoint (dynamodb-local, LocalStack)
public final class DynamoDBDriver: DatabaseDriver, Sendable {
    public static let descriptor = DriverDescriptor(
        id: "dynamodb",
        displayName: "DynamoDB",
        queryLanguage: .partiql,
        defaultPort: nil,
        supportsStreaming: true,
        supportsServerSideCancel: false
    )

    private let state: ClientActor

    public init(config: ResolvedConnectionConfig) throws {
        self.state = ClientActor(config: config)
    }

    public func connect() async throws {
        try await state.connect()
    }

    public func disconnect() async {
        await state.disconnect()
    }

    public func listNamespaces(parent: Namespace?) async throws -> [Namespace] {
        guard parent == nil else { return [] }
        let names = try await state.listTables()
        return names.map {
            Namespace(path: [$0], kind: .table(.table), isExpandable: false)
        }
    }

    public func listColumns(of table: Namespace) async throws -> [ColumnMeta] {
        guard let name = table.path.last else { return [] }
        return try await state.keyColumns(table: name)
    }

    public func describeTable(_ table: Namespace) async throws -> TableStructure {
        guard let name = table.path.last else {
            return TableStructure(columns: [], indexes: [])
        }
        return try await state.tableStructure(table: name)
    }

    public func execute(_ query: DriverQuery, pageSize: Int) async throws -> QueryExecution {
        guard case .sql(let statement) = query else {
            throw DBError(kind: .unsupported, message: "DynamoDB driver only accepts PartiQL")
        }
        return await state.executeStatement(statement, pageSize: pageSize)
    }
}

// MARK: - Client actor

private actor ClientActor {
    private let config: ResolvedConnectionConfig
    private var client: AWSClient?
    private var dynamoDB: DynamoDB?

    init(config: ResolvedConnectionConfig) {
        self.config = config
    }

    func connect() async throws {
        guard client == nil else { return }
        let credentialProvider: CredentialProviderFactory
        if let user = config.user, let password = config.password {
            credentialProvider = .static(accessKeyId: user, secretAccessKey: password)
        } else {
            credentialProvider = .default
        }
        let awsClient = AWSClient(credentialProvider: credentialProvider)
        let region = config.host.map { Region(rawValue: $0) } ?? .useast1
        let service = DynamoDB(client: awsClient, region: region, endpoint: config.uri)
        // Validate the connection/credentials with a cheap call.
        do {
            _ = try await service.listTables(DynamoDB.ListTablesInput(limit: 1))
        } catch {
            try? await awsClient.shutdown()
            throw DBError(
                kind: .connectionFailed,
                message: "Could not reach DynamoDB",
                underlying: String(reflecting: error))
        }
        client = awsClient
        dynamoDB = service
    }

    func disconnect() async {
        dynamoDB = nil
        if let client {
            try? await client.shutdown()
        }
        client = nil
    }

    private func requireService() throws -> DynamoDB {
        guard let dynamoDB else {
            throw DBError(kind: .connectionFailed, message: "Not connected")
        }
        return dynamoDB
    }

    func listTables() async throws -> [String] {
        let service = try requireService()
        var names: [String] = []
        var start: String?
        repeat {
            let output = try await service.listTables(
                DynamoDB.ListTablesInput(exclusiveStartTableName: start))
            names += output.tableNames ?? []
            start = output.lastEvaluatedTableName
        } while start != nil
        return names.sorted()
    }

    func keyColumns(table: String) async throws -> [ColumnMeta] {
        let service = try requireService()
        let output = try await service.describeTable(
            DynamoDB.DescribeTableInput(tableName: table))
        guard let description = output.table else { return [] }
        let types = Dictionary(
            uniqueKeysWithValues: (description.attributeDefinitions ?? []).map {
                ($0.attributeName, $0.attributeType.rawValue)
            })
        return (description.keySchema ?? []).map { key in
            ColumnMeta(
                name: key.attributeName,
                dbTypeName: "\(types[key.attributeName] ?? "?") · \(key.keyType.rawValue)")
        }
    }

    /// Key schema as columns; primary key + GSIs/LSIs as "indexes".
    func tableStructure(table: String) async throws -> TableStructure {
        let service = try requireService()
        let output = try await service.describeTable(
            DynamoDB.DescribeTableInput(tableName: table))
        guard let description = output.table else {
            return TableStructure(columns: [], indexes: [])
        }
        let types = Dictionary(
            uniqueKeysWithValues: (description.attributeDefinitions ?? []).map {
                ($0.attributeName, $0.attributeType.rawValue)
            })
        func keyColumns(_ schema: [DynamoDB.KeySchemaElement]?) -> [String] {
            (schema ?? []).map { "\($0.attributeName) (\($0.keyType.rawValue))" }
        }

        let columns = (description.keySchema ?? []).map { key in
            ColumnDetail(
                name: key.attributeName,
                dbTypeName: types[key.attributeName] ?? "?",
                isNullable: false,
                isPrimaryKey: true)
        }
        var indexes = [IndexInfo(
            name: "PRIMARY KEY",
            columns: keyColumns(description.keySchema),
            isUnique: true,
            isPrimary: true)]
        indexes += (description.globalSecondaryIndexes ?? []).map {
            IndexInfo(
                name: $0.indexName ?? "GSI",
                columns: keyColumns($0.keySchema),
                isUnique: false,
                method: "GSI")
        }
        indexes += (description.localSecondaryIndexes ?? []).map {
            IndexInfo(
                name: $0.indexName ?? "LSI",
                columns: keyColumns($0.keySchema),
                isUnique: false,
                method: "LSI")
        }
        return TableStructure(columns: columns, indexes: indexes)
    }

    func executeStatement(_ statement: String, pageSize: Int) async -> QueryExecution {
        let (stream, continuation) = AsyncThrowingStream<QueryResultChunk, Error>
            .makeStream()

        let producer = Task {
            do {
                let service = try requireService()
                var nextToken: String?
                var index = 0
                repeat {
                    let output = try await service.executeStatement(
                        DynamoDB.ExecuteStatementInput(
                            limit: pageSize,
                            nextToken: nextToken,
                            statement: statement))
                    nextToken = output.nextToken
                    let rows = (output.items ?? []).map { item in
                        defer { index += 1 }
                        return ResultRow(
                            id: index,
                            values: [AttributeValueMapper.document(item)])
                    }
                    continuation.yield(QueryResultChunk(
                        rows: rows, isFinal: nextToken == nil))
                    try Task.checkCancellation()
                } while nextToken != nil
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: DBError(kind: .cancelled, message: "Query cancelled"))
            } catch {
                continuation.finish(throwing: DBError(
                    kind: .queryFailed,
                    message: Self.friendlyMessage(for: error),
                    underlying: String(reflecting: error)))
            }
        }
        continuation.onTermination = { _ in producer.cancel() }

        return QueryExecution(
            columns: [ColumnMeta(name: "document", dbTypeName: "document")],
            chunks: stream,
            cancel: { producer.cancel() })
    }

    private static func friendlyMessage(for error: Error) -> String {
        if let awsError = error as? AWSErrorType {
            return awsError.message ?? String(describing: awsError)
        }
        return "Query failed"
    }
}

// MARK: - Value mapping

enum AttributeValueMapper {
    static func document(_ item: [String: DynamoDB.AttributeValue]) -> DBValue {
        .document(item.mapValues { value($0) })
    }

    static func value(_ attribute: DynamoDB.AttributeValue) -> DBValue {
        switch attribute {
        case .s(let string):
            return .string(string)
        case .n(let number):
            return .decimal(number)
        case .bool(let bool):
            return .bool(bool)
        case .null:
            return .null
        case .b(let data):
            return .bytes((data.decoded() as [UInt8]?).map { Data($0) } ?? Data())
        case .l(let list):
            return .array(list.map { value($0) })
        case .m(let map):
            return .document(map.mapValues { value($0) })
        case .ss(let strings):
            return .array(strings.map { .string($0) })
        case .ns(let numbers):
            return .array(numbers.map { .decimal($0) })
        case .bs(let blobs):
            return .array(blobs.map {
                .bytes(($0.decoded() as [UInt8]?).map { Data($0) } ?? Data())
            })
        }
    }
}
