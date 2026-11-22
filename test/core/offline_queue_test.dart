import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_client_flutter/graphql_client_flutter.dart';
import 'package:graphql_client_flutter/testing.dart';

const getUser = 'query GetUser { user { id name } }';
const rename = r'''
  mutation Rename($name: String!) { renameUser(id: "1", name: $name) { id name } }
''';

JsonMap userJson(String name) =>
    {'__typename': 'User', 'id': '1', 'name': name};

void main() {
  late bool reachable;
  late MockTransport mock;
  late Store store;
  late GraphQLClient client;

  /// Replies to Rename with the new name, or fails like a dropped
  /// connection while [reachable] is false.
  void serveRename() => mock.on('Rename').respond((request) {
        if (!reachable) {
          throw const GraphQLException(GraphQLErrorKind.network, 'offline');
        }
        return GraphQLResponse(data: {
          'renameUser': userJson(request.variables['name'] as String),
        });
      });

  GraphQLClient newClient() => GraphQLClient.custom(
        transport: mock,
        cache: GraphQLCache(store: store),
      );

  setUp(() async {
    reachable = true;
    mock = MockTransport()..on('GetUser').reply({'user': userJson('Ada')});
    serveRename();
    store = InMemoryStore();
    client = newClient();
    await client.query<JsonMap>(getUser);
  });

  tearDown(() => client.dispose());

  Future<GraphQLResult<JsonMap>> renameTo(String name) => client.mutate(
        rename,
        variables: {'name': name},
        queueIfOffline: true,
        optimisticResponse: {'renameUser': userJson(name)},
      );

  String? cachedName() =>
      (client.cache.read(getUser)?['user'] as JsonMap?)?['name'] as String?;

  List<String?> sentNames() => mock.requests
      .where((r) => r.operationName == 'Rename')
      .map((r) => r.variables['name'] as String?)
      .toList();

  test('online, it is sent right away like any mutation', () async {
    final result = await renameTo('Grace');

    expect(result.isSuccess, isTrue);
    expect(client.offlineQueue.length, 0);
    expect(cachedName(), 'Grace');
  });

  test('offline, it waits with the optimistic data shown', () async {
    reachable = false;
    var completed = false;
    unawaited(renameTo('Grace').then((_) => completed = true));
    await pumpEventQueue();

    expect(completed, isFalse);
    expect(client.offlineQueue.length, 1);
    expect(cachedName(), 'Grace'); // Optimistic.
    expect(store.get(r'$offlineQueue'), isNotNull); // Survives restarts.
  });

  test('coming back online sends it and completes the call', () async {
    reachable = false;
    final pending = renameTo('Grace');
    await pumpEventQueue();

    reachable = true;
    await client.setOnline(false);
    await client.setOnline(true);
    final result = await pending;

    expect(result.isSuccess, isTrue);
    expect(client.offlineQueue.length, 0);
    expect(store.get(r'$offlineQueue'), isNull);
    expect(cachedName(), 'Grace');
  });

  test('queued mutations are sent in order, after earlier ones', () async {
    reachable = false;
    final first = renameTo('Grace');
    final second = renameTo('Alan');
    await pumpEventQueue();

    reachable = true;
    await client.offlineQueue.flush();
    await Future.wait([first, second]);

    expect(sentNames(), ['Grace', 'Grace', 'Alan']); // Failed try, then both.
    expect(cachedName(), 'Alan');
  });

  test('nothing is attempted while the client is offline', () async {
    await client.setOnline(false);
    unawaited(renameTo('Grace'));
    await pumpEventQueue();

    expect(sentNames(), isEmpty);
    expect(client.offlineQueue.length, 1);
  });

  test('any successful request triggers sending the queue', () async {
    reachable = false;
    final pending = renameTo('Grace');
    await pumpEventQueue();

    reachable = true;
    await client.query<JsonMap>(getUser, fetchPolicy: FetchPolicy.networkOnly);

    expect((await pending).isSuccess, isTrue);
  });

  for (final kind in [
    GraphQLErrorKind.server,
    GraphQLErrorKind.timeout,
    GraphQLErrorKind.unauthenticated,
  ]) {
    test('a ${kind.name} failure keeps the mutation queued', () async {
      var failing = true;
      mock.on('Rename').respond((_) {
        if (failing) throw GraphQLException(kind, 'try again later');
        return GraphQLResponse(data: {'renameUser': userJson('Grace')});
      });
      final pending = renameTo('Grace');
      await pumpEventQueue();
      expect(client.offlineQueue.length, 1);

      failing = false;
      await client.offlineQueue.flush();
      expect((await pending).isSuccess, isTrue);
    });
  }

  test('restored mutations are not sent while the client is created', () async {
    reachable = false;
    unawaited(renameTo('Grace'));
    await pumpEventQueue();
    await client.dispose();
    final sentBefore = sentNames().length;

    reachable = true;
    client = newClient();
    expect(sentNames(), hasLength(sentBefore)); // Deferred, not synchronous.
    await pumpEventQueue();
    expect(sentNames(), hasLength(sentBefore + 1));
  });

  test('a send that finishes after dispose leaves the queue saved', () async {
    final gate = Completer<void>();
    mock.on('Rename').respond((_) async {
      await gate.future;
      return GraphQLResponse(data: {'renameUser': userJson('Grace')});
    });
    unawaited(renameTo('Grace'));
    await pumpEventQueue();
    await client.dispose();

    gate.complete();
    await pumpEventQueue();
    expect(store.get(r'$offlineQueue'), isNotNull); // Resent next start.
  });

  test('a rejected mutation is dropped and later ones still go', () async {
    mock.on('Fail').respond((_) {
      if (!reachable) {
        throw const GraphQLException(GraphQLErrorKind.network, 'offline');
      }
      throw const GraphQLException(GraphQLErrorKind.forbidden, 'Not allowed');
    });
    reachable = false;
    final rejected = client.mutate<JsonMap>(
      'mutation Fail { fail }',
      queueIfOffline: true,
    );
    final accepted = renameTo('Grace');
    await pumpEventQueue();

    reachable = true;
    await client.offlineQueue.flush();

    final failure = await rejected;
    expect(failure.isSuccess, isFalse);
    expect(failure.exceptionOrNull?.kind, GraphQLErrorKind.forbidden);
    expect((await accepted).isSuccess, isTrue);
    expect(client.offlineQueue.length, 0);
  });

  test('pending mutations survive an app restart', () async {
    reachable = false;
    unawaited(renameTo('Grace'));
    await pumpEventQueue();
    await client.dispose();

    reachable = true;
    client = newClient();
    expect(client.offlineQueue.length, 1);
    await client.offlineQueue.flush();

    expect(client.offlineQueue.length, 0);
    expect(cachedName(), 'Grace'); // The server's answer was cached.
  });

  test('restored mutations show their optimistic data until sent', () async {
    reachable = false;
    unawaited(renameTo('Grace'));
    await pumpEventQueue();
    await client.dispose();

    client = newClient();
    await pumpEventQueue();

    expect(client.offlineQueue.length, 1);
    expect(cachedName(), 'Grace');
    final confirmed =
        client.cache.readQuery(_getUserRequest, optimistic: false);
    expect((confirmed?['user'] as JsonMap?)?['name'], 'Ada');
  });

  test('disposing keeps the mutation queued and ends the call', () async {
    reachable = false;
    final pending = renameTo('Grace');
    await pumpEventQueue();
    await client.dispose();

    final result = await pending;
    expect(result.exceptionOrNull?.kind, GraphQLErrorKind.cancelled);
    expect(store.get(r'$offlineQueue'), isNotNull);
  });

  test('resetStore discards pending mutations', () async {
    reachable = false;
    final pending = renameTo('Grace');
    await pumpEventQueue();

    await client.resetStore();

    expect((await pending).exceptionOrNull?.kind, GraphQLErrorKind.cancelled);
    expect(client.offlineQueue.length, 0);
    reachable = true;
    await client.offlineQueue.flush();
    expect(sentNames(), ['Grace']); // Only the first, failed try.
  });

  test('clear discards pending mutations and their optimistic data', () async {
    reachable = false;
    final pending = renameTo('Grace');
    await pumpEventQueue();

    await client.offlineQueue.clear();
    final result = await pending;
    await pumpEventQueue();

    expect(result.exceptionOrNull?.kind, GraphQLErrorKind.cancelled);
    expect(cachedName(), 'Ada');
  });

  test('variables that cannot be saved (file uploads) are rejected', () async {
    final result = await client.mutate<JsonMap>(
      r'mutation Upload($file: Upload!) { upload(file: $file) }',
      variables: {'file': MultipartFile.fromString('x', filename: 'x.txt')},
      queueIfOffline: true,
    );

    expect(result.exceptionOrNull?.kind, GraphQLErrorKind.invalidRequest);
    expect(client.offlineQueue.length, 0);
  });

  test('changes reports the queue length', () async {
    final lengths = <int>[];
    client.offlineQueue.changes.listen(lengths.add);
    reachable = false;
    final pending = renameTo('Grace');
    await pumpEventQueue();
    reachable = true;
    await client.offlineQueue.flush();
    await pending;
    await pumpEventQueue();

    expect(lengths, [1, 0]);
  });

  test('retries on its own after a delay', () async {
    await client.dispose();
    client = GraphQLClient.custom(
      transport: mock,
      cache: GraphQLCache(store: store),
      offlineRetryDelay: (_) => const Duration(milliseconds: 10),
    );
    reachable = false;
    final pending = renameTo('Grace');
    await pumpEventQueue();

    reachable = true;
    final result = await pending.timeout(const Duration(seconds: 1));
    expect(result.isSuccess, isTrue);
  });
}

final _getUserRequest =
    GraphQLRequest(document: GraphQLDocument.parse(getUser));
