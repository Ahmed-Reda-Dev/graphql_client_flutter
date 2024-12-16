import 'package:dio/dio.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';

import '../../../graphql_client_flutter.dart';

/// Implementation of GraphQL repository with caching and error handling
class GraphQLRepositoryImpl implements GraphQLRepository {
  final Dio _dio;
  final CacheManager _cacheManager;
  final GraphQLErrorHandler _errorHandler;
  bool _isDisposed = false;

  GraphQLRepositoryImpl(
    this._dio,
    this._cacheManager, {
    ErrorHandlingStrategy errorHandling = ErrorHandlingStrategy.throwError,
    void Function(GraphQLException)? onError,
  }) : _errorHandler = GraphQLErrorHandler(
          strategy: errorHandling,
          onError: onError,
        );

  @override
  Future<GraphQLResponse<T>> query<T>(
    String query, {
    Map<String, dynamic>? variables,
    CachePolicy cachePolicy = CachePolicy.networkOnly,
    Duration? ttl,
    String? operationName,
  }) async {
    _checkDisposed();
    try {
      // Validate and transform query
      if (!QueryTransformer.isValidQuery(query)) {
        throw GraphQLException(
          message: 'Invalid GraphQL query',
          extensions: {'type': 'validation_error'},
        );
      }

      final transformedQuery = QueryTransformer.addErrorFields(query);
      final cacheKey = _generateCacheKey(transformedQuery, variables);

      return await switch (cachePolicy) {
        CachePolicy.cacheFirst => _handleCacheFirstPolicy<T>(
            transformedQuery, variables, cacheKey, ttl, operationName),
        CachePolicy.cacheOnly => _handleCacheOnlyPolicy<T>(cacheKey),
        CachePolicy.networkOnly => _handleNetworkOnlyPolicy<T>(
            transformedQuery, variables, cacheKey, operationName),
        CachePolicy.networkFirst => _handleNetworkFirstPolicy<T>(
            transformedQuery, variables, cacheKey, ttl, operationName),
        CachePolicy.cacheAndNetwork => _handleCacheAndNetworkPolicy<T>(
            transformedQuery, variables, cacheKey, ttl, operationName),
        CachePolicy.mergeNetworkAndCache =>
          _handleMergeNetworkAndCachePolicy<T>(
              transformedQuery, variables, cacheKey, ttl, operationName),
        _ => _performRequest<T>(transformedQuery, variables, operationName),
      };
    } catch (e) {
      return _errorHandler.handleError(
        e,
        operationType: 'query',
        operationName: operationName,
      );
    }
  }

  @override
  Future<GraphQLResponse<T>> mutate<T>(
    String mutation, {
    Map<String, dynamic>? variables,
    List<String>? invalidateCache,
    String? operationName,
  }) async {
    _checkDisposed();
    try {
      final transformedMutation = QueryTransformer.addErrorFields(mutation);
      final response = await _performRequest<T>(
        transformedMutation,
        variables,
        operationName,
      );

      if (invalidateCache != null) {
        await invalidateQueries(invalidateCache);
      }
      return response;
    } catch (e) {
      return _errorHandler.handleError(
        e,
        operationType: 'mutation',
        operationName: operationName,
      );
    }
  }

  @override
  Future<BatchResponse> batch(List<BatchOperation> operations) async {
    _checkDisposed();
    try {
      final batchedQueries = operations
          .map((op) => {
                'query': QueryTransformer.addErrorFields(op.query),
                'variables': op.variables,
                'operationName': op.operationName,
              })
          .toList();

      final response = await _dio.post(
        '',
        data: batchedQueries,
        options: Options(headers: {'Content-Type': 'application/json'}),
      );

      return BatchResponse(
        responses: (response.data as List)
            .map((data) => ResponseParser.parse(data as Map<String, dynamic>))
            .toList(),
      );
    } catch (e) {
      return _errorHandler.handleError(
        e,
        operationType: 'batch',
      );
    }
  }

  @override
  Future<bool> validateQuery(
    String query, {
    Map<String, dynamic>? variables,
  }) async {
    _checkDisposed();
    return QueryTransformer.isValidQuery(query);
  }

  @override
  Future<GraphQLResponse<Map<String, dynamic>>> getSchema() async {
    _checkDisposed();
    return query(
      '''
      query IntrospectionQuery {
        __schema {
          types {
            name
            fields {
              name
              type {
                name
                kind
                ofType {
                  name
                  kind
                }
              }
            }
          }
        }
      }
      ''',
      cachePolicy: CachePolicy.networkOnly,
    );
  }

  // Cache management methods
  @override
  Future<void> clearCache() => _cacheManager.clear();

