// Calls without a type argument mirror apps that do not use strict inference.
// ignore_for_file: inference_failure_on_function_invocation

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_client_flutter/graphql_client_flutter.dart';
import 'package:graphql_client_flutter/testing.dart';

const getUser = r'''
  query GetUser($id: ID!) { user(id: $id) { id name } }
''';

JsonMap user(String id, String name) => {
      'user': {'__typename': 'User', 'id': id, 'name': name},
    };

class User {
  const User(this.id, this.name);
  factory User.fromJson(JsonMap json) =>
      User(json['id'] as String, json['name'] as String);
  final String id;
  final String name;
}

void main() {
  late MockTransport mock;
  late GraphQLClient client;

  setUp(() {
    mock = MockTransport();
    client = GraphQLClient.custom(transport: mock);
  });

  group('query', () {
    test('returns typed data through parse', () async {
      mock.on('GetUser', variables: {'id': '1'}).reply(user('1', 'Ada'));

      final result = await client.query(
        getUser,
        variables: {'id': '1'},
        parse: (data) => User.fromJson(data['user'] as JsonMap),
      );

      expect(result.dataOrThrow.name, 'Ada');
    });

    test('returns the raw map without parse', () async {
      mock.on('GetUser').reply(user('1', 'Ada'));
      final result =
          await client.query<JsonMap>(getUser, variables: {'id': '1'});
      expect((result.dataOrThrow['user'] as JsonMap)['name'], 'Ada');
    });

    test('explains how to fix a missing parse', () async {
      mock.on('GetUser').reply(user('1', 'Ada'));
      final result = await client.query<User>(getUser, variables: {'id': '1'});
      expect(result.exceptionOrNull?.kind, GraphQLErrorKind.invalidResponse);
      expect(result.exceptionOrNull?.message, contains('parse:'));
    });

    test('turns a throwing parse into a failure', () async {
      mock.on('GetUser').reply({'user': null});
      final result = await client.query(
        getUser,
        variables: {'id': '1'},
        parse: (data) => User.fromJson(data['user'] as JsonMap),
      );
      expect(result.exceptionOrNull?.kind, GraphQLErrorKind.invalidResponse);
    });

    test('returns failures instead of throwing', () async {
      mock.on('GetUser').fail(GraphQLErrorKind.network);
      final result = await client.query(getUser, variables: {'id': '1'});
      expect(result.exceptionOrNull?.kind, GraphQLErrorKind.network);
      expect(result.exceptionOrNull?.operationName, 'GetUser');
    });

    test('rejects invalid documents without a request', () async {
      final result = await client.query('query { broken');
      expect(result.exceptionOrNull?.kind, GraphQLErrorKind.invalidRequest);
      expect(mock.requests, isEmpty);
    });

    test('rejects a mutation passed to query()', () async {
      final result = await client.query('mutation M { m }');
      expect(result.exceptionOrNull?.message, contains('client.mutate()'));
    });

    test('identical concurrent queries share one request', () async {
      mock = MockTransport(latency: const Duration(milliseconds: 20));
      client = GraphQLClient.custom(transport: mock);
      mock.on('GetUser').reply(user('1', 'Ada'));

      final results = await Future.wait([
        client.query(getUser,
            variables: {'id': '1'}, fetchPolicy: FetchPolicy.networkOnly),
        client.query(getUser,
            variables: {'id': '1'}, fetchPolicy: FetchPolicy.networkOnly),
      ]);

      expect(results.every((r) => r.isSuccess), isTrue);
      expect(mock.requests, hasLength(1));
    });

    test('a cancelled request fails with cancelled', () async {
      mock = MockTransport(latency: const Duration(milliseconds: 20));
      client = GraphQLClient.custom(transport: mock);
      mock.on('GetUser').reply(user('1', 'Ada'));
      final token = CancellationToken();

      final future =
          client.query(getUser, variables: {'id': '1'}, cancelToken: token);
      token.cancel();

      expect((await future).exceptionOrNull?.kind, GraphQLErrorKind.cancelled);
    });
  });

  group('fetch policies', () {
    setUp(() => mock.on('GetUser').reply(user('1', 'Ada')));

    Future<GraphQLResult<JsonMap>> run(FetchPolicy policy) => client
        .query<JsonMap>(getUser, variables: {'id': '1'}, fetchPolicy: policy);

    test('cacheFirst uses the cache after the first fetch', () async {
      await run(FetchPolicy.cacheFirst);
      final second = await run(FetchPolicy.cacheFirst);
      expect(mock.requests, hasLength(1));
      expect((second as GraphQLSuccess).source, ResultSource.cache);
    });

    test('networkOnly always fetches but fills the cache', () async {
      await run(FetchPolicy.networkOnly);
      await run(FetchPolicy.networkOnly);
      expect(mock.requests, hasLength(2));
      expect((await run(FetchPolicy.cacheOnly)).isSuccess, isTrue);
    });

    test('noCache never touches the cache', () async {
      await run(FetchPolicy.noCache);
      final cached = await run(FetchPolicy.cacheOnly);
      expect(cached.exceptionOrNull?.kind, GraphQLErrorKind.cacheMiss);
    });

    test('cacheAndNetwork returns cache now and refreshes', () async {
      await run(FetchPolicy.networkOnly);
      final result = await run(FetchPolicy.cacheAndNetwork);
      expect((result as GraphQLSuccess).source, ResultSource.cache);
      await pumpEventQueue();
      expect(mock.requests, hasLength(2));
    });
  });

  group('error policies', () {
    setUp(() {
      mock.on('GetUser').reply(
        user('1', 'Ada'),
        errors: [const GraphQLError(message: 'avatar failed')],
      );
    });

    Future<GraphQLResult<JsonMap>> run(ErrorPolicy policy) =>
        client.query<JsonMap>(getUser,
            variables: {'id': '1'},
            errorPolicy: policy,
            fetchPolicy: FetchPolicy.noCache);

    test('none fails on any error', () async {
      final result = await run(ErrorPolicy.none);
      expect(result.exceptionOrNull?.kind, GraphQLErrorKind.graphql);
      expect(result.exceptionOrNull?.errors.single.message, 'avatar failed');
    });

    test('all returns data with errors', () async {
      final result = await run(ErrorPolicy.all) as GraphQLSuccess<JsonMap>;
      expect(result.hasErrors, isTrue);
      expect(result.data, isNotEmpty);
    });

    test('ignore drops the errors', () async {
      final result = await run(ErrorPolicy.ignore) as GraphQLSuccess<JsonMap>;
      expect(result.hasErrors, isFalse);
    });

    test('partial data is not cached under none', () async {
      await run(ErrorPolicy.none);
      final cached = await client.query(getUser,
          variables: {'id': '1'}, fetchPolicy: FetchPolicy.cacheOnly);
      expect(cached.exceptionOrNull?.kind, GraphQLErrorKind.cacheMiss);
    });
  });

  group('observers', () {
    test('see requests, responses, errors and cache hits', () async {
      final events = <String>[];
      final observer = _RecordingObserver(events);
      client = GraphQLClient.custom(transport: mock, observers: [observer]);
      mock
        ..on('GetUser', variables: {'id': '1'}).reply(user('1', 'Ada'))
        ..on('GetUser', variables: {'id': '2'}).fail(GraphQLErrorKind.timeout);

      await client.query(getUser, variables: {'id': '1'});
      await client.query(getUser, variables: {'id': '1'});
      await client.query(getUser, variables: {'id': '2'});

      expect(events, [
        'request GetUser',
        'response GetUser',
        'cache GetUser',
        'request GetUser',
        'error timeout',
      ]);
    });

    test('a throwing observer does not break the operation', () async {
      client = GraphQLClient.custom(
          transport: mock, observers: [_ThrowingObserver()]);
      mock.on('GetUser').reply(user('1', 'Ada'));

      final errors = <Object>[];
      final result = await runZonedGuarded(
        () => client.query(getUser, variables: {'id': '1'}),
        (error, _) => errors.add(error),
      );

      expect(result?.isSuccess, isTrue);
      expect(errors, isNotEmpty);
    });
  });

  group('subscribe', () {
    test('emits typed results and writes them to the cache', () async {
      mock.on('OnUser').emit([
        user('1', 'Ada'),
        user('1', 'Ada Lovelace'),
      ]);

      final names = await client
          .subscribe('subscription OnUser { user { id name } }',
              parse: (data) => (data['user'] as JsonMap)['name'])
          .map((r) => r.dataOrThrow)
          .toList();

      expect(names, ['Ada', 'Ada Lovelace']);
      final cached = client.cache.readFragment('fragment U on User { name }',
          idFields: {'__typename': 'User', 'id': '1'});
      expect(cached?['name'], 'Ada Lovelace');
    });

    test('transport errors become failure events', () async {
      mock.on('OnUser').fail(GraphQLErrorKind.network);
      final results = await client
          .subscribe('subscription OnUser { user { id } }')
          .toList();
      expect(results.single.exceptionOrNull?.kind, GraphQLErrorKind.network);
    });
  });

  test('dispose makes later calls fail clearly', () async {
    await client.dispose();
    final result = await client.query(getUser);
    expect(result.exceptionOrNull?.message, contains('disposed'));
  });
}

class _RecordingObserver extends GraphQLObserver {
  _RecordingObserver(this.events);
  final List<String> events;

  @override
  void onRequest(GraphQLRequest request) =>
      events.add('request ${request.operationName}');

  @override
  void onResponse(GraphQLRequest r, GraphQLResponse response, Duration e) =>
      events.add('response ${r.operationName}');

  @override
  void onError(GraphQLRequest r, GraphQLException exception, Duration e) =>
      events.add('error ${exception.kind.name}');

  @override
  void onCacheHit(GraphQLRequest request) =>
      events.add('cache ${request.operationName}');
}

class _ThrowingObserver extends GraphQLObserver {
  @override
  void onRequest(GraphQLRequest request) => throw StateError('observer bug');
}
