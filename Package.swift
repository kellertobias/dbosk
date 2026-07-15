// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "dbosk",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DBCore", targets: ["DBCore"]),
        .library(name: "DBDriverPostgres", targets: ["DBDriverPostgres"]),
        .library(name: "Connections", targets: ["Connections"]),
        .executable(name: "dbOSK", targets: ["Dbosk"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/vapor/mysql-nio.git", from: "1.7.0"),
        .package(url: "https://github.com/orlandos-nl/MongoKitten.git", from: "7.9.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/swift-server/RediStack.git", from: "1.6.0"),
        .package(url: "https://github.com/soto-project/soto.git", from: "7.0.0"),
        // Pre-1.0 SDK, pinned to a commit: the 0.9.0 release does not compile
        // under Swift 6.3's stricter sendability checking, main does. All SDK
        // types stay inside the MCPServer target.
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk.git",
            revision: "a0ae212ebf6eab5f754c3129608bc5557637e605"),
        // Already in the transitive graph via postgres-nio and friends; the
        // MCP HTTP bridge uses it directly.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(name: "DBCore"),
        .target(
            name: "DBDriverPostgres",
            dependencies: [
                "DBCore",
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "DBDriverMySQL",
            dependencies: [
                "DBCore",
                .product(name: "MySQLNIO", package: "mysql-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "DBDriverMongo",
            dependencies: [
                "DBCore",
                .product(name: "MongoKitten", package: "MongoKitten"),
            ]
        ),
        .target(
            name: "DBDriverSQLite",
            dependencies: [
                "DBCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "DBDriverRedis",
            dependencies: [
                "DBCore",
                .product(name: "RediStack", package: "RediStack"),
            ]
        ),
        .target(
            name: "DBDriverDynamoDB",
            dependencies: [
                "DBCore",
                .product(name: "SotoDynamoDB", package: "soto"),
            ]
        ),
        .target(
            name: "DBDriverMetabase",
            dependencies: ["DBCore"]
        ),
        .target(
            name: "Connections",
            dependencies: [
                "DBCore",
                .product(name: "SotoSecretsManager", package: "soto"),
            ]
        ),
        .target(
            name: "MCPServer",
            dependencies: [
                "DBCore",
                "Connections",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(name: "Export", dependencies: ["DBCore"]),
        .target(name: "QueryEditor", dependencies: ["DBCore"]),
        .executableTarget(
            name: "Dbosk",
            dependencies: [
                "DBCore", "DBDriverPostgres", "DBDriverMySQL", "DBDriverMongo",
                "DBDriverSQLite", "DBDriverRedis", "DBDriverDynamoDB", "DBDriverMetabase",
                "Connections", "Export", "QueryEditor", "MCPServer",
            ]
        ),
        .testTarget(name: "DBCoreTests", dependencies: ["DBCore"]),
        .testTarget(name: "DboskTests", dependencies: ["Dbosk"]),
        .testTarget(
            name: "DBDriverPostgresTests",
            dependencies: ["DBDriverPostgres", "Connections"]),
        .testTarget(name: "DBDriverMySQLTests", dependencies: ["DBDriverMySQL"]),
        .testTarget(name: "DBDriverMongoTests", dependencies: ["DBDriverMongo"]),
        .testTarget(name: "DBDriverSQLiteTests", dependencies: ["DBDriverSQLite"]),
        .testTarget(name: "DBDriverRedisTests", dependencies: ["DBDriverRedis"]),
        .testTarget(name: "DBDriverDynamoDBTests", dependencies: ["DBDriverDynamoDB"]),
        .testTarget(name: "DBDriverMetabaseTests", dependencies: ["DBDriverMetabase"]),
        .testTarget(name: "ConnectionsTests", dependencies: ["Connections"]),
        .testTarget(name: "MCPServerTests", dependencies: ["MCPServer"]),
        .testTarget(name: "ExportTests", dependencies: ["Export"]),
        .testTarget(name: "QueryEditorTests", dependencies: ["QueryEditor"]),
    ]
)
