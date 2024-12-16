import '../entities/graphql_response.dart';
import '../entities/batch_response.dart';
import '../../core/caching/cache_policy.dart';

/// Abstract interface for GraphQL operations with enhanced functionality
abstract class GraphQLRepository {
  /// Executes a GraphQL query operation with caching support
  Future<GraphQLResponse<T>> query<T>(
    String query, {
    Map<String, dynamic>? variables,
    CachePolicy cachePolicy = CachePolicy.networkOnly,
    Duration? ttl,
    String? operationName,
  });

  /// Executes a GraphQL mutation operation with cache invalidation
  Future<GraphQLResponse<T>> mutate<T>(
    String mutation, {
    Map<String, dynamic>? variables,
    List<String>? invalidateCache,
    String? operationName,
  });

  /// Executes multiple GraphQL operations in a single request
  Future<BatchResponse> batch(List<BatchOperation> operations);

  /// Validates a GraphQL query against the schema
  Future<bool> validateQuery(
    String query, {
    Map<String, dynamic>? variables,
  });

  /// Gets the schema from the server
  Future<GraphQLResponse<Map<String, dynamic>>> getSchema();

  /// Clears the entire cache
  Future<void> clearCache();

  /// Gets cache statistics and metrics
  Future<Map<String, dynamic>> getCacheStats();

  /// Disposes of any resources
  Future<void> dispose();
  
  /// Invalidates specific queries in the cache
  Future<void> invalidateQueries(List<String> queryKeys);
  
  /// Refreshes cached queries
  Future<void> refreshQueries(List<String> queryKeys);
}

/// Represents a single operation in a batch request
class BatchOperation {
  /// The GraphQL query/mutation string
  final String query;

  /// Variables for the operation
  final Map<String, dynamic>? variables;

  /// Name of the operation for tracking
  final String? operationName;

  /// Cache policy for this specific operation
  final CachePolicy? cachePolicy;

  /// Time to live for cached response
  final Duration? ttl;

  BatchOperation({
    required this.query,
    this.variables,
    this.operationName,
    this.cachePolicy,
    this.ttl,
  });

  /// Creates a BatchOperation from a JSON map
  factory BatchOperation.fromJson(Map<String, dynamic> json) {
    return BatchOperation(
      query: json['query'] as String,
      variables: json['variables'] as Map<String, dynamic>?,
      operationName: json['operationName'] as String?,
      cachePolicy: json['cachePolicy'] != null 
          ? CachePolicy.values.byName(json['cachePolicy'] as String)
          : null,
      ttl: json['ttl'] != null 
          ? Duration(milliseconds: json['ttl'] as int)
          : null,
    );
  }

  /// Converts the operation to a JSON map
  Map<String, dynamic> toJson() {
    return {
      'query': query,
      if (variables != null) 'variables': variables,
      if (operationName != null) 'operationName': operationName,
      if (cachePolicy != null) 'cachePolicy': cachePolicy!.name,
      if (ttl != null) 'ttl': ttl!.inMilliseconds,
    };
  }

  @override
  String toString() => 'BatchOperation('
      'query: $query, '
      'variables: $variables, '
      'operationName: $operationName, '
      'cachePolicy: $cachePolicy, '
      'ttl: $ttl)';
}

/// Extension methods for GraphQL operations
extension GraphQLOperationExtensions on GraphQLRepository {
  /// Executes a GraphQL query with cache-first policy
  Future<GraphQLResponse<T>> queryCacheFirst<T>(
    String query, {
    Map<String, dynamic>? variables,
    Duration? ttl,
    String? operationName,
  }) async {
    return this.query<T>(
      query,
      variables: variables,
      cachePolicy: CachePolicy.cacheFirst,
      ttl: ttl,
      operationName: operationName,
    );
  }

  /// Executes a GraphQL query with network-only policy
  Future<GraphQLResponse<T>> queryNetworkOnly<T>(
    String query, {
    Map<String, dynamic>? variables,
    String? operationName,
  }) async {
    return this.query<T>(
      query,
      variables: variables,
      cachePolicy: CachePolicy.networkOnly,
      operationName: operationName,
    );
  }

  /// Executes multiple queries in parallel
  Future<List<GraphQLResponse<T>>> queryBatch<T>(
    List<String> queries, {
    List<Map<String, dynamic>>? variablesList,
    List<String>? operationNames,
    CachePolicy cachePolicy = CachePolicy.networkOnly,
    Duration? ttl,
  }) async {
    final operations = List.generate(
      queries.length,
      (i) => BatchOperation(
        query: queries[i],
        variables: variablesList?[i],
        operationName: operationNames?[i],
        cachePolicy: cachePolicy,
        ttl: ttl,
      ),
    );

    final batchResponse = await batch(operations);
    return batchResponse.mapResponses<T>();
  }

  /// Executes a mutation and invalidates specific cache entries
  Future<GraphQLResponse<T>> mutateAndInvalidate<T>(
    String mutation, {
    Map<String, dynamic>? variables,
    List<String> invalidateQueries = const [],
    String? operationName,
  }) async {
    return mutate<T>(
      mutation,
      variables: variables,
      invalidateCache: invalidateQueries,
      operationName: operationName,
    );
  }
}