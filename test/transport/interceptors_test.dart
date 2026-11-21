import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_client_flutter/graphql_client_flutter.dart';

import '../support/fake_http_adapter.dart';

GraphQLRequest req(String document, {JsonMap variables = const {}}) =>
    GraphQLRequest(
      document: GraphQLDocument.parse(document, addTypename: false),
      variables: variables,
    );

HttpTransport http(FakeHttpAdapter adapter, List<Interceptor> interceptors) =>
    HttpTransport(
      'https://api.test/graphql',
      httpClientAdapter: adapter,
      interceptors: interceptors,
    );

RetryInterceptor fastRetry({int maxRetries = 2, bool retryMutations = false}) =>
    RetryInterceptor(
      maxRetries: maxRetries,
      baseDelay: const Duration(milliseconds: 1),
      retryMutations: retryMutations,
    );

const _unauthenticated = FakeReply({
  'data': null,
  'errors': [
    {
      'message': 'expired',
      'extensions': {'code': 'UNAUTHENTICATED'}
    },
  ],
});

void main() {
  group('AuthInterceptor', () {
    late String token;
    late int refreshes;
    late AuthInterceptor auth;

    setUp(() {
      token = 'old';
      refreshes = 0;
      auth = AuthInterceptor(
        token: () => token,
        refreshToken: () async {
          refreshes++;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return token = 'new';
        },
      );
    });

    bool hasNewToken(RequestOptions r) =>
        r.headers['Authorization'] == 'Bearer new';

    test('adds the bearer token', () async {
      final adapter = FakeHttpAdapter((_, __) => ok({'a': 1}));
      await http(adapter, [auth]).execute(req('{ a }'));
      expect(adapter.requests.single.headers['Authorization'], 'Bearer old');
    });

    test('refreshes and retries on HTTP 401', () async {
      final adapter = FakeHttpAdapter((r, _) => hasNewToken(r)
          ? ok({'a': 1})
          : const FakeReply({'message': 'no'}, status: 401));
      final response = await http(adapter, [auth]).execute(req('{ a }'));
      expect(response.data, {'a': 1});
      expect(adapter.requests, hasLength(2));
    });

    test('refreshes on UNAUTHENTICATED inside an HTTP 200', () async {
      final adapter = FakeHttpAdapter(
          (r, _) => hasNewToken(r) ? ok({'a': 1}) : _unauthenticated);
      final response = await http(adapter, [auth]).execute(req('{ a }'));
      expect(response.data, {'a': 1});
      expect(refreshes, 1);
    });

    test('concurrent failures share one refresh', () async {
      final adapter = FakeHttpAdapter((r, _) => hasNewToken(r)
          ? ok({'a': 1})
          : const FakeReply({'message': 'no'}, status: 401));
      final transport = http(adapter, [auth]);

      await Future.wait([
        transport.execute(req('query A { a }')),
        transport.execute(req('query B { a }')),
        transport.execute(req('query C { a }')),
      ]);

      expect(refreshes, 1);
    });

    test('retries at most once per request', () async {
      final adapter = FakeHttpAdapter(
          (_, __) => const FakeReply({'message': 'no'}, status: 401));
      await expectLater(
        http(adapter, [auth]).execute(req('{ a }')),
        throwsA(isA<GraphQLException>()
            .having((e) => e.kind, 'kind', GraphQLErrorKind.unauthenticated)),
      );
      expect(adapter.requests, hasLength(2));
    });

    test('the retry keeps the refreshed token even if the provider lags',
        () async {
      // The refresher returns the new token before the app stores it.
      final lagging = AuthInterceptor(
        token: () => 'old',
        refreshToken: () async => 'new',
      );
      final adapter = FakeHttpAdapter((r, _) => hasNewToken(r)
          ? ok({'a': 1})
          : const FakeReply({'message': 'no'}, status: 401));
      final response = await http(adapter, [lagging]).execute(req('{ a }'));
      expect(response.data, {'a': 1});
      expect(adapter.requests.last.headers['Authorization'], 'Bearer new');
    });

    test('never sends the token over http:// to a public host', () async {
      final adapter = FakeHttpAdapter((_, __) => ok({'a': 1}));
      await expectLater(
        HttpTransport('http://api.example.com/graphql',
            httpClientAdapter: adapter,
            interceptors: [auth]).execute(req('{ a }')),
        throwsA(isA<GraphQLException>()
            .having((e) => e.message, 'message', contains('unencrypted'))),
      );
      expect(adapter.requests, isEmpty);
    });

    test('allows http:// to local and private hosts', () async {
      for (final host in ['localhost:4000', '10.0.2.2', '192.168.1.20']) {
        final adapter = FakeHttpAdapter((_, __) => ok({'a': 1}));
        await HttpTransport('http://$host/graphql',
            httpClientAdapter: adapter,
            interceptors: [auth]).execute(req('{ a }'));
        expect(adapter.requests.single.headers['Authorization'], 'Bearer old',
            reason: host);
      }
    });

    test('reports a failed refresh', () async {
      Object? failure = 'not called';
      final failing = AuthInterceptor(
        token: () => 'old',
        refreshToken: () async => null,
        onRefreshFailed: (error) => failure = error,
      );
      final adapter = FakeHttpAdapter((_, __) => _unauthenticated);
      final response = await http(adapter, [failing]).execute(req('{ a }'));

      expect(response.errors.single.code, 'UNAUTHENTICATED');
      expect(failure, isNull);
      expect(adapter.requests, hasLength(1));
    });
  });

  group('RetryInterceptor', () {
    test('retries 5xx and succeeds', () async {
      final adapter = FakeHttpAdapter((_, i) => i == 0
          ? const FakeReply('down', status: 503, raw: true)
          : ok({'a': 1}));
      final response = await http(adapter, [fastRetry()]).execute(req('{ a }'));
      expect(response.data, {'a': 1});
      expect(adapter.requests, hasLength(2));
    });

    test('honours Retry-After on 429', () async {
      final adapter = FakeHttpAdapter((_, i) => i == 0
          ? const FakeReply('slow',
              status: 429, raw: true, headers: {'retry-after': '0'})
          : ok({'a': 1}));
      final response = await http(adapter, [fastRetry()]).execute(req('{ a }'));
      expect(response.data, {'a': 1});
    });

    test('sends at most 1 + maxRetries requests', () async {
      final adapter = FakeHttpAdapter(
          (_, __) => const FakeReply('down', status: 503, raw: true));
      await expectLater(
        http(adapter, [fastRetry(maxRetries: 3)]).execute(req('{ a }')),
        throwsA(isA<GraphQLException>()),
      );
      expect(adapter.requests, hasLength(4));
    });

    test('does not retry mutations unless allowed', () async {
      FakeHttpAdapter failing() => FakeHttpAdapter(
          (_, __) => const FakeReply('down', status: 503, raw: true));

      final strict = failing();
      await expectLater(
          http(strict, [fastRetry()]).execute(req('mutation M { m }')),
          throwsA(isA<GraphQLException>()));
      expect(strict.requests, hasLength(1));

      final lenient = failing();
      await expectLater(
          http(lenient, [fastRetry(retryMutations: true)])
              .execute(req('mutation M { m }')),
          throwsA(isA<GraphQLException>()));
      expect(lenient.requests, hasLength(3));
    });

    test('does not retry a 500 that carries GraphQL errors', () async {
      final adapter = FakeHttpAdapter((_, __) => const FakeReply({
            'errors': [
              {'message': 'resolver crashed'},
            ],
          }, status: 500));
      final response = await http(adapter, [fastRetry()]).execute(req('{ a }'));
      expect(response.statusCode, 500);
      expect(adapter.requests, hasLength(1));
    });

    test('does not retry file uploads', () async {
      final adapter = FakeHttpAdapter(
          (_, __) => const FakeReply('down', status: 503, raw: true));
      await expectLater(
        http(adapter, [fastRetry(retryMutations: true)]).execute(req(
          r'mutation U($f: Upload!) { upload(f: $f) }',
          variables: {'f': MultipartFile.fromString('x', filename: 'x')},
        )),
        throwsA(isA<GraphQLException>()),
      );
      expect(adapter.requests, hasLength(1));
    });
  });

  group('LoggingInterceptor', () {
    test('logs operation names and redacts credentials', () async {
      final logs = <String>[];
      final adapter = FakeHttpAdapter((_, __) => ok({'a': 1}));
      await HttpTransport(
        'https://api.test/graphql',
        headers: {'Authorization': 'Bearer secret', 'X-Trace': 'abc'},
        httpClientAdapter: adapter,
        interceptors: [LoggingInterceptor(logger: logs.add, logHeaders: true)],
      ).execute(req('query GetThing { a }'));

      final text = logs.join('\n');
      expect(text, contains('query GetThing'));
      expect(text, contains('abc'));
      expect(text, isNot(contains('secret')));
    });

    test('keeps GET variables out of logs unless bodies are enabled', () async {
      final logs = <String>[];
      final adapter = FakeHttpAdapter((_, __) => ok({'a': 1}));
      await HttpTransport(
        'https://api.test/graphql',
        httpClientAdapter: adapter,
        useGetForQueries: true,
        interceptors: [LoggingInterceptor(logger: logs.add)],
      ).execute(req(r'query Q($pw: String) { a(pw: $pw) }',
          variables: {'pw': 'hunter2'}));

      expect(logs.join('\n'), isNot(contains('hunter2')));
    });
  });
}
