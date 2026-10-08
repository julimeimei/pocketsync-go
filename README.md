# PocketSync

PocketSync is an offline-first Flutter app backed by a small Go REST API.
It demonstrates local-first persistence, a retryable synchronization queue,
conflict handling, and clean state management for mobile applications that must
keep working under unreliable network conditions.

The product domain is intentionally small: a task app with create, edit,
delete, completion, and synchronization status. The engineering focus is the
offline-first workflow rather than a large feature set.

## Why Offline-First

Many mobile apps become frustrating when the network is slow, unstable, or
temporarily unavailable. PocketSync treats the local SQLite database as the
source of truth so the user can keep working immediately.

The remote API is a synchronization target, not the place the UI waits for
before showing changes.

```text
User action
  -> local SQLite transaction
  -> sync operation queued
  -> UI updates immediately
  -> sync engine sends operation to Go API
  -> API stores remote version in PostgreSQL
  -> local task becomes synced, failed, or conflict
```

## What It Demonstrates

- Offline-first Flutter architecture.
- Drift/SQLite as the local source of truth.
- Durable local sync queue for create, update, and delete operations.
- Manual and connectivity-triggered synchronization.
- Retryable failures with visible task status.
- Version-based conflict detection and resolution.
- Small Go REST API with PostgreSQL persistence.
- API input validation, request body limits, safe errors, and narrow CORS.
- Focused tests for repositories, sync behavior, API handlers, and UI states.

## Architecture

PocketSync keeps the UI, local database, sync engine, remote client, and API
separate enough to explain and test each part independently.

```text
Flutter UI
  -> Riverpod providers
  -> TaskLocalRepository
  -> Drift SQLite
      - local_tasks
      - sync_operations
      - task_conflicts

SyncCoordinator
  -> SyncEngine
  -> TaskRemoteApiClient
  -> Go REST API
  -> PostgreSQL tasks table
```

## Running Locally

Prerequisites:

- Go 1.23 or newer.
- Flutter with web or Android tooling configured.
- Docker Desktop for the local PostgreSQL database.

Start PostgreSQL from the repository root:

```powershell
docker compose up -d postgres
```

Start the Go API:

```powershell
cd services/api
$env:API_DATABASE_URL="postgres://pocketsync:pocketsync@localhost:5432/pocketsync?sslmode=disable"
go run ./cmd/api
```

The API applies database migrations on startup and listens on
`http://localhost:8080` by default. `API_DATABASE_URL` is required so real
database credentials stay in environment configuration instead of source code.

Run the Flutter web demo on a fixed local port:

```powershell
cd apps/mobile
flutter run -d chrome --web-port 8081 --dart-define=POCKETSYNC_API_BASE_URL=http://localhost:8080
```

Run the Flutter app on an Android emulator:

```powershell
cd apps/mobile
flutter run -d emulator --dart-define=POCKETSYNC_API_BASE_URL=http://10.0.2.2:8080
```

`10.0.2.2` is the Android emulator alias for the host machine. For a physical
device, use an HTTPS API endpoint for release-like testing. Cleartext local
traffic is allowed only in Android debug/profile builds for the emulator demo.

For Flutter web, the API uses a CORS allowlist through `API_ALLOWED_ORIGINS`.
The default allows `http://localhost:8081` and `http://127.0.0.1:8081`, matching
the web command above. Add more local origins explicitly instead of using a
wildcard.

## Running Tests

API:

```powershell
cd services/api
go test ./...
```

Flutter:

```powershell
cd apps/mobile
flutter analyze
flutter test --reporter expanded
flutter build web
```

PostgreSQL integration tests are opt-in because they need a running database:

```powershell
cd services/api
$env:POCKETSYNC_TEST_DATABASE_URL="postgres://pocketsync:pocketsync@localhost:5432/pocketsync?sslmode=disable"
go test ./internal/store -run TestTaskStoreIntegration -count=1
```
