import '../../../graphql_client_flutter.dart';

/// Type definition for a function that executes a GraphQL query
typedef QueryExecutor = Future<GraphQLResponse<T>> Function<T>(
  String query, {
  Map<String, dynamic>? variables,
});

/// Type definition for a function that executes a GraphQL mutation
typedef MutationExecutor = Future<GraphQLResponse<T>> Function<T>(
  String mutation, {
  Map<String, dynamic>? variables,
  List<String>? invalidateCache,
});

/// Type definition for a function that handles GraphQL errors
typedef ErrorHandler = void Function(GraphQLException error);

/// Type definition for a function that validates variables
typedef VariablesValidator = bool Function(Map<String, dynamic> variables);

/// Type definition for a function that transforms query responses
typedef ResponseTransformer<T> = T Function(Map<String, dynamic> data);

/// Type definition for a function that decides if a request should be retried
typedef RetryDecider = bool Function(GraphQLException error, int retryCount);

/// Type definition for a function that provides authentication tokens
typedef TokenProvider = Future<String?> Function();

/// Type definition for a function that handles cache updates
typedef CacheUpdater = Future<void> Function(
  String key,
  dynamic data, {
  Duration? ttl,
});

/// Type definition for subscription event handler
typedef SubscriptionHandler<T> = void Function(GraphQLResponse<T> response);

/// Type definition for WebSocket connection status handler
typedef ConnectionStatusHandler = void Function(bool isConnected);

/// Type definition for cache key generator
typedef CacheKeyGenerator = String Function(
  String query,
  Map<String, dynamic>? variables,
);

/// Type definition for query/mutation result parser
typedef ResultParser<T> = T Function(Map<String, dynamic> json);