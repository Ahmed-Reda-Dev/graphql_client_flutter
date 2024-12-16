import 'package:dio/dio.dart';
import '../graphql_client_flutter.dart';

/// Main GraphQL client class that handles all GraphQL operations
class GraphQLClientBase {
  /// Configuration for the GraphQL client
  final GraphQLConfig config;

  /// Repository for GraphQL operations
  final GraphQLRepository _repository;

  /// Cache manager for GraphQL responses
  final CacheManager _cacheManager;

  /// Repository for GraphQL subscriptions
  GraphQLSubscriptionRepository? _subscriptionRepository;

  /// Error handler for GraphQL operations
  final GraphQLErrorHandler _errorHandler;

  /// Creates a new GraphQLClient instance
  GraphQLClientBase({
    required this.config,
    CacheManager? cacheManager,
    List<Interceptor>? interceptors,
  })  : _cacheManager = cacheManager ?? CacheManager(),
        _errorHandler = GraphQLErrorHandler(
          strategy: config.errorHandling,
          onError: config.onError,
        ),
        _repository = GraphQLRepositoryImpl(
          Dio(BaseOptions(
            baseUrl: config.endpoint,
            headers: config.defaultHeaders,
            connectTimeout: config.defaultTimeout,
            validateStatus: (status) => status! < 500,
          ))
            ..interceptors.addAll([
              RetryInterceptor(
                maxRetries: config.maxRetries,
                retryDelay: config.retryDelay,
                onRetry: (attempt, error) {
                  print('Retrying request (attempt $attempt)');
                },
              ),
              if (config.enableLogging)
                LoggingInterceptor(
                  options: LoggingOptions(
                    logRequests: true,
                    logResponses: true,
                    logErrors: true,
                  ),
                  prettyPrintJson: true,
                ),
              ...?interceptors,
            ]),
          cacheManager ?? CacheManager(),
          errorHandling: config.errorHandling,
          onError: config.onError,
        ) {
    if (config.subscriptionEndpoint != null) {
      _subscriptionRepository = GraphQLSubscriptionRepository(
        config.subscriptionEndpoint!,
        connectionTimeout: config.defaultTimeout,
        keepAliveInterval: const Duration(seconds: 60),
        connectionParams: {
          ...?config.defaultHeaders,
          ...?config.subscriptionConnectionParams,
        },
      );
    }
  }

  /// Executes a GraphQL query operation
  Future<GraphQLResponse<T>> query<T>(
    String query, {
    Map<String, dynamic>? variables,
    CachePolicy? cachePolicy,
    Duration? ttl,
    String? operationName,
  }) async {
    try {
      return await _retryOperation<GraphQLResponse<T>>(
        () => _repository.query<T>(
          query,
          variables: variables,
          cachePolicy: cachePolicy ?? config.defaultCachePolicy,
          ttl: ttl,
          operationName: operationName,
        ),
        'query',
        operationName,
      );
    } catch (e) {
      return _handleError<GraphQLResponse<T>>(
        e,
        operationType: 'query',
        operationName: operationName,
      );
    }
  }

  /// Executes a GraphQL mutation operation
  Future<GraphQLResponse<T>> mutate<T>(
    String mutation, {
    Map<String, dynamic>? variables,
    List<String>? invalidateCache,
    String? operationName,
  }) async {
    try {
      return await _repository.mutate<T>(
        mutation,
        variables: variables,
        invalidateCache: invalidateCache,
        operationName: operationName,
      );
    } catch (e) {
      return _handleError<GraphQLResponse<T>>(
        e,
        operationType: 'mutate',
        operationName: operationName,
      );
    }
  }

  /// Executes multiple GraphQL operations in batch
  Future<BatchResponse> batch(List<BatchOperation> operations) async {
    try {
      return await _repository.batch(operations);
    } catch (e) {
      return _handleError<BatchResponse>(
        e,
        operationType: 'batch',
      );
    }
  }

  /// Subscribes to a GraphQL subscription
  Stream<GraphQLResponse<T>> subscribe<T>(
    String subscription, {
    Map<String, dynamic>? variables,
    Duration? timeout,
    String? operationName,
  }) {
    try {
      if (_subscriptionRepository == null) {
        throw _handleError(
          GraphQLException(
            message: 'Subscription endpoint not configured',
            extensions: {'type': 'subscription_error'},
          ),
          operationType: 'subscription',
          operationName: operationName,
        );
      }
      return _subscriptionRepository!.subscribe<T>(
        subscription,
        variables: variables,
        timeout: timeout ?? config.defaultTimeout,
      );
    } catch (e) {
      return Stream.error(_handleError(
        e,
        operationType: 'subscription',
        operationName: operationName,
      ));
    }
  }

