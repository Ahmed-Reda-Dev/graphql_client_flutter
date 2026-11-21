# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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