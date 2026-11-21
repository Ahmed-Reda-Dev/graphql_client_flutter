import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_client_flutter/graphql_client_flutter.dart';

import '../support/fake_http_adapter.dart';

const _endpoint = 'https://api.test/graphql';

GraphQLRequest request(
  String document, {
  JsonMap variables = const {},
  bool addTypename = false,
}) =>
    GraphQLRequest(
      document: GraphQLDocument.parse(document, addTypename: addTypename),
      variables: variables,
    );

HttpTransport transport(
  FakeHttpAdapter adapter, {
  bool persistedQueries = false,
  bool useGetForQueries = false,
  List<Interceptor> interceptors = const [],
}) =>
    HttpTransport(
      _endpoint,
      httpClientAdapter: adapter,
      persistedQueries: persistedQueries,
      useGetForQueries: useGetForQueries,
      interceptors: interceptors,
    );

void main() {
  group('HttpTransport', () {
    test('POSTs the standard body', () async {
      final adapter = FakeHttpAdapter((_, __) => ok({'a': 1}));
      final req =
          request(r'query Q($id: ID) { a(id: $id) }', variables: {'id': '1'});
      final response = await transport(adapter).execute(req);

      expect(response.data, {'a': 1});
      expect(adapter.requests.single.method, 'POST');
      expect(adapter.body(0), {
        'query': req.document.printed,
        'variables': {'id': '1'},
        'operationName': 'Q',
      });
    });

    test('returns 4xx responses that carry a GraphQL body', () async {
      final adapter = FakeHttpAdapter((_, __) => const FakeReply({
            'errors': [
              {
                'message': 'bad',
                'extensions': {'code': 'BAD_USER_INPUT'}
              },
            ],
          }, status: 400));
      final response = await transport(adapter).execute(request('{ a }'));
      expect(response.statusCode, 400);
      expect(response.errors.single.code, 'BAD_USER_INPUT');
    });

    test('maps non-GraphQL failures to kinds', () async {
      Future<GraphQLErrorKind> kindOf(FakeHttpAdapter adapter) async {
        try {
          await transport(adapter).execute(request('{ a }'));
        } on GraphQLException catch (e) {
          return e.kind;
        }
        fail('expected a GraphQLException');
      }

      expect(
        await kindOf(FakeHttpAdapter((_, __) =>
            const FakeReply('<h1>Bad gateway</h1>', status: 502, raw: true))),
        GraphQLErrorKind.server,
      );
      expect(
        await kindOf(FakeHttpAdapter((r, __) =>
            throw DioException.connectionTimeout(
                requestOptions: r, timeout: Duration.zero))),
        GraphQLErrorKind.timeout,
      );
      expect(
        await kindOf(FakeHttpAdapter((r, __) =>
            throw DioException.connectionError(
                requestOptions: r, reason: 'x'))),
        GraphQLErrorKind.network,
      );
      expect(
        await kindOf(
            FakeHttpAdapter((_, __) => const FakeReply('not json', raw: true))),
        GraphQLErrorKind.invalidResponse,
      );
    });

    test('decodes JSON sent as text/plain', () async {
      final adapter = FakeHttpAdapter((_, __) => FakeReply(
          jsonEncode({
            'data': {'a': 1},
          }),
          raw: true));
      final response = await transport(adapter).execute(request('{ a }'));
      expect(response.data, {'a': 1});
    });

    test('sends queries as GET when enabled, mutations still POST', () async {
      final adapter = FakeHttpAdapter((_, __) => ok({'a': 1}));
      final http = transport(adapter, useGetForQueries: true);

      await http.execute(
          request(r'query Q($x: Int) { a(x: $x) }', variables: {'x': 1}));
      await http.execute(request('mutation M { b }'));

      expect(adapter.requests[0].method, 'GET');
      expect(adapter.requests[0].queryParameters['variables'], '{"x":1}');
      expect(adapter.requests[1].method, 'POST');
    });

    test('cancellation maps to cancelled', () async {
      final adapter = FakeHttpAdapter((_, __) => ok({'a': 1}));
      final token = CancellationToken()..cancel();
      await expectLater(
        transport(adapter).execute(request('{ a }'), cancelToken: token),
        throwsA(isA<GraphQLException>()
            .having((e) => e.kind, 'kind', GraphQLErrorKind.cancelled)),
      );
    });

    test('subscriptions over HTTP explain what to configure', () {
      expect(
        transport(FakeHttpAdapter((_, __) => ok({})))
            .subscribe(request('subscription S { s }')),
        emitsError(isA<GraphQLException>().having(
            (e) => e.message, 'message', contains('subscriptionEndpoint'))),
      );
    });
  });

  group('persisted queries', () {
    test('sends only the hash when the server knows it', () async {
      final adapter = FakeHttpAdapter((_, __) => ok({'a': 1}));
      final req = request('query Q { a }');
      await transport(adapter, persistedQueries: true).execute(req);

      final body = adapter.body(0);
      expect(body.containsKey('query'), isFalse);
      expect(body['extensions'], {
        'persistedQuery': {'version': 1, 'sha256Hash': req.document.sha256Hash},
      });
    });

    test('retries with the full query on PersistedQueryNotFound', () async {
      final adapter = FakeHttpAdapter((_, index) => index == 0
          ? const FakeReply({
              'errors': [
                {'message': 'PersistedQueryNotFound'},
              ],
            })
          : ok({'a': 1}));
      final response = await transport(adapter, persistedQueries: true)
          .execute(request('query Q { a }'));

      expect(response.data, {'a': 1});
      expect(adapter.requests, hasLength(2));
      expect(adapter.body(1)['query'], isNotNull);
      expect(adapter.body(1)['extensions'], isNotNull);
    });
  });

  group('file uploads', () {
    test('encodes the GraphQL multipart request spec', () async {
      final adapter = FakeHttpAdapter((_, __) => ok({'upload': true}));
      await transport(adapter).execute(request(
        r'mutation Upload($file: Upload!, $docs: [Upload!]!) '
        r'{ upload(file: $file, docs: $docs) }',
        variables: {
          'file': MultipartFile.fromString('a', filename: 'a.txt'),
          'docs': [MultipartFile.fromString('b', filename: 'b.txt')],
        },
      ));

      final sent = adapter.requests.single;
      final form = sent.data as FormData;
      final fields = Map.fromEntries(form.fields);
      final operations = jsonDecode(fields['operations']!) as JsonMap;

      expect(operations['variables'], {
        'file': null,
        'docs': [null],
      });
      expect(jsonDecode(fields['map']!), {
        '0': ['variables.file'],
        '1': ['variables.docs.0'],
      });
      expect(form.files.map((f) => f.key), ['0', '1']);
      expect(sent.headers['apollo-require-preflight'], 'true');
    });
  });
}
