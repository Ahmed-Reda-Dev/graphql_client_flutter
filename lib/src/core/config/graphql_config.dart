import '../../../graphql_client_flutter.dart';

/// Configuration class for GraphQL client settings
class GraphQLConfig {
  /// The GraphQL API endpoint URL
  final String endpoint;

  /// The WebSocket endpoint URL for GraphQL subscriptions
  final String? subscriptionEndpoint;

  /// Additional parameters for subscription connections
  final Map<String, dynamic>? subscriptionConnectionParams;

  /// Callback for handling GraphQL errors
  final void Function(GraphQLException)? onError;

  /// Default timeout duration for requests
  final Duration defaultTimeout;

  /// Default caching policy for queries
  final CachePolicy defaultCachePolicy;

  /// Default headers to be sent with every request
  final Map<String, String>? defaultHeaders;

  /// Whether to enable request/response logging
  final bool enableLogging;

  /// Maximum number of retry attempts for failed requests
  final int maxRetries;

  /// Delay between retry attempts
  final Duration retryDelay;

  /// Maximum size for the in-memory cache (in bytes)
  final int maxCacheSize;

  /// Whether to enable compression for cached data
  final bool enableCompression;

  /// Whether to persist cache to disk
  final bool persistCache;

  /// Duration after which cached entries are considered stale
  final Duration defaultCacheTtl;

  /// Whether to include query complexity analysis
  final bool enableQueryComplexityAnalysis;

  /// Maximum allowed query complexity score
  final int maxQueryComplexity;

  /// Whether to validate queries before execution
  final bool validateQueries;

  /// Whether to include operation name in requests
  final bool includeOperationName;

  /// Error handling strategy
  final ErrorHandlingStrategy errorHandling;

  /// Whether to automatically handle authentication refresh
  final bool autoRefreshAuth;

  const GraphQLConfig({
    required this.endpoint,
    this.subscriptionEndpoint,
    this.defaultTimeout = const Duration(seconds: 30),
    this.defaultCachePolicy = CachePolicy.networkOnly,
    this.defaultHeaders,
    this.enableLogging = false,
    this.maxRetries = 3,
    this.retryDelay = const Duration(seconds: 1),
    this.maxCacheSize = 10 * 1024 * 1024,
    this.enableCompression = true,
    this.persistCache = true,
    this.defaultCacheTtl = const Duration(minutes: 30),
    this.enableQueryComplexityAnalysis = false,
    this.maxQueryComplexity = 1000,
    this.validateQueries = true,
    this.includeOperationName = true,
    this.errorHandling = ErrorHandlingStrategy.throwError,
    this.autoRefreshAuth = true,
    this.subscriptionConnectionParams,
    this.onError,
  });

  /// Creates a copy of this config with the given fields replaced with new values
  GraphQLConfig copyWith({
    String? endpoint,
    String? subscriptionEndpoint,
    Duration? defaultTimeout,
    CachePolicy? defaultCachePolicy,
    Map<String, String>? defaultHeaders,
    bool? enableLogging,
    int? maxRetries,
    Duration? retryDelay,
    int? maxCacheSize,
    bool? enableCompression,
    bool? persistCache,
    Duration? defaultCacheTtl,
    bool? enableQueryComplexityAnalysis,
    int? maxQueryComplexity,
    bool? validateQueries,
    bool? includeOperationName,
    ErrorHandlingStrategy? errorHandling,
    bool? autoRefreshAuth,
    Map<String, dynamic>? subscriptionConnectionParams,
    void Function(GraphQLException)? onError,
  }) {
    return GraphQLConfig(
      endpoint: endpoint ?? this.endpoint,
      subscriptionEndpoint: subscriptionEndpoint ?? this.subscriptionEndpoint,
      defaultTimeout: defaultTimeout ?? this.defaultTimeout,
      defaultCachePolicy: defaultCachePolicy ?? this.defaultCachePolicy,
      defaultHeaders: defaultHeaders ?? this.defaultHeaders,
      enableLogging: enableLogging ?? this.enableLogging,
      maxRetries: maxRetries ?? this.maxRetries,
      retryDelay: retryDelay ?? this.retryDelay,
      maxCacheSize: maxCacheSize ?? this.maxCacheSize,
      enableCompression: enableCompression ?? this.enableCompression,
      persistCache: persistCache ?? this.persistCache,
      defaultCacheTtl: defaultCacheTtl ?? this.defaultCacheTtl,
      enableQueryComplexityAnalysis:
          enableQueryComplexityAnalysis ?? this.enableQueryComplexityAnalysis,
      maxQueryComplexity: maxQueryComplexity ?? this.maxQueryComplexity,
      validateQueries: validateQueries ?? this.validateQueries,
      includeOperationName: includeOperationName ?? this.includeOperationName,
      errorHandling: errorHandling ?? this.errorHandling,
      autoRefreshAuth: autoRefreshAuth ?? this.autoRefreshAuth,
      subscriptionConnectionParams:
          subscriptionConnectionParams ?? this.subscriptionConnectionParams,
      onError: onError ?? this.onError,
    );
  }

  /// Creates a configuration optimized for production use
  factory GraphQLConfig.production({
    required String endpoint,
    String? subscriptionEndpoint,
    Map<String, dynamic>? subscriptionConnectionParams,
    void Function(GraphQLException)? onError,
  }) {
    return GraphQLConfig(
      endpoint: endpoint,
      subscriptionEndpoint: subscriptionEndpoint,
      defaultCachePolicy: CachePolicy.cacheFirst,
      enableLogging: false,
      maxRetries: 3,
      enableCompression: true,
      persistCache: true,
      validateQueries: true,
      errorHandling: ErrorHandlingStrategy.throwError,
      subscriptionConnectionParams: subscriptionConnectionParams,
      onError: onError,
    );
  }

  /// Creates a configuration optimized for development use
  factory GraphQLConfig.development({
    required String endpoint,
    String? subscriptionEndpoint,
    Map<String, dynamic>? subscriptionConnectionParams,
    void Function(GraphQLException)? onError,
  }) {
    return GraphQLConfig(
      endpoint: endpoint,
      subscriptionEndpoint: subscriptionEndpoint,
      defaultCachePolicy: CachePolicy.networkOnly,
      enableLogging: true,
      maxRetries: 1,
      enableCompression: false,
      persistCache: false,
      validateQueries: true,
      errorHandling: ErrorHandlingStrategy.showDialog,
      subscriptionConnectionParams: subscriptionConnectionParams,
      onError: onError,
    );
  }

  /// Validates the configuration
  bool validate() {
    if (endpoint.isEmpty) return false;
    if (maxRetries < 0) return false;
    if (maxCacheSize < 0) return false;
    if (maxQueryComplexity < 0) return false;
    return true;
  }

  @override
  String toString() {
    return 'GraphQLConfig('
        'endpoint: $endpoint, '
        'subscriptionEndpoint: $subscriptionEndpoint, '
        'defaultTimeout: $defaultTimeout, '
        'defaultCachePolicy: $defaultCachePolicy, '
        'enableLogging: $enableLogging, '
        'maxRetries: $maxRetries)';
  }
}

/// Defines how errors should be handled in the GraphQL client
enum ErrorHandlingStrategy {
  /// Throw errors as exceptions
  throwError,

  /// Show errors in a dialog
  showDialog,

  /// Silent error handling with callback
  silent,

  /// Custom error handling
  custom
}
