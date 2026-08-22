# Lillygram

A fully native SwiftUI Instagram client focused on deliberate social use:
favorites-only Home, Stories, posts, account search, profiles, and read-only DMs,
with no Reel feed or Explore surface.

Current version: **0.5.1**. Private beta; distributed through TestFlight to a
small tester group.

## Product rules

| Requirement | Behavior |
| --- | --- |
| Favorites-only Home | Native Home renders only posts from accounts selected for the current Lillygram account. Empty or failed filtering never falls back to algorithmic content. |
| No Reels | There is no Reel tab, feed, search, profile grid, or creation path. One Reel shared in a DM can play in an isolated one-item player. |
| Account-only search | The REST and Swift models expose account results only. |
| Native experience | Every surface is SwiftUI/AVKit. There is no WebView or injected JavaScript. |

See [`docs/product-requirements.md`](docs/product-requirements.md) for the full
contract.

## Architecture

The iOS app talks over REST/JSON to a small FastAPI service. Only the backend
imports `instagrapi` or communicates with Instagram's unofficial private API.

- iOS stores only a Lillygram backend bearer token in Keychain.
- Backend Instagram sessions, device settings, and optional proxy URLs are
  Fernet-encrypted at rest.
- Each account has one stable device identity, one encrypted session, one lock,
  and durable request budgets.
- Every operation creates a fresh `instagrapi.Client` from that account's saved
  settings. No live client state is shared across users.
- Challenge or rejected-session states freeze only the affected account and are
  never retried silently.
- New accounts are read-only for three days by default. Reads, writes, and login
  attempts have conservative rolling hourly limits and randomized pacing.
- DMs are read-only. Replies open Instagram instead of using unofficial DM
  writes.

These controls reduce unnecessary automation but cannot guarantee that Meta will
not challenge or restrict an account. Read [`docs/known-issues.md`](docs/known-issues.md)
before using a real account.

## Backend setup

Requirements: Python 3.12+, `uv`, a persistent database volume, and a stable
Fernet key.

```sh
cd backend
uv sync --extra test
export LILLYGRAM_ENCRYPTION_KEY="$(uv run python -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())')"
export LILLYGRAM_DATABASE_PATH="$PWD/data/lillygram.sqlite3"
uv run uvicorn lillygram_backend.main:build_default_app --factory --host 127.0.0.1 --port 8000
```

Generate the encryption key once and store it in the deployment secret manager.
Do not regenerate it on restart. `backend/.env.example` lists all optional
limits. `backend/Dockerfile` provides the production container entry point.

For Simulator development, enter `http://127.0.0.1:8000` in Lillygram. A physical
device requires a reachable HTTPS deployment. No production backend host is
bundled or hardcoded.

## iOS build

The pbxproj is hand-managed and authoritative. Do not run xcodegen.

```sh
xcodebuild -project ios/Lillygram.xcodeproj -scheme Lillygram \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

## Test

```sh
uv run --directory backend --extra test pytest -q
```

The backend suite verifies encrypted storage, stable device reuse, per-account
challenge isolation, request caps, warm-up, absence of DM writes, pagination
mapping, and Reel filtering. CI also builds the unsigned iOS simulator target.
Live Instagram behavior must be verified with a designated test account before
family accounts.

## Project layout

```text
backend/                     FastAPI + instagrapi gateway and tests
ios/Lillygram/               Native SwiftUI application
ios/Lillygram.xcodeproj/     Hand-maintained Xcode project
docs/                        Product and architecture source of truth
tools/                       Release and TestFlight utilities
```

Migration details: [`docs/native-migration.md`](docs/native-migration.md).

## Release

Semantic versions are shared by Xcode, the changelog, this README, and GitHub
Release tags. Publishing `v<version>` from `main` runs backend tests, archives
the native app, uploads it, and waits until App Store Connect reports the build
available to Internal Testers.

## License

[MIT](LICENSE)
