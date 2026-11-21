/// How a query uses the cache.
enum FetchPolicy {
  /// Return cached data when complete; otherwise fetch and cache it.
  cacheFirst,

  /// Return cached data immediately (if any) and refresh it from the
  /// network. With `watchQuery` the fresh data is emitted when it arrives.
  cacheAndNetwork,

  /// Always fetch, then update the cache.
  networkOnly,

  /// Only read the cache; fail with `GraphQLErrorKind.cacheMiss` when the
  /// data is not there.
  cacheOnly,

  /// Always fetch and never touch the cache.
  noCache,
}

/// How GraphQL errors in a response that also contains data are treated.
enum ErrorPolicy {
  /// Any error makes the operation a failure. The default.
  none,

  /// Errors are dropped when data is present.
  ignore,

  /// Data and errors are both returned in a `GraphQLSuccess`.
  all,
}
