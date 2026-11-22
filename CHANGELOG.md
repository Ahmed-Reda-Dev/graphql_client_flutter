# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.3.0]

### Added
- **Record and replay** (in `package:graphql_client_flutter/testing.dart`):
  - `RecordingTransport` wraps a real transport and records every answer into a `Cassette`: responses, GraphQL errors, transport failures and subscription events. Request headers are never recorded.
  - `ReplayTransport` plays a cassette back without a server. It matches by operation name and variables, replays repeated requests in order, and explains any request that wasn't recorded.
  - `Cassette.save` and `Cassette.load` write indented JSON fixtures. On the web, use `toJson` and `fromJson`.
- **`RelayPagination`** for `fetchMore` on Relay-style connections: `merge` appends edges and nodes, while `hasNextPage` and `nextPageVariables` read `pageInfo`.

## [2.2.0]

### Added
- **Offline mutation queue:** `mutate(queueIfOffline: true)` (also on `GraphQLMutation`) keeps a mutation while the server is unreachable and sends it once the network is back.
  - The optimistic response stays applied until then, and the returned future completes with the server's answer.
  - Queued mutations are saved with the cache (encrypted by a store codec), survive restarts, and are sent in order.
  - Retries happen after any successful request, on a backoff timer (`offlineRetryDelay`), when the app returns to the foreground, and on `setOnline(true)`.
  - `client.offlineQueue` exposes `length`, `changes`, `flush()` and `clear()`. `resetStore()` discards the queue.
- **App lifecycle awareness:** `client.setAppVisible(bool)` pauses polling in the background, and refreshes watched queries when the app returns, following each query's fetch policy and `maxAge`. `GraphQLProvider` calls it on its own (opt out with `handleAppLifecycle: false`).
- **Connectivity awareness:** `client.setOnline(bool)` pauses polling and the offline queue while offline, and refreshes watched queries and sends queued mutations when the device is back online.
- **Cache size limit:** `GraphQLCache(maxEntities:)` evicts the least recently used objects past the limit. Root types and bookkeeping entries are never evicted.

### Changed
- `GraphQLProvider` is now a `StatefulWidget` (it listens to the app lifecycle). `GraphQLProvider.of`, `maybeOf` and `context.graphQLClient` work as before.

## [2.1.0]

### Added
- **Cache freshness with `maxAge`**, available per query, on `watchQuery` and `GraphQLQuery`, and client-wide as `defaultMaxAge`:
  - `cacheFirst` refetches stale data, and returns it anyway when the server is unreachable (stale-if-error).
  - `cacheAndNetwork` skips the network while data is fresh.
  - Write times are kept in the store, so they survive restarts.
- **Web persistence:** `PersistentStore` saves to `localStorage` in browsers, with the same API, codec support and batched writes as the file-backed store.
- **Automatic query batching:** `GraphQLClient(batch: BatchOptions())` sends queries started close together as one request.
  - Requests are split by headers and capped by `maxBatchSize`.
  - If the server doesn't support batching, the client falls back to single requests on its own.
- **DevTools integration:**
  - A `graphql_client_flutter` tab in Dart DevTools shows live operations (variables, response, errors, timing) and a cache browser.
  - Operations also appear on the Performance timeline.
  - The integration is compiled out of release builds.
- `BufferedStore`, the base class for custom persistent stores.

### Fixed
- The minimum Dio version is now 5.10, which adds `DioExceptionType.transformTimeout`. Projects resolving an older Dio failed to compile.
- An `UNAUTHENTICATED` error inside a batched response now triggers the token refresh.
- CI passes on Flutter 3.50: the tests no longer import the deprecated `package:flutter/material.dart`.

### Documentation
- The README is redesigned, with diagrams for the architecture, the normalized cache, fetch policies and token refresh, plus screenshots of the example app and the DevTools extension. The screenshots also appear on the pub.dev page.
- The example is a runnable Flutter app, uses the official `material_ui` package, and shows whether data is live or cached.
- The pubspec description is shortened to fit pub.dev's limit.

## [2.0.0]

A redesign for simplicity and correctness. See [MIGRATION.md](MIGRATION.md).

