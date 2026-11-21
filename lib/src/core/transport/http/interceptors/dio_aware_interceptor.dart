import 'package:dio/dio.dart';

/// Keys this package stores in `RequestOptions.extra`.
abstract final class RequestExtras {
  /// The operation type name (`query`, `mutation`, `subscription`).
  static const operationType = 'graphql.operationType';

  /// The operation name, for logging.
  static const operationName = 'graphql.operationName';

  /// Set on requests re-sent by `RetryInterceptor`.
  static const retryAttempt = 'graphql.retryAttempt';

  /// Set on requests re-sent by `AuthInterceptor` after a token refresh.
  static const authRetried = 'graphql.authRetried';

  /// Request start time, for logging.
  static const startedAt = 'graphql.startedAt';
}

/// For interceptors that re-send requests (retry, token refresh).
///
/// Re-sending must go through the same [Dio] that made the original request
/// so its adapter (proxy, certificate pinning) and the other interceptors
/// still apply. `HttpTransport` calls [attachDio] on every interceptor that
/// mixes this in.
mixin DioAwareInterceptor on Interceptor {
  Dio? _attachedDio;

  /// Attaches the [Dio] instance this interceptor is installed on.
  void attachDio(Dio dio) => _attachedDio = dio;

  /// The [Dio] used to re-send requests.
  ///
  /// Throws a [StateError] when the interceptor was never attached, which
  /// would otherwise silently bypass the adapter and other interceptors.
  Dio get dio {
    final dio = _attachedDio;
    if (dio == null) {
      throw StateError(
        '$runtimeType is not attached to a Dio instance. Add it through '
        'HttpTransport/GraphQLClient, or call attachDio(dio) yourself.',
      );
    }
    return dio;
  }
}
