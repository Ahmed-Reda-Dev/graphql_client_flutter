import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_client_flutter/graphql_client_flutter.dart';
import 'package:graphql_client_flutter/testing.dart';

const getUser = 'query GetUser { user { id name } }';

JsonMap user(String name) => {
      'user': {'__typename': 'User', 'id': '1', 'name': name},
    };

void main() {
  late MockTransport mock;
  late GraphQLClient client;

  setUp(() {
    mock = MockTransport()..on('GetUser').reply(user('Ada'));
    client = GraphQLClient.custom(transport: mock);
  });

  tearDown(() => client.dispose());

  /// Starts watching and waits for the first load.
  Future<StreamSubscription<void>> watch(
    FetchPolicy policy, {
    Duration? pollInterval,
    Duration? maxAge,
  }) async {
    final subscription = client
        .watchQuery<JsonMap>(getUser,
            fetchPolicy: policy, pollInterval: pollInterval, maxAge: maxAge)
        .stream
        .listen((_) {});
    await pumpEventQueue();
    return subscription;
  }

  group('app visibility', () {
    test('polling stops while hidden and resumes when visible', () async {
      await watch(FetchPolicy.networkOnly,
          pollInterval: const Duration(milliseconds: 20));
      await client.setAppVisible(false);
      final whileHidden = mock.requests.length;

      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(mock.requests, hasLength(whileHidden));

      await client.setAppVisible(true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(mock.requests.length, greaterThan(whileHidden + 1));
    });

    test('returning refreshes queries the way they started', () async {
      await watch(FetchPolicy.cacheAndNetwork); // Refreshes on start.
      await client.setAppVisible(false);
      await client.setAppVisible(true);

      expect(mock.requests, hasLength(2));
    });

    test('returning does not refetch fresh cache-first data', () async {
      await watch(FetchPolicy.cacheFirst, maxAge: const Duration(hours: 1));
      await client.setAppVisible(false);
      await client.setAppVisible(true);

      expect(mock.requests, hasLength(1));
    });

    test('queries nobody listens to are left alone', () async {
      final subscription = await watch(FetchPolicy.cacheAndNetwork);
      await subscription.cancel();
      await client.setAppVisible(false);
      await client.setAppVisible(true);

      expect(mock.requests, hasLength(1));
    });

    test('repeating the same state does nothing', () async {
      await watch(FetchPolicy.cacheAndNetwork);
      await client.setAppVisible(true);

      expect(client.isAppVisible, isTrue);
      expect(mock.requests, hasLength(1));
    });
  });

  group('connectivity', () {
    test('coming back online refreshes watched queries', () async {
      await watch(FetchPolicy.cacheAndNetwork);
      await client.setOnline(false);
      expect(client.isOnline, isFalse);
      await client.setOnline(true);

      expect(mock.requests, hasLength(2));
    });

    test('polling pauses while offline', () async {
      await watch(FetchPolicy.networkOnly,
          pollInterval: const Duration(milliseconds: 20));
      await client.setOnline(false);
      final whileOffline = mock.requests.length;

      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(mock.requests, hasLength(whileOffline));
    });

    test('nothing refreshes until the app is both visible and online',
        () async {
      await watch(FetchPolicy.cacheAndNetwork);
      await client.setAppVisible(false);
      await client.setOnline(false);
      await client.setOnline(true); // Still hidden.
      expect(mock.requests, hasLength(1));

      await client.setAppVisible(true);
      expect(mock.requests, hasLength(2));
    });
  });
}