### Added
- `GraphQLClient(url)`: one-line setup with retries, timeouts, auth and a normalized cache.
- Sealed `GraphQLResult<T>` (`GraphQLSuccess` / `GraphQLFailure`) returned by every operation. Requests no longer throw.
- `GraphQLException.kind` (`network`, `timeout`, `unauthenticated`, ...) and `userMessage` for UI text.
- Typed data through `parse:`, with no codegen required.
- A normalized cache (`GraphQLCache`, built on `package:normalize`): mutations update every query that shows the same object. Includes `TypePolicy` key fields, fragments, `evict`, `gc` and `resetStore`.
- Optimistic mutations with automatic rollback, `update:` cache callbacks and `refetchQueries:`.
- `watchQuery` with `refetch`, `fetchMore` (pagination), `setVariables` and polling.
- Widgets: `GraphQLProvider`, `GraphQLQuery`, `GraphQLMutation` and `GraphQLSubscription`, with sealed `QueryState` / `MutationState`.
- `PersistentStore`: an offline cache saved to disk with atomic, batched writes.
- Auth token refresh on HTTP 401 and on `UNAUTHENTICATED` errors in HTTP 200 responses; concurrent requests share a single refresh.
- WebSocket subscriptions that reconnect with backoff and restart active subscriptions, skip retries after fatal close codes, read `connectionParams` on every connection, and close the socket when idle.
- Automatic Persisted Queries, GET for queries, file uploads (GraphQL multipart spec) and `CancellationToken`.
- `GraphQLObserver` for analytics and tracing, and request deduplication for identical in-flight queries.
- `package:graphql_client_flutter/testing.dart` with `MockTransport`.
- Security defaults:
  - Credentials are never sent over unencrypted connections to public hosts; `allowInsecureAuth` overrides this for development.
  - HTTP redirects are not followed.
  - Logs and exception messages never include tokens, URL query strings or request bodies unless explicitly enabled.
  - The WebSocket `connection_init` payload carries only the token.
  - `PersistentStore` supports an encryption `codec`, and `resetStore()` clears the cache on disk before it returns.
- `GraphQLTransport` abstraction, with `HttpTransport`, `WebSocketTransport` and `SplitTransport`.

### Fixed (from 1.x)
- Queries are sent unchanged. 1.x injected an `errors { ... }` selection that spec-compliant servers reject.
- Subscriptions no longer crash, time out after 30 seconds, or keep running after the stream is cancelled.
- 401/403/429 responses now reach the auth and retry logic, and retries go to the right URL through the same Dio instance.
- Documents are parsed with a real GraphQL parser, so shorthand queries such as `{ user { name } }` work.
- Logs redact credentials and are written with `dart:developer` instead of `print`.

### Removed
- `GraphQLClientBase`, `GraphQLConfig`, `CacheManager`, `CachePolicy`, `ErrorHandlingStrategy`, `GraphQLErrorHandler`, `QueryTransformer`, `ResponseParser`, `BatchResponse` and the repository classes.
- `batch()`, `getSchema()` and `validateQuery()`.
- `dartdoc` as a runtime dependency, and generated API docs committed to the repository.

## [1.0.1+2]

### Fixed
- **Bug Fix:** Fix formatting issues and ensure consistent newline usage across multiple files.

## [1.0.1+1]

### Fixed
- **Bug Fix:** Resolved an issue where the client would throw a `Null` error when attempting to access the SDK directory during documentation generation. This fix ensures smoother `dartdoc` executions without runtime type errors.
- **Dependency Update:** Updated `path_provider` to version `^2.1.5` to ensure compatibility with the latest Flutter SDKs.

### Improved
- **Performance:** Enhanced caching mechanisms to improve query execution speed and reduce unnecessary network calls.
- **Logging:** Improved logging details for better debugging and monitoring of GraphQL operations.

### Miscellaneous
- **Documentation:** Updated the usage examples in `README.md` to provide clearer guidance on configuring and utilizing the GraphQL client.
- **Code Quality:** Applied linting fixes and code formatting to adhere to Dart's best practices, ensuring maintainable and readable codebase.


## [1.0.1]

### Added
- **Initial Release**:
  - Core functionality to execute GraphQL queries and mutations.
  - Basic caching with `CachePolicy` support.
  - Error handling with `GraphQLException`.
  - Unit tests covering primary features.
  - Example usage in the `example/` directory.

---

## Contributing

Contributions are welcome! Please follow these steps:

1. **Fork the Repository**: Click the "Fork" button at the top-right corner of the repository page.
2. **Create a New Branch**: `git checkout -b feature/YourFeatureName`
3. **Commit Your Changes**: `git commit -m "Add some feature"`
4. **Push to the Branch**: `git push origin feature/YourFeatureName`
5. **Open a Pull Request**: Navigate to the repository on GitHub and click "Compare & pull request".

Please ensure your code adheres to the project's linting rules and includes appropriate tests.

## License

This project is licensed under the [MIT License](LICENSE).

## Additional Information

- **GitHub Repository**: [https://github.com/Ahmed-Reda-Dev/graphql_client_flutter](https://github.com/Ahmed-Reda-Dev/graphql_client_flutter)
- **Issue Tracker**: [https://github.com/Ahmed-Reda-Dev/graphql_client_flutter/issues](https://github.com/Ahmed-Reda-Dev/graphql_client_flutter/issues)
- **Documentation**: [https://pub.dev/documentation/graphql_client/latest/graphql_client/graphql_client-library.html](https://pub.dev/documentation/graphql_client/latest/graphql_client/graphql_client-library.html)
- **Examples**: Check out the [example](example/) directory for comprehensive usage examples.

---

*Maintained by Ahmed Reda. For support or questions, please open an issue on [GitHub](https://github.com/Ahmed-Reda-Dev/graphql_client_flutter/issues).*