import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_client_flutter/graphql_client_flutter.dart';
import 'package:graphql_client_flutter/testing.dart';

const getUser = r'query GetUser($id: ID!) { user(id: $id) { id name } }';
const onMessage = 'subscription OnMessage { message { id text } }';

JsonMap userJson(String id, String name) => {
      'user': {'__typename': 'User', 'id': id, 'name': name},
    };

String? nameOf(GraphQLResult<JsonMap> result) =>
    (result.dataOrNull?['user'] as JsonMap?)?['name'] as String?;

void main() {
  /// The "real server" being recorded.
  late MockTransport server;

  setUp(() {
    server = MockTransport()
      ..on('GetUser', variables: {'id': '1'}).reply(userJson('1', 'Ada'))
      ..on('GetUser', variables: {'id': '2'}).reply(userJson('2', 'Alan'));
  });

  /// Records what [run] does against [server], as a JSON round trip.
  Future<Cassette> record(
    Future<void> Function(GraphQLClient client) run,
  ) async {
    final recorder = RecordingTransport(server);
    final client = GraphQLClient.custom(transport: recorder);
    await run(client);
    await client.dispose();
    return Cassette.fromJson(
      jsonDecode(jsonEncode(recorder.cassette.toJson())) as JsonMap,
    );
  }

  GraphQLClient replaying(Cassette cassette) =>
      GraphQLClient.custom(transport: ReplayTransport(cassette));

  test('replays recorded responses without the server', () async {
    final cassette = await record((client) async {
      await client.query<JsonMap>(getUser, variables: {'id': '1'});
      await client.query<JsonMap>(getUser, variables: {'id': '2'});
    });
    server.reset(); // Any use of the server would now fail.

    final client = replaying(cassette);
    expect(nameOf(await client.query(getUser, variables: {'id': '2'})), 'Alan');
    expect(nameOf(await client.query(getUser, variables: {'id': '1'})), 'Ada');
  });

  test('passes responses through unchanged while recording', () async {
    final recorder = RecordingTransport(server);
    final client = GraphQLClient.custom(transport: recorder);

    final result = await client.query<JsonMap>(getUser, variables: {'id': '1'});

    expect(nameOf(result), 'Ada');
    expect(recorder.cassette.entries, hasLength(1));
    expect(recorder.cassette.entries.single.operationName, 'GetUser');
  });

  test('repeated requests replay in recorded order, then repeat the last',
      () async {
    server.on('GetUser', variables: {'id': '1'})
      ..reply(userJson('1', 'Ada'))
      ..reply(userJson('1', 'Ada Lovelace'));
    final cassette = await record((client) async {
      for (var i = 0; i < 2; i++) {
        await client.query<JsonMap>(getUser,
            variables: {'id': '1'}, fetchPolicy: FetchPolicy.networkOnly);
      }
    });

    final client = replaying(cassette);
    Future<String?> fetch() async => nameOf(await client.query(getUser,
        variables: {'id': '1'}, fetchPolicy: FetchPolicy.networkOnly));
    expect(await fetch(), 'Ada');
    expect(await fetch(), 'Ada Lovelace');
    expect(await fetch(), 'Ada Lovelace');
  });

  test('replays GraphQL errors and transport failures', () async {
    server
      ..on('GetUser', variables: {'id': '3'})
          .replyErrors(['Not found'], code: 'NOT_FOUND')
      ..on('GetUser', variables: {'id': '4'})
          .fail(GraphQLErrorKind.network, 'Connection refused');
    final cassette = await record((client) async {
      await client.query<JsonMap>(getUser, variables: {'id': '3'});
      await client.query<JsonMap>(getUser, variables: {'id': '4'});
    });

    final client = replaying(cassette);
    final notFound =
        await client.query<JsonMap>(getUser, variables: {'id': '3'});
    expect(notFound.exceptionOrNull?.errors.single.message, 'Not found');
    final offline =
        await client.query<JsonMap>(getUser, variables: {'id': '4'});
    expect(offline.exceptionOrNull?.kind, GraphQLErrorKind.network);
    expect(offline.exceptionOrNull?.message, 'Connection refused');
  });

  test('replays subscription events', () async {
    server.on('OnMessage').emit([
      {
        'message': {'__typename': 'Message', 'id': '1', 'text': 'hi'},
      },
      {
        'message': {'__typename': 'Message', 'id': '2', 'text': 'bye'},
      },
    ]);
    final cassette = await record((client) async {
      await client.subscribe<JsonMap>(onMessage).toList();
    });

    final texts = await replaying(cassette)
        .subscribe<JsonMap>(onMessage)
        .map((r) => (r.dataOrThrow['message'] as JsonMap)['text'])
        .toList();
    expect(texts, ['hi', 'bye']);
  });

  test('an unrecorded request fails with a clear explanation', () async {
    final cassette = await record((client) async {
      await client.query<JsonMap>(getUser, variables: {'id': '1'});
    });

    final result = await replaying(cassette)
        .query<JsonMap>(getUser, variables: {'id': '9'});

    expect(result.exceptionOrNull?.message, contains('No recorded response'));
    expect(result.exceptionOrNull?.message, contains('{id: 9}'));
  });

  test('records the requests it replays, for assertions', () async {
    final cassette = await record((client) async {
      await client.query<JsonMap>(getUser, variables: {'id': '1'});
    });
    final replay = ReplayTransport(cassette);
    final client = GraphQLClient.custom(transport: replay);

    await client.query<JsonMap>(getUser, variables: {'id': '1'});

    expect(replay.requests.single.variables, {'id': '1'});
  });

  test('headers are never recorded', () async {
    final recorder = RecordingTransport(server);
    final client = GraphQLClient.custom(transport: recorder);
    await client.query<JsonMap>(getUser,
        variables: {'id': '1'}, headers: {'Authorization': 'Bearer secret'});

    expect(jsonEncode(recorder.cassette.toJson()), isNot(contains('secret')));
  });

  test('saves to and loads from a file', () async {
    final directory = await Directory.systemTemp.createTemp('cassette');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/fixtures/users.json';
    final recorder = RecordingTransport(server);
    final client = GraphQLClient.custom(transport: recorder);
    await client.query<JsonMap>(getUser, variables: {'id': '1'});

    await recorder.cassette.save(path); // Creates missing folders.
    final loaded = await Cassette.load(path);

    expect(File(path).readAsStringSync(), contains('\n  ')); // Readable diff.
    final replayed =
        await replaying(loaded).query<JsonMap>(getUser, variables: {'id': '1'});
    expect(nameOf(replayed), 'Ada');
  });

  test('a file with an unknown format is rejected', () {
    expect(
      () => Cassette.fromJson({'version': 99, 'entries': <Object?>[]}),
      throwsFormatException,
    );
  });
}
