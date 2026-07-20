<p align="center"><img src="Resources/AppIcon_1024.png" width="128" alt="dbOSK icon"></p>

# dbOSK

A native macOS database client (SwiftUI + AppKit) for PostgreSQL, MySQL/MariaDB,
MongoDB, and SQLite. Streaming results, cancellable queries, CSV/JSON export,
saved queries, table notes/groups/visibility, and shell-script credential
loading (1Password CLI, AWS, …).

## Screenshots

| | |
|---|---|
| ![Connections list](docs/connections.png) Manage multiple connections, grouped and labeled | ![Table structure](docs/sql-structure.png) Inspect columns, types, and indexes |
| ![Query results grid](docs/sql-table.png) Browse table data with filters and paging | ![SQL query editor](docs/sql-query.png) Write and save complex SQL, browse results inline |
| ![MongoDB structure](docs/mongo-structure.png) Same structure view for MongoDB collections | ![MongoDB document viewer](docs/mongo-data.png) Browse documents as JSON or tree |

## Install with Homebrew

This repository is its own Homebrew tap. There is no prebuilt download or
GitHub Release: the cask downloads the `main` branch source archive and
compiles the app on your machine during install, then places `dbOSK.app`
in `/Applications` automatically. You need Xcode 16+ and macOS 14 (Sonoma)
or newer.

```sh
# 1. Tap this repository (registers it as a third-party tap):
brew tap kellertobias/dbosk https://github.com/kellertobias/dbosk

# 2. Trust only this one cask from the tap (Homebrew 6+ requires trusting
#    non-official taps; trusting the single cask is narrower than trusting
#    the whole tap):
brew trust --cask kellertobias/dbosk/dbosk

# 3. Install: builds from source, then installs dbOSK.app to /Applications.
#    The fully-qualified name scopes the install to exactly this tap — it
#    can never resolve to a same-named package from another tap:
brew install --cask kellertobias/dbosk/dbosk
```

Update to the latest `main`, or force a clean rebuild (the cask tracks the
branch head rather than a version, so `brew upgrade` cannot detect new
commits — reinstalling is the update path):

```sh
brew reinstall --cask kellertobias/dbosk/dbosk
```

Because the cask pins no version and checks no checksum (`version :latest`,
`sha256 :no_check`), Homebrew reuses the source archive it cached on the
first install and never re-downloads it — so a plain `reinstall` can quietly
recompile stale code. To actually pick up new commits, delete the cached
tarball first so the current `main` branch is fetched:

```sh
rm -f "$(brew --cache --cask kellertobias/dbosk/dbosk)"
brew reinstall --cask kellertobias/dbosk/dbosk
```

Then quit and reopen the app (a running instance is still the old build).

Uninstall and remove the tap:

```sh
brew uninstall --cask kellertobias/dbosk/dbosk
brew untap kellertobias/dbosk
```

### Signing and Gatekeeper

The build is compiled locally and ad-hoc signed (`codesign --sign -`), not
notarized. Gatekeeper only assesses apps whose bundle or executable carries
the quarantine attribute, and the executable here is produced by the local
compiler, so the app normally launches without any prompt — no workarounds
needed. Files staged from the downloaded source archive can carry the
attribute, though, so if a macOS update ever blocks the first launch,
approve it once via right-click → Open, or System Settings → Privacy &
Security → "Open Anyway". Distributing prebuilt binaries to other machines
is different: those downloads are quarantined, and passing Gatekeeper then
requires a paid Apple Developer ID certificate plus notarization by Apple —
`Scripts/make-app.sh` supports that via `DBOSK_SIGN_IDENTITY` (see below).

## Build & run (development)

```sh
swift build
swift run dbOSK        # or .build/debug/dbOSK
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
Scripts/make-app.sh            # dist/dbOSK.app (ad-hoc signed, local use)
Scripts/make-app.sh --dmg      # + dist/dbOSK.dmg
```

For notarized distribution, sign with a Developer ID and submit the DMG:

```sh
export DBOSK_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
Scripts/make-app.sh --dmg
xcrun notarytool submit dist/dbOSK.dmg --keychain-profile <profile> --wait
xcrun stapler staple dist/dbOSK.dmg
```

The app is intentionally **not sandboxed**: the script-based credential loader
runs arbitrary user executables (e.g. `op`, `aws`) and reads their stdout.

## SSH tunnels

A connection can be routed through an SSH bastion (toggle in the connection
editor). The tunnel uses the system `ssh` binary with local port forwarding,
so your `~/.ssh/config`, agent, and known_hosts apply. Auth is key-based only
(agent or an explicit identity file); the database host/port configured on
the profile are resolved *from the SSH host*. Tunnel tests:

```sh
docker compose --profile ssh up -d ssh postgres
DBOSK_SSH_TESTS=1 swift test
```

## Credential scripts

A connection can load its credentials at connect time from an executable that
prints JSON to stdout:

```json
{ "host": "…", "port": 5432, "user": "…", "password": "…", "database": "…", "uri": "postgres://…" }
```

All keys are optional and merged over the profile's fields; `uri` wins when
present. stderr is shown on failure; stdout is never logged or persisted.

## AWS Secrets Manager

A connection can instead reference an AWS Secrets Manager secret ("AWS Secret"
credential mode in the editor). Authentication uses your existing `~/.aws`
setup — pick a named profile (SSO profiles work; run `aws sso login --profile
<name>` first) or leave it empty for the default credential chain. The region
comes from the connection, the secret's ARN, the profile's config, or
`AWS_REGION`, in that order.

The secret's JSON follows the RDS-managed shape. At connect time the secret
supplies the password and fills in any fields the profile leaves empty —
host, port, user, and database set on the connection win over the secret's
values (useful when the secret's endpoint is only resolvable inside the VPC).
Nothing from the secret is persisted locally:

```json
{ "username": "…", "password": "…", "host": "…", "port": 5432, "dbname": "…" }
```

`user`/`database`/`hostname`/`uri` aliases are accepted; a plain-string secret
is treated as just the password. Secrets with non-standard key names can be
mapped in the editor: "Fetch Keys" lists the secret's key names (values are
never shown) and each field gets a dropdown to pick its key, with "Auto"
falling back to the aliases above. Opt-in integration test:

```sh
DBOSK_AWS_TESTS=1 DBOSK_AWS_SECRET_ID=prod/db [DBOSK_AWS_PROFILE=…] swift test
```

## Layout

- `Sources/DBCore` — value model (`DBValue`), `DatabaseDriver` protocol, streaming `QueryExecution`
- `Sources/DBDriver{Postgres,MySQL,Mongo,SQLite}` — driver adapters
- `Sources/Connections` — profiles, Keychain, credential scripts, per-connection metadata
- `Sources/Export` — streaming CSV/JSON exporters
- `Sources/Dbosk` — the app (SwiftUI shell, AppKit results grid + editor)
