import 'package:dio/dio.dart';

/// Interceptor for handling authentication in GraphQL requests
class AuthInterceptor extends Interceptor {
  /// Function to get the current authentication token
  final Future<String> Function() getToken;

  /// Function to refresh the token when expired
  final Future<String> Function()? refreshToken;

  /// Function to handle authentication errors
  final void Function(DioException error)? onAuthenticationError;

  /// Whether to automatically retry failed requests with refreshed token
  final bool autoRetryWithRefreshedToken;

  /// Maximum number of retry attempts for failed auth
  final int maxAuthRetries;

  /// Token type (e.g., 'Bearer', 'Basic')
  final String tokenType;

  /// Header key for authorization
  final String authHeaderKey;

  int _retryCount = 0;
  bool _isRefreshing = false;

  AuthInterceptor({
    required this.getToken,
    this.refreshToken,
    this.onAuthenticationError,
    this.autoRetryWithRefreshedToken = true,
    this.maxAuthRetries = 3,
    this.tokenType = 'Bearer',
    this.authHeaderKey = 'Authorization',
  });

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    try {
      final token = await getToken();
      if (token.isNotEmpty) {
        options.headers[authHeaderKey] = '$tokenType $token';
      }
      handler.next(options);
    } catch (e) {
      handler.reject(
        DioException(
          requestOptions: options,
          error: 'Failed to get authentication token: $e',
        ),
      );
    }
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    if (!_shouldHandleAuthError(err)) {
      return handler.next(err);
    }

    try {
      if (_isRefreshing) {
        // Wait for the current refresh to complete
        await _waitForRefresh();
        return _retryRequest(err, handler);
      }

      if (_retryCount >= maxAuthRetries) {
        _resetRetryCount();
        return _handleAuthenticationError(err, handler);
      }

      if (!autoRetryWithRefreshedToken || refreshToken == null) {
        return _handleAuthenticationError(err, handler);
      }

      _isRefreshing = true;
      _retryCount++;

      // Attempt to refresh the token
      final newToken = await refreshToken!();
      _isRefreshing = false;

      if (newToken.isEmpty) {
        return _handleAuthenticationError(err, handler);
      }

      return _retryRequest(err, handler);
    } catch (e) {
      _resetRetryCount();
      _isRefreshing = false;
      return _handleAuthenticationError(err, handler);
    }
  }

  /// Determines if the error should be handled by this interceptor
  bool _shouldHandleAuthError(DioException err) {
    return err.response?.statusCode == 401 || err.response?.statusCode == 403;
  }

  /// Handles authentication errors
  void _handleAuthenticationError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) {
    onAuthenticationError?.call(err);
    handler.next(err);
  }

  /// Retries the failed request with the new token
  Future<void> _retryRequest(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    try {
      final token = await getToken();
      final options = err.requestOptions;
      options.headers[authHeaderKey] = '$tokenType $token';

      final response = await Dio().fetch(options);
      handler.resolve(response);
    } catch (e) {
      handler.next(err);
    }
  }

  /// Resets the retry counter
  void _resetRetryCount() {
    _retryCount = 0;
  }

  /// Waits for the current token refresh to complete
  Future<void> _waitForRefresh() async {
    while (_isRefreshing) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  @override
  void onResponse(
    Response response,
    ResponseInterceptorHandler handler,
  ) {
    // Reset retry count on successful response
    _resetRetryCount();
    handler.next(response);
  }
}