  @override
  Future<Map<String, dynamic>> getCacheStats() =>
      Future.value(_cacheManager.getCacheStats());

  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    await clearCache();
  }

  @override
  Future<void> invalidateQueries(List<String> queryKeys) async {
    for (final key in queryKeys) {
      await _cacheManager.invalidate(key);
    }
  }

  @override
  Future<void> refreshQueries(List<String> queryKeys) async {
    for (final key in queryKeys) {
      final data = await _cacheManager.get(key);
      if (data != null) {
        await _cacheManager.invalidate(key);
      }
    }
  }

// Cache Policy Handlers
  Future<GraphQLResponse<T>> _handleCacheFirstPolicy<T>(
    String query,
    Map<String, dynamic>? variables,
    String cacheKey,
    Duration? ttl,
    String? operationName,
  ) async {
    final cachedData = await _cacheManager.get<GraphQLResponse<T>>(cacheKey);
    if (cachedData != null) return cachedData;

    final response = await _performRequest<T>(query, variables, operationName);
    await _cacheManager.set(cacheKey, response, ttl: ttl);
    return response;
  }

  Future<GraphQLResponse<T>> _handleCacheOnlyPolicy<T>(String cacheKey) async {
    final cachedData = await _cacheManager.get<GraphQLResponse<T>>(cacheKey);
    if (cachedData == null) {
      throw _errorHandler.handleError(
        GraphQLException.cache('Data not found in cache'),
        operationType: 'cache',
      );
    }
    return cachedData;
  }

  Future<GraphQLResponse<T>> _handleNetworkOnlyPolicy<T>(
    String query,
    Map<String, dynamic>? variables,
    String cacheKey,
    String? operationName,
  ) async {
    final response = await _performRequest<T>(query, variables, operationName);
    await _cacheManager.set(cacheKey, response);
    return response;
  }

  Future<GraphQLResponse<T>> _handleNetworkFirstPolicy<T>(
    String query,
    Map<String, dynamic>? variables,
    String cacheKey,
    Duration? ttl,
    String? operationName,
  ) async {
    try {
      final response =
          await _performRequest<T>(query, variables, operationName);
      await _cacheManager.set(cacheKey, response, ttl: ttl);
      return response;
    } catch (e) {
      final cachedData = await _cacheManager.get<GraphQLResponse<T>>(cacheKey);
      if (cachedData != null) return cachedData;
      rethrow;
    }
  }

  Future<GraphQLResponse<T>> _handleCacheAndNetworkPolicy<T>(
    String query,
    Map<String, dynamic>? variables,
    String cacheKey,
    Duration? ttl,
    String? operationName,
  ) async {
    final cachedData = await _cacheManager.get<GraphQLResponse<T>>(cacheKey);
    if (cachedData != null) {
      _performRequest<T>(query, variables, operationName)
          .then((response) => _cacheManager.set(cacheKey, response, ttl: ttl));
      return cachedData;
    }

    return _handleNetworkOnlyPolicy<T>(
        query, variables, cacheKey, operationName);
  }

  Future<GraphQLResponse<T>> _handleMergeNetworkAndCachePolicy<T>(
    String query,
    Map<String, dynamic>? variables,
    String cacheKey,
    Duration? ttl,
    String? operationName,
  ) async {
    final cachedData = await _cacheManager.get<GraphQLResponse<T>>(cacheKey);
    final networkResponse =
        await _performRequest<T>(query, variables, operationName);

    if (cachedData != null && networkResponse.data != null) {
      final mergedData = {
        ...cachedData.data as Map<String, dynamic>,
        ...networkResponse.data as Map<String, dynamic>,
      };

      final mergedResponse = GraphQLResponse<T>(
        data: mergedData as T,
        extensions: networkResponse.extensions,
      );

      await _cacheManager.set(cacheKey, mergedResponse, ttl: ttl);
      return mergedResponse;
    }

    await _cacheManager.set(cacheKey, networkResponse, ttl: ttl);
    return networkResponse;
  }

  // Helper Methods
  Future<GraphQLResponse<T>> _performRequest<T>(
    String query,
    Map<String, dynamic>? variables,
    String? operationName,
  ) async {
    try {
      final response = await _dio.post(
        '',
        data: {
          'query': query,
          'variables': variables,
          if (operationName != null) 'operationName': operationName,
        },
        options: Options(
          headers: {'Content-Type': 'application/json'},
          responseType: ResponseType.json,
        ),
      );

      return ResponseParser.parse<T>(response.data);
    } on DioException catch (e) {
      throw _errorHandler.handleError(
        GraphQLException.network(
          'Network error: ${e.message}',
          originalException: e,
        ),
        operationType: 'network',
      );
    }
  }

  String _generateCacheKey(String query, Map<String, dynamic>? variables) {
    final keyData = {
      'query': query,
      'variables': variables,
    };
    final keyJson = json.encode(keyData);
    return md5.convert(utf8.encode(keyJson)).toString();
  }

  void _checkDisposed() {
    if (_isDisposed) {
      throw StateError('GraphQLRepositoryImpl has been disposed');
    }
  }
}
