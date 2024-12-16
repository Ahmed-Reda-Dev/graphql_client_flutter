import 'dart:math';

import 'package:dio/dio.dart';

import '../../../graphql_client_flutter.dart';

/// An interceptor that handles retrying failed requests
class RetryInterceptor extends Interceptor {
  /// Maximum number of retry attempts
  final int maxRetries;

  /// Base delay between retries
  final Duration retryDelay;

  /// Whether to use exponential backoff
  final bool useExponentialBackoff;

  /// Optional callback to determine if a request should be retried
  final bool Function(DioException)? shouldRetry;

  /// Optional callback to handle retry attempts
  final void Function(int, DioException)? onRetry;

  RetryInterceptor({
    this.maxRetries = 3,
    this.retryDelay = const Duration(seconds: 1),
    this.useExponentialBackoff = true,
    this.shouldRetry,
    this.onRetry,
  });

  @override
  Future<void> onError(
      DioException err, ErrorInterceptorHandler handler) async {
    final attempt = _getRetryAttempt(err.requestOptions);

    if (!_shouldAttemptRetry(err, attempt)) {
      return handler.next(err);
    }

    try {
      await _executeRetry(err, handler, attempt);
    } catch (e) {
      handler.next(DioException(
        requestOptions: err.requestOptions,
        error: e,
        type: DioExceptionType.unknown,
      ));
    }
  }

    bool _shouldAttemptRetry(DioException err, int attempt) {
    return attempt < maxRetries &&
        _shouldRetryRequest(err) &&
        _isValidGraphQLRequest(err.requestOptions);
  }

  bool _isValidGraphQLRequest(RequestOptions request) {
    if (request.data is! Map<String, dynamic>) return false;
    final query = request.data['query'] as String?;
    return query != null && QueryTransformer.isValidQuery(query);
  }

  Future<void> _executeRetry(
    DioException err,
    ErrorInterceptorHandler handler,
    int attempt,
  ) async {
    final delay = _calculateDelay(attempt);
    await Future.delayed(delay);

    onRetry?.call(attempt + 1, err);

    final response = await _retry(err.requestOptions, attempt + 1);

    // Validate response before resolving
    if (response.data is Map<String, dynamic>) {
      ResponseParser.validate(response.data as Map<String, dynamic>);
    }

    handler.resolve(response);
  }

  Future<Response<dynamic>> _retry(
    RequestOptions requestOptions,
    int attempt,
  ) async {
    final options = Options(
      method: requestOptions.method,
      headers: requestOptions.headers,
      contentType: requestOptions.contentType,
      responseType: requestOptions.responseType,
      extra: {
        ...requestOptions.extra,
        _retryAttemptKey: attempt,
      },
    );

    return await Dio().request<dynamic>(
      requestOptions.path,
      data: requestOptions.data,
      queryParameters: requestOptions.queryParameters,
      options: options,
    );
  }

  bool _shouldRetryRequest(DioException error) {
    if (shouldRetry != null) {
      return shouldRetry!(error);
    }
    // Add handling for GraphQL-specific errors
    if (error.response?.data is Map<String, dynamic>) {
      final data = error.response!.data as Map<String, dynamic>;
      if (data['errors'] != null) {
        return false; // Don't retry on GraphQL validation errors
      }
    }
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.connectionError => true,
      DioExceptionType.badResponse => _isRetryableStatusCode(
          error.response?.statusCode,
        ),
      _ => false,
    };
  }

  bool _isRetryableStatusCode(int? statusCode) {
    if (statusCode == null) return false;
    // Retry on server errors and some specific client errors
    return statusCode >= 500 || statusCode == 429; // 429 = Too Many Requests
  }

  Duration _calculateDelay(int attempt) {
    if (!useExponentialBackoff) {
      return retryDelay;
    }

    // Exponential backoff with jitter
    final exponentialDelay = retryDelay.inMilliseconds * (1 << attempt);
    final jitter = (exponentialDelay * 0.2 * Random().nextDouble()).toInt();
    
    return Duration(milliseconds: exponentialDelay + jitter);
  }

  static const _retryAttemptKey = 'retry_attempt';

  int _getRetryAttempt(RequestOptions request) {
    return request.extra[_retryAttemptKey] as int? ?? 0;
  }
}