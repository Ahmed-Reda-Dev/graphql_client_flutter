import 'dart:math';

import 'package:dio/dio.dart';

import 'dio_aware_interceptor.dart';

/// Retries requests that failed for transient reasons.
///
/// Retries connection errors, timeouts, HTTP 429 and 5xx with exponential
/// backoff and jitter, honouring a `Retry-After` header. Mutations are not
/// retried unless [retryMutations] is true, because a mutation that timed
/// out may already have run on the server. File uploads are never retried
/// (their streams can only be read once).
final class RetryInterceptor extends Interceptor with DioAwareInterceptor {
  /// Creates the interceptor.
  RetryInterceptor({
    this.maxRetries = 2,
    this.baseDelay = const Duration(milliseconds: 500),
    this.maxDelay = const Duration(seconds: 30),
    this.retryMutations = false,
    this.shouldRetry,
    Random? random,
  })  : assert(maxRetries >= 0, 'maxRetries must not be negative'),
        _random = random ?? Random();

  /// How many times a request is re-sent after the first attempt.
  final int maxRetries;

  /// Delay before the first retry; doubled for each later one.
  final Duration baseDelay;

  /// Upper bound for any single delay, including `Retry-After`.
  final Duration maxDelay;

  /// Whether mutations may be retried.
  final bool retryMutations;

  /// Overrides the default decision of which failures are retryable.
  final bool Function(DioException error)? shouldRetry;

  final Random _random;

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final options = err.requestOptions;
    // A re-sent request passes straight through: the first call owns the loop.
    if (options.extra[RequestExtras.retryAttempt] != null ||
        !_isRetryableRequest(options) ||
        !_isRetryableError(err)) {
      return handler.next(err);
    }

    var lastError = err;
    for (var attempt = 1; attempt <= maxRetries; attempt++) {
      await Future<void>.delayed(_delayFor(attempt, lastError));
      try {
        final response = await dio.fetch<dynamic>(options.copyWith(
          extra: {...options.extra, RequestExtras.retryAttempt: attempt},
        ));
        return handler.resolve(response);
      } on DioException catch (e) {
        lastError = e;
        if (!_isRetryableError(e)) break;
      }
    }
    handler.next(lastError);
  }

  bool _isRetryableRequest(RequestOptions options) {
    if (maxRetries == 0 || options.data is FormData) return false;
    final isMutation = options.extra[RequestExtras.operationType] == 'mutation';
    return retryMutations || !isMutation;
  }

  bool _isRetryableError(DioException error) {
    final custom = shouldRetry;
    if (custom != null) return custom(error);
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.connectionError =>
        true,
      DioExceptionType.badResponse => switch (error.response?.statusCode) {
          429 || 502 || 503 || 504 => true,
          final int s => s >= 500 && !_hasGraphQLErrors(error.response?.data),
          null => false,
        },
      _ => false,
    };
  }

  /// A 500 with a GraphQL body is an execution error, not an outage.
  static bool _hasGraphQLErrors(Object? body) =>
      body is Map && body['errors'] is List;

  Duration _delayFor(int attempt, DioException error) {
    final retryAfter = _parseRetryAfter(error.response?.headers);
    if (retryAfter != null) {
      return retryAfter > maxDelay ? maxDelay : retryAfter;
    }

    final exponential = baseDelay * pow(2, attempt - 1);
    final jitter = exponential * (_random.nextDouble() * 0.25);
    final delay = exponential + jitter;
    return delay > maxDelay ? maxDelay : delay;
  }

  /// Reads `Retry-After` in its delay-seconds form. The HTTP-date form is
  /// rare for APIs and falls back to normal backoff.
  static Duration? _parseRetryAfter(Headers? headers) {
    final seconds = int.tryParse(headers?.value('retry-after')?.trim() ?? '');
    return seconds == null || seconds < 0 ? null : Duration(seconds: seconds);
  }
}
