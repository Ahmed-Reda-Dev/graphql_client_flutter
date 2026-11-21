import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// A canned HTTP reply.
class FakeReply {
  const FakeReply(
    this.body, {
    this.status = 200,
    this.headers = const {},
    this.raw = false,
  });

  /// JSON-encoded unless [raw] is true (then sent as text).
  final Object? body;
  final int status;
  final Map<String, String> headers;
  final bool raw;
}

/// Records requests and answers them with [handler].
///
/// [handler] gets the request and its zero-based index; it may throw a
/// [DioException] to simulate a transport failure.
class FakeHttpAdapter implements HttpClientAdapter {
  FakeHttpAdapter(this.handler);

  final FutureOr<FakeReply> Function(RequestOptions request, int index) handler;
  final List<RequestOptions> requests = [];

  /// Request [index]'s JSON body (POST) or query parameters (GET).
  Map<String, dynamic> body(int index) {
    final request = requests[index];
    return request.data is Map
        ? request.data as Map<String, dynamic>
        : request.queryParameters;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final reply = await handler(options, requests.length - 1);
    return ResponseBody.fromString(
      reply.raw ? reply.body! as String : jsonEncode(reply.body),
      reply.status,
      headers: {
        Headers.contentTypeHeader: [
          reply.raw ? 'text/plain' : Headers.jsonContentType,
        ],
        for (final MapEntry(:key, :value) in reply.headers.entries)
          key: [value],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A successful GraphQL reply with [data].
FakeReply ok(Map<String, dynamic> data) => FakeReply({'data': data});
