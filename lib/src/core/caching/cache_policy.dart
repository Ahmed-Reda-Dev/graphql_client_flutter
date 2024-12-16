/// Defines the caching behavior for GraphQL operations
enum CachePolicy {
  /// Always fetch from network and don't cache the response
  /// Use this when you need real-time data and don't want any caching
  networkOnly,

  /// Try to get data from cache first, if not found or expired, fetch from network
  /// This is useful for optimizing performance and reducing network calls
  cacheFirst,

  /// Only fetch from cache, throw error if data is not found or expired
  /// Use this when you want to work offline or ensure using only cached data
  cacheOnly,

  /// Try network first, use cache as fallback if network fails
  /// Useful for ensuring fresh data while having a fallback
  networkFirst,

  /// Return cache data immediately, then update from network in background
  /// Best for immediate UI updates while ensuring eventual consistency
  cacheAndNetwork,

  /// Merge network response with cached data
  /// Useful for partial updates while maintaining complete cached objects
  mergeNetworkAndCache,

  /// Cache data only if network request fails
  /// Helps in implementing offline-first functionality
  cacheOnError,

  /// Prefer cache but refresh if expired
  /// Balance between fresh data and performance
  preferCache,

  /// Custom validation for cache entries
  /// Allows implementing domain-specific caching rules
  customValidation,

  /// No caching at all, always bypass cache
  /// Use for sensitive or temporary data
  noCache,

  /// Cache with background refresh
  /// Periodically update cache in background while serving cached data
  backgroundRefresh
}

/// Extension methods for CachePolicy
extension CachePolicyExtension on CachePolicy {
  /// Whether this policy allows reading from cache
  bool get canReadFromCache {
    return this != CachePolicy.networkOnly && this != CachePolicy.noCache;
  }

  /// Whether this policy allows writing to cache
  bool get canWriteToCache {
    return this != CachePolicy.cacheOnly && this != CachePolicy.noCache;
  }

  /// Whether this policy requires network access
  bool get requiresNetwork {
    return this != CachePolicy.cacheOnly;
  }

  /// Whether this policy supports background refresh
  bool get supportsBackgroundRefresh {
    return this == CachePolicy.backgroundRefresh ||
        this == CachePolicy.cacheAndNetwork;
  }

  /// Default TTL (Time To Live) for this cache policy
  Duration get defaultTtl {
    switch (this) {
      case CachePolicy.preferCache:
        return const Duration(minutes: 30);
      case CachePolicy.backgroundRefresh:
        return const Duration(hours: 1);
      case CachePolicy.cacheFirst:
        return const Duration(minutes: 5);
      default:
        return const Duration(minutes: 15);
    }
  }

  /// Priority level for cache invalidation
  /// Higher number means higher priority for keeping in cache
  int get retentionPriority {
    switch (this) {
      case CachePolicy.preferCache:
        return 3;
      case CachePolicy.cacheFirst:
        return 2;
      case CachePolicy.cacheAndNetwork:
        return 1;
      default:
        return 0;
    }
  }
}
