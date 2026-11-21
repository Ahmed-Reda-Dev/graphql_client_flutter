import 'dart:async';

import 'package:dio/dio.dart';

import '../../../response/graphql_exception.dart';
import '../../credential_policy.dart';
import 'dio_aware_interceptor.dart';

/// Returns the current access token, or null when signed out.
typedef TokenProvider = FutureOr<String?> Function();

/// Obtains a new access token, or returns null when that is impossible
/// (for example, the refresh token expired).
typedef TokenRefresher = Future<String?> Function();

/// Adds an access token to every request and refreshes it when it expires.
///
/// An expired token is detected from HTTP 401 or from a GraphQL error with
/// code `UNAUTHENTICATED` in an otherwise successful response (the usual
/// GraphQL behaviour). Concurrent failures share a single refresh, and each
/// request is retried at most once.
///
/// Credentials are never sent over unencrypted `http://` to a public host
/// unless [allowInsecureAuth] is true; local and private-network hosts
/// (emulators, LAN servers) are allowed.
final class AuthInterceptor extends Interceptor with DioAwareInterceptor {
  /// Creates the interceptor.
  AuthInterceptor({
    required this.token,
    this.refreshToken,
    this.onRefreshFailed,
    this.headerName = 'Authorization',
    this.scheme = 'Bearer',
    this.allowInsecureAuth = false,
  });

  /// Supplies the current token.
  final TokenProvider token;

  /// Supplies a new token after the current one is rejected.
  final TokenRefresher? refreshToken;

  /// Called when refreshing fails, e.g. to sign the user out.
  final void Function(Object? error)? onRefreshFailed;

  /// The header that carries the token.
  final String headerName;

  /// Prefix before the token (`Bearer`). Empty to send the raw token.
  final String scheme;

  /// Whether the token may be sent over `http://` to a public host.
  final bool allowInsecureAuth;

  Future<String?>? _refreshing;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    // A retry after refresh already carries the new token; reading the
    // provider again could put back a stale one.
    if (options.extra[RequestExtras.authRetried] == true) {
      return handler.next(options);
    }
    if (!allowInsecureAuth &&
        !CredentialPolicy.isSafeForCredentials(options.uri)) {
      return handler.reject(DioException(
        requestOptions: options,
        error: GraphQLException(
          GraphQLErrorKind.invalidRequest,
          CredentialPolicy.insecureMessage(options.uri),
        ),
      ));
    }
    try {
      final value = await token();
      if (value != null && value.isNotEmpty) {
        options.headers[headerName] = _format(value);
      }
      handler.next(options);
    } catch (e, stackTrace) {
      // The provider's error text is not included: it could contain token
      // material. It stays available as the exception's cause.
      handler.reject(DioException(
        requestOptions: options,
        error: GraphQLException(
          GraphQLErrorKind.unauthenticated,
          'Failed to read the access token',
          cause: e,
          stackTrace: stackTrace,
        ),
      ));
    }
  }

  @override
  Future<void> onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) async {
    if (!_canRetry(response.requestOptions) ||
        !_hasUnauthenticatedError(response.data)) {
      return handler.next(response);
    }
    try {
      final retried = await _refreshAndRetry(response.requestOptions);
      handler.next(retried ?? response);
    } on DioException catch (e) {
      handler.reject(e);
    }
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    if (err.response?.statusCode != 401 || !_canRetry(err.requestOptions)) {
      return handler.next(err);
    }
    try {
      final retried = await _refreshAndRetry(err.requestOptions);
      if (retried == null) return handler.next(err);
      handler.resolve(retried);
    } on DioException catch (e) {
      handler.next(e);
    }
  }

  bool _canRetry(RequestOptions options) =>
      refreshToken != null && options.extra[RequestExtras.authRetried] != true;

  /// Refreshes the token and re-sends [original]. Returns null when no new
  /// token could be obtained.
  Future<Response<dynamic>?> _refreshAndRetry(RequestOptions original) async {
    final String? newToken;
    try {
      newToken = await _currentOrRefreshed(original);
    } catch (e) {
      onRefreshFailed?.call(e);
      return null;
    }
    if (newToken == null || newToken.isEmpty) {
      onRefreshFailed?.call(null);
      return null;
    }

    return dio.fetch<dynamic>(original.copyWith(
      headers: {...original.headers, headerName: _format(newToken)},
      extra: {...original.extra, RequestExtras.authRetried: true},
    ));
  }

  /// Returns a token newer than the one [original] was sent with: the
  /// current one if another request already refreshed it, otherwise the
  /// result of a (shared) refresh.
  Future<String?> _currentOrRefreshed(RequestOptions original) async {
    final current = await token();
    if (current != null &&
        current.isNotEmpty &&
        _format(current) != original.headers[headerName]) {
      return current;
    }
    return _refreshing ??= refreshToken!().whenComplete(() {
      _refreshing = null;
    });
  }

  String _format(String value) => scheme.isEmpty ? value : '$scheme $value';

  static bool _hasUnauthenticatedError(Object? body) {
    if (body is! Map) return false;
    final errors = body['errors'];
    if (errors is! List) return false;
    return errors.any((e) =>
        e is Map &&
        e['extensions'] is Map &&
        (e['extensions'] as Map)['code'] == 'UNAUTHENTICATED');
  }
}
