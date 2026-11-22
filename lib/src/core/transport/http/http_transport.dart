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
import 'request_batcher.dart';

/// Sends queries and mutations over HTTP using [Dio].
///
/// Supports Automatic Persisted Queries ([persistedQueries]), GET for
/// queries ([useGetForQueries]), automatic query batching ([batch]) and
/// file uploads (pass a `MultipartFile` anywhere in the variables).
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
    this.batch,
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
    // Responses of 50 KB or more are decoded in a background isolate so
    // large lists do not drop frames (Flutter's own threshold for assets).
    _dio.transformer = FusedTransformer(
      contentLengthIsolateThreshold: _isolateDecodingThreshold,
    );
    if (httpClientAdapter != null) _dio.httpClientAdapter = httpClientAdapter;
    for (final interceptor in interceptors) {
      if (interceptor is DioAwareInterceptor) interceptor.attachDio(_dio);
    }
    _dio.interceptors.addAll(interceptors);
    final batch = this.batch;
    if (batch != null) _batcher = RequestBatcher(batch, _sendBatch);
  }

  static const _isolateDecodingThreshold = 50 * 1024;

  /// The GraphQL endpoint URL.
  final String endpoint;

  /// Send a query hash first and the full query only when the server asks.
  final bool persistedQueries;

  /// Send queries (not mutations) as GET requests, which CDNs can cache.
  final bool useGetForQueries;

  /// Sends queries started close together as one request, when set.
  /// Mutations and uploads are never batched.
  final BatchOptions? batch;

  final Dio _dio;
  RequestBatcher? _batcher;
  bool _persistedQueriesSupported = true;
  bool _batchingSupported = true;

  @override
  Future<GraphQLResponse> execute(
    GraphQLRequest request, {
    CancellationToken? cancelToken,
  }) {
    final batcher = _batcher;
    if (batcher != null &&
        _batchingSupported &&
        request.type == GraphQLOperationType.query &&
        !MultipartBody.hasFiles(request.variables)) {
      return batcher.add(request, cancelToken);
    }
    return _executeOne(request, cancelToken);
  }

  Future<GraphQLResponse> _executeOne(
    GraphQLRequest request,
    CancellationToken? cancelToken,
  ) async {
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
  Future<void> dispose() async {
    _batcher?.dispose();
    _dio.close();
  }

  /// Sends [requests] as one JSON-array request. Falls back to individual
  /// requests (and stops batching) when the server does not answer with an
  /// array of matching length.
  Future<List<GraphQLResponse>> _sendBatch(
      List<GraphQLRequest> requests) async {
    if (requests.length == 1 || !_batchingSupported) {
      return Future.wait(requests.map((r) => _executeOne(r, null)));
    }
    final names = requests.map((r) => r.operationName ?? 'anonymous');
    Object? body;
    int? status;
    try {
      final response = await _dio.post<dynamic>(
        endpoint,
        data: [for (final request in requests) request.toJson()],
        options: Options(
          headers: requests.first.headers,
          contentType: Headers.jsonContentType,
          extra: {
            RequestExtras.operationType: 'query',
            RequestExtras.operationName: 'batch: ${names.join(', ')}',
          },
        ),
      );
      body = _decode(response.data);
      status = response.statusCode;
    } on DioException catch (e, stackTrace) {
      if (e.error case final GraphQLException inner) throw inner;
      final response = e.response;
      if (response == null) throw _transportException(e, stackTrace, null);
      body = _decode(response.data);
      status = response.statusCode;
    }

    if (body is List && body.length == requests.length) {
      return [
        for (final item in body)
          GraphQLResponse.fromJson(item, statusCode: status),
      ];
    }
    // Not a batch response: this server does not support batching.
    _batchingSupported = false;
    return Future.wait(requests.map((r) => _executeOne(r, null)));
  }

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

    throw _transportException(e, stackTrace, request.operationName);
  }

  /// Maps a failure without a GraphQL body to a [GraphQLException].
  GraphQLException _transportException(
    DioException e,
    StackTrace stackTrace,
    String? operationName,
  ) {
    final response = e.response;
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
    return GraphQLException(
      kind,
      e.message ?? e.error?.toString() ?? 'HTTP request failed',
      statusCode: response?.statusCode,
      operationName: operationName,
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
