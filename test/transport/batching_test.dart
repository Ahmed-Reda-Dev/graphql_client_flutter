import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_client_flutter/graphql_client_flutter.dart';

import '../support/fake_http_adapter.dart';

GraphQLRequest req(
  String name, {
  String type = 'query',
  Map<String, String> headers = const {},
}) =>
    GraphQLRequest(
      document:
          GraphQLDocument.parse('$type $name { $name }', addTypename: false),
      headers: headers,
    );

/// Answers a batch with one response per operation, echoing its name.
FakeReply echoBatch(RequestOptions request) {
  final body = request.data;
  if (body is List) {
    return FakeReply([
      for (final op in body)
        {
          'data': {(op as Map)['operationName']: true},
        },
    ]);
  }
  final op = body as Map;
  return ok({op['operationName'] as String: true});
}

HttpTransport transport(
  FakeHttpAdapter adapter, {
  BatchOptions batch = const BatchOptions(window: Duration(milliseconds: 5)),
  List<Interceptor> interceptors = const [],
}) =>
    HttpTransport(
      'https://api.test/graphql',
      httpClientAdapter: adapter,
      batch: batch,
      interceptors: interceptors,
    );

void main() {
  test('queries started together are sent as one request', () async {
    final adapter = FakeHttpAdapter((r, _) => echoBatch(r));
    final http = transport(adapter);

    final responses = await Future.wait([
      http.execute(req('A')),
      http.execute(req('B')),
      http.execute(req('C')),
    ]);

    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.data, isA<List<dynamic>>());
    expect(responses.map((r) => r.data!.keys.single), ['A', 'B', 'C']);
  });

  test('a full batch is sent without waiting for the window', () async {
    final adapter = FakeHttpAdapter((r, _) => echoBatch(r));
    final http = transport(
      adapter,
      batch: const BatchOptions(window: Duration(hours: 1), maxBatchSize: 2),
    );

    await Future.wait([http.execute(req('A')), http.execute(req('B'))]);

    expect(adapter.requests, hasLength(1));
  });

  test('requests with different headers are batched separately', () async {
    final adapter = FakeHttpAdapter((r, _) => echoBatch(r));
    final http = transport(adapter);

    await Future.wait([
      http.execute(req('A', headers: {'X-Tenant': '1'})),
      http.execute(req('B', headers: {'X-Tenant': '1'})),
      http.execute(req('C', headers: {'X-Tenant': '2'})),
    ]);

    expect(adapter.requests, hasLength(2));
  });

  test('mutations are never batched', () async {
    final adapter = FakeHttpAdapter((r, _) => echoBatch(r));
    final http = transport(adapter);

    await Future.wait([
      http.execute(req('A')),
      http.execute(req('M', type: 'mutation')),
    ]);

    expect(adapter.requests.map((r) => r.data is List), [false, false]);
  });

  test('falls back to single requests when the server cannot batch', () async {
    final adapter = FakeHttpAdapter((r, _) => r.data is List
        ? const FakeReply({
            'errors': [
              {'message': 'Batching is not supported'},
            ],
          }, status: 400)
        : echoBatch(r));
    final http = transport(adapter);

    final first =
        await Future.wait([http.execute(req('A')), http.execute(req('B'))]);
    expect(first.map((r) => r.data!.keys.single), ['A', 'B']);
    expect(adapter.requests, hasLength(3)); // 1 rejected batch + 2 singles.

    await Future.wait([http.execute(req('C')), http.execute(req('D'))]);
    expect(adapter.requests, hasLength(5), reason: 'batching is now off');
  });

  test('a network failure fails every request in the batch', () async {
    final adapter = FakeHttpAdapter((r, _) =>
        throw DioException.connectionError(requestOptions: r, reason: 'down'));
    final http = transport(adapter);

    final results = await Future.wait([
      http.execute(req('A')).then<Object>((r) => r, onError: (Object e) => e),
      http.execute(req('B')).then<Object>((r) => r, onError: (Object e) => e),
    ]);

    expect(
        results,
        everyElement(isA<GraphQLException>()
            .having((e) => e.kind, 'kind', GraphQLErrorKind.network)));
  });

  test('a request cancelled before sending leaves the batch', () async {
    final adapter = FakeHttpAdapter((r, _) => echoBatch(r));
    final http = transport(adapter);
    final token = CancellationToken();

    final cancelled = http.execute(req('A'), cancelToken: token);
    final kept = http.execute(req('B'));
    token.cancel();

    await expectLater(
      cancelled,
      throwsA(isA<GraphQLException>()
          .having((e) => e.kind, 'kind', GraphQLErrorKind.cancelled)),
    );
    expect((await kept).data, {'B': true});
    expect(adapter.requests.single.data, isA<Map<dynamic, dynamic>>(),
        reason: 'a batch of one is sent as a normal request');
  });

  test('an expired token inside a batch triggers one refresh', () async {
    var token = 'old';
    final adapter = FakeHttpAdapter((r, _) {
      if (r.headers['Authorization'] != 'Bearer new' && r.data is List) {
        return const FakeReply([
          {
            'errors': [
              {
                'message': 'expired',
                'extensions': {'code': 'UNAUTHENTICATED'}
              },
            ],
          },
          {
            'data': {'B': true}
          },
        ]);
      }
      return echoBatch(r);
    });
    final http = transport(adapter, interceptors: [
      AuthInterceptor(
          token: () => token, refreshToken: () async => token = 'new'),
    ]);

    final responses =
        await Future.wait([http.execute(req('A')), http.execute(req('B'))]);

    expect(responses.map((r) => r.hasErrors), [false, false]);
    expect(adapter.requests, hasLength(2));
  });

  test('the client batches concurrent queries end to end', () async {
    final adapter = FakeHttpAdapter((r, _) => echoBatch(r));
    final client = GraphQLClient(
      'https://api.test/graphql',
      httpClientAdapter: adapter,
      batch: const BatchOptions(),
      addTypename: false,
    );
    addTearDown(client.dispose);

    final results = await Future.wait([
      client.query<JsonMap>('query A { A }'),
      client.query<JsonMap>('query B { B }'),
    ]);

    expect(results.every((r) => r.isSuccess), isTrue);
    expect(adapter.requests, hasLength(1));
  });
}