  /// Validates a GraphQL query
  Future<bool> validateQuery(
    String query, {
    Map<String, dynamic>? variables,
    String? operationName,
  }) async {
    try {
      return await _repository.validateQuery(
        query,
        variables: variables,
      );
    } catch (e) {
      return _handleError<bool>(
        e,
        operationType: 'validate',
        operationName: operationName,
      );
    }
  }

  /// Gets the GraphQL schema
  Future<GraphQLResponse<Map<String, dynamic>>> getSchema() async {
    try {
      return await _repository.getSchema();
    } catch (e) {
      return _handleError<GraphQLResponse<Map<String, dynamic>>>(
        e,
        operationType: 'introspection',
        operationName: 'IntrospectionQuery',
      );
    }
  }

  /// Clears the cache
  Future<void> clearCache() async {
    try {
      await _cacheManager.clear();
    } catch (e) {
      throw _handleError(
        e,
        operationType: 'cache',
        operationName: 'clear',
      );
    }
  }

  /// Gets cache statistics
  Future<Map<String, dynamic>> getCacheStats() async {
    try {
      return await _repository.getCacheStats();
    } catch (e) {
      return _handleError<Map<String, dynamic>>(
        e,
        operationType: 'cache',
        operationName: 'stats',
      );
    }
  }

  /// Invalidates specific queries in the cache
  Future<void> invalidateQueries(List<String> queryKeys) async {
    try {
      await _repository.invalidateQueries(queryKeys);
    } catch (e) {
      throw _handleError(
        e,
        operationType: 'cache',
        operationName: 'invalidate',
      );
    }
  }

  /// Refreshes cached queries
  Future<void> refreshQueries(List<String> queryKeys) async {
    try {
      await _repository.refreshQueries(queryKeys);
    } catch (e) {
      throw _handleError(
        e,
        operationType: 'cache',
        operationName: 'refresh',
      );
    }
  }

  /// Checks if subscriptions are supported
  bool get hasSubscriptionSupport => _subscriptionRepository != null;

  /// Gets the number of active subscriptions
  int get activeSubscriptions =>
      _subscriptionRepository?.activeSubscriptions ?? 0;

  /// Disposes of client resources
  Future<void> dispose() async {
    try {
      await _repository.dispose();
      await _subscriptionRepository?.dispose();
    } catch (e) {
      throw _handleError(
        e,
        operationType: 'dispose',
      );
    }
  }

  /// Handles errors uniformly across the client
  T _handleError<T>(
    dynamic error, {
    String? operationType,
    String? operationName,
  }) {
    return _errorHandler.handleError<T>(
      error,
      operationType: operationType,
      operationName: operationName,
    );
  }

    Future<T> _retryOperation<T>(
    Future<T> Function() operation,
    String operationType,
    String? operationName,
  ) async {
    int attempts = 0;
    while (attempts < config.maxRetries) {
      try {
        return await operation();
      } catch (e) {
        attempts++;
        if (attempts >= config.maxRetries || !_errorHandler.shouldRetry(e is GraphQLException ? e : GraphQLException(message: e.toString()))) {
          return _handleError(
            e,
            operationType: operationType,
            operationName: operationName,
          );
        }
        await Future.delayed(config.retryDelay);
      }
    }
    throw _handleError(
      GraphQLException(message: 'Max retry attempts reached'),
      operationType: operationType,
      operationName: operationName,
    );
  }
}

/// Extension methods for GraphQL operations
extension GraphQLClientExtensions on GraphQLClientBase {
  /// Executes a query with cache-first policy
  Future<GraphQLResponse<T>> queryCacheFirst<T>(
    String query, {
    Map<String, dynamic>? variables,
    Duration? ttl,
    String? operationName,
  }) {
    return this.query<T>(
      query,
      variables: variables,
      cachePolicy: CachePolicy.cacheFirst,
      ttl: ttl,
      operationName: operationName,
    );
  }

  /// Executes a query with network-only policy
  Future<GraphQLResponse<T>> queryNetworkOnly<T>(
    String query, {
    Map<String, dynamic>? variables,
    String? operationName,
  }) {
    return this.query<T>(
      query,
      variables: variables,
      cachePolicy: CachePolicy.networkOnly,
      operationName: operationName,
    );
  }

  /// Executes a mutation and invalidates cache entries
  Future<GraphQLResponse<T>> mutateAndInvalidate<T>(
    String mutation, {
    Map<String, dynamic>? variables,
    List<String> invalidateQueries = const [],
    String? operationName,
  }) {
    return mutate<T>(
      mutation,
      variables: variables,
      invalidateCache: invalidateQueries,
      operationName: operationName,
    );
  }
}
