# dbosk

A native macOS database client (SwiftUI + AppKit) for PostgreSQL, MySQL/MariaDB,
MongoDB, and SQLite. Streaming results, cancellable queries, CSV/JSON export,
saved queries, table notes/groups/visibility, and shell-script credential
loading (1Password CLI, AWS, …).

## Build & run (development)

```sh
swift build
swift run Dbosk        # or .build/debug/Dbosk
```

## Tests

Unit tests run standalone; driver integration tests need the docker databases:

```sh
swift test                                   # unit + SQLite (no server needed)
docker compose up -d postgres                # port 54329
docker compose --profile phase4 up -d        # + mysql (33069), mongo (27019)
DBOSK_PG_TESTS=1 DBOSK_MYSQL_TESTS=1 DBOSK_MONGO_TESTS=1 swift test
```

## App bundle & distribution

```sh
Scripts/make-app.sh            # dist/Dbosk.app (ad-hoc signed, local use)
Scripts/make-app.sh --dmg      # + dist/Dbosk.dmg
```

For notarized distribution, sign with a Developer ID and submit the DMG:

```sh
export DBOSK_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
Scripts/make-app.sh --dmg
xcrun notarytool submit dist/Dbosk.dmg --keychain-profile <profile> --wait
xcrun stapler staple dist/Dbosk.dmg
```

The app is intentionally **not sandboxed**: the script-based credential loader
runs arbitrary user executables (e.g. `op`, `aws`) and reads their stdout.

## Credential scripts

A connection can load its credentials at connect time from an executable that
prints JSON to stdout:

```json
{ "host": "…", "port": 5432, "user": "…", "password": "…", "database": "…", "uri": "postgres://…" }
```

All keys are optional and merged over the profile's fields; `uri` wins when
present. stderr is shown on failure; stdout is never logged or persisted.

## Layout

- `Sources/DBCore` — value model (`DBValue`), `DatabaseDriver` protocol, streaming `QueryExecution`
- `Sources/DBDriver{Postgres,MySQL,Mongo,SQLite}` — driver adapters
- `Sources/Connections` — profiles, Keychain, credential scripts, per-connection metadata
- `Sources/Export` — streaming CSV/JSON exporters
- `Sources/Dbosk` — the app (SwiftUI shell, AppKit results grid + editor)
