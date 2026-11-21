import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../request/cancellation_token.dart';
import '../../request/graphql_document.dart';
import '../../request/graphql_request.dart';
import '../../response/graphql_exception.dart';
import '../../response/graphql_response.dart';
import '../graphql_transport.dart';
import 'interceptors/dio_aware_interceptor.dart';
import 'multipart_body.dart';

/// Sends queries and mutations over HTTP using [Dio].
///
/// Supports Automatic Persisted Queries ([persistedQueries]), GET for
/// queries ([useGetForQueries]) and file uploads (pass a `MultipartFile`
/// anywhere in the variables).
final class HttpTransport implements GraphQLTransport {
  /// Creates the transport.
  ///
  /// [interceptors] run in order; ones that mix in [DioAwareInterceptor]
  /// are attached to this transport's [Dio]. Pass [httpClientAdapter] for
  /// certificate pinning, proxies or tests.
  HttpTransport(
    this.endpoint, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 30),
    List<Interceptor> interceptors = const [],
    HttpClientAdapter? httpClientAdapter,
    this.persistedQueries = false,
    this.useGetForQueries = false,
  }) : _dio = Dio(BaseOptions(
          headers: headers,
          connectTimeout: timeout,
          sendTimeout: timeout,
          receiveTimeout: timeout,
          responseType: ResponseType.json,
          // GraphQL endpoints do not redirect; following one could re-send
          // credentials and variables to another host.
          followRedirects: false,
        )) {
    if (httpClientAdapter != null) _dio.httpClientAdapter = httpClientAdapter;
    for (final interceptor in interceptors) {
      if (interceptor is DioAwareInterceptor) interceptor.attachDio(_dio);
    }
    _dio.interceptors.addAll(interceptors);
  }

  /// The GraphQL endpoint URL.
  final String endpoint;

  /// Send a query hash first and the full query only when the server asks.
  final bool persistedQueries;

  /// Send queries (not mutations) as GET requests, which CDNs can cache.
  final bool useGetForQueries;

  final Dio _dio;
  bool _persistedQueriesSupported = true;

  @override
  Future<GraphQLResponse> execute(
    GraphQLRequest request, {
    CancellationToken? cancelToken,
  }) async {
    final dioCancel = _bridge(cancelToken);
    if (MultipartBody.hasFiles(request.variables)) {
      return _send(request, dioCancel, upload: true);
    }
    if (!persistedQueries || !_persistedQueriesSupported) {
      return _send(request, dioCancel);
    }

    final extensions = {
      'persistedQuery': {
        'version': 1,
        'sha256Hash': request.document.sha256Hash
      },
    };
    final hashOnly = await _send(
      request,
      dioCancel,
      includeQuery: false,
      extensions: extensions,
    );
    if (_isPersistedQueryNotSupported(hashOnly)) {
      // The server has APQ disabled: stop trying for this transport.
      _persistedQueriesSupported = false;
      return _send(request, dioCancel);
    }
    if (!_isPersistedQueryNotFound(hashOnly)) return hashOnly;
    return _send(request, dioCancel, extensions: extensions);
  }

  @override
  Stream<GraphQLResponse> subscribe(GraphQLRequest request) => Stream.error(
        GraphQLException(
          GraphQLErrorKind.invalidRequest,
          'Subscriptions need a WebSocket endpoint. Pass subscriptionEndpoint '
          'to GraphQLClient.',
          operationName: request.operationName,
        ),
      );

  @override
  Future<void> dispose() async => _dio.close();

  Future<GraphQLResponse> _send(
    GraphQLRequest request,
    CancelToken cancelToken, {
    bool includeQuery = true,
    Map<String, Object?>? extensions,
    bool upload = false,
  }) async {
    final options = Options(
      headers: {
        ...request.headers,
        // Lets CSRF-protected servers (e.g. Apollo) accept multipart uploads.
        if (upload) 'apollo-require-preflight': 'true',
      },
      extra: {
        RequestExtras.operationType: request.type.name,
        if (request.operationName != null)
          RequestExtras.operationName: request.operationName,
      },
    );
    final useGet = !upload &&
        useGetForQueries &&
        request.type == GraphQLOperationType.query;

    try {
      final Response<dynamic> response;
      if (useGet) {
        response = await _dio.get<dynamic>(
          endpoint,
          queryParameters: _getParameters(request, includeQuery, extensions),
          options: options,
          cancelToken: cancelToken,
        );
      } else {
        response = await _dio.post<dynamic>(
          endpoint,
          data: upload
              ? MultipartBody.encode(request)
              : request.toJson(
                  includeQuery: includeQuery,
                  extensions: extensions,
                ),
          options: options
            ..contentType = upload ? null : Headers.jsonContentType,
          cancelToken: cancelToken,
        );
      }
      return GraphQLResponse.fromJson(
        _decode(response.data),
        statusCode: response.statusCode,
      );
    } on DioException catch (e, stackTrace) {
      return _responseFromError(e, stackTrace, request);
    } on GraphQLException catch (e) {
      throw e.withOperationName(request.operationName);
    }
  }

  /// A non-2xx response that still carries a GraphQL body is returned as a
  /// response (the client derives the failure kind); anything else becomes a
  /// [GraphQLException].
  GraphQLResponse _responseFromError(
    DioException e,
    StackTrace stackTrace,
    GraphQLRequest request,
  ) {
    // Interceptors report their own failures (e.g. AuthInterceptor).
    if (e.error case final GraphQLException inner) {
      throw inner.withOperationName(request.operationName);
    }

    final response = e.response;
    if (response != null) {
      try {
        return GraphQLResponse.fromJson(
          _decode(response.data),
          statusCode: response.statusCode,
        );
      } on GraphQLException {
        // Not a GraphQL body; fall through.
      }
    }

    final kind = switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.transformTimeout =>
        GraphQLErrorKind.timeout,
      DioExceptionType.connectionError ||
      DioExceptionType.badCertificate =>
        GraphQLErrorKind.network,
      DioExceptionType.cancel => GraphQLErrorKind.cancelled,
      DioExceptionType.badResponse =>
        GraphQLException.kindFor(statusCode: response?.statusCode),
      DioExceptionType.unknown when _looksLikeNetworkError(e.error) =>
        GraphQLErrorKind.network,
      DioExceptionType.unknown => GraphQLErrorKind.unknown,
    };
    throw GraphQLException(
      kind,
      e.message ?? e.error?.toString() ?? 'HTTP request failed',
      statusCode: response?.statusCode,
      operationName: request.operationName,
      cause: e,
      stackTrace: stackTrace,
    );
  }

  Map<String, Object?> _getParameters(
    GraphQLRequest request,
    bool includeQuery,
    Map<String, Object?>? extensions,
  ) =>
      {
        if (includeQuery) 'query': request.document.printed,
        if (request.variables.isNotEmpty)
          'variables': jsonEncode(request.variables),
        if (request.operationName != null)
          'operationName': request.operationName,
        if (extensions != null) 'extensions': jsonEncode(extensions),
      };

  CancelToken _bridge(CancellationToken? token) {
    final dioToken = CancelToken();
    if (token != null) {
      if (token.isCancelled) {
        dioToken.cancel(token.reason);
      } else {
        unawaited(
            token.whenCancelled.then((_) => dioToken.cancel(token.reason)));
      }
    }
    return dioToken;
  }

  /// Some servers send JSON as `text/plain`; decode it ourselves.
  static Object? _decode(Object? data) {
    if (data is! String || data.isEmpty) return data;
    try {
      return jsonDecode(data);
    } on FormatException {
      return data;
    }
  }

  static bool _isPersistedQueryNotSupported(GraphQLResponse response) =>
      response.errors.any((e) =>
          e.message == 'PersistedQueryNotSupported' ||
          e.code == 'PERSISTED_QUERY_NOT_SUPPORTED');

  static bool _isPersistedQueryNotFound(GraphQLResponse response) =>
      response.errors.any((e) =>
          e.message == 'PersistedQueryNotFound' ||
          e.code == 'PERSISTED_QUERY_NOT_FOUND');

  /// `SocketException` lives in `dart:io`, which is unavailable on the web.
  static bool _looksLikeNetworkError(Object? error) {
    final text = error?.toString() ?? '';
    return text.contains('SocketException') ||
        text.contains('HandshakeException') ||
        text.contains('XMLHttpRequest');
  }
}
