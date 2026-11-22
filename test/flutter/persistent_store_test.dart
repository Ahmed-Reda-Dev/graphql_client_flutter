// Calls without a type argument mirror apps that do not use strict inference.
// ignore_for_file: inference_failure_on_function_invocation

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_client_flutter/graphql_client_flutter.dart';
import 'package:graphql_client_flutter/testing.dart';

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('gql_store'));
  tearDown(() => dir.delete(recursive: true));

  Future<PersistentStore> open() => PersistentStore.open(
        directoryPath: () async => dir.path,
        writeDelay: const Duration(milliseconds: 5),
      );

  test('cached query results survive a restart', () async {
    final mock = MockTransport()
      ..on('GetUser').reply({
        'user': {'__typename': 'User', 'id': '1', 'name': 'Ada'},
      });
    const getUser = 'query GetUser { user { id name } }';

    final first = GraphQLClient.custom(
      transport: mock,
      cache: GraphQLCache(store: await open()),
    );
    await first.query(getUser);
    await first.dispose();

    final offline = GraphQLClient.custom(
      transport: MockTransport(), // Any network use would throw.
      cache: GraphQLCache(store: await open()),
    );
    final result = await offline.query<JsonMap>(getUser,
        fetchPolicy: FetchPolicy.cacheOnly);

    expect((result.dataOrThrow['user'] as JsonMap)['name'], 'Ada');
    await offline.dispose();
  });

  test('writes are atomic and batched', () async {
    final store = await open();
    store
      ..put('A:1', {'v': 1})
      ..put('A:1', {'v': 2})
      ..put('B:1', {'v': 3})
      ..delete('B:1');
    await store.close();

    final reopened = await open();
    expect(reopened.get('A:1'), {'v': 2});
    expect(reopened.get('B:1'), isNull);
    expect(File('${dir.path}/graphql_cache.json.tmp').existsSync(), isFalse);
  });

  test('a large cache file loads (decoded in a background isolate)', () async {
    final store = await open();
    for (var i = 0; i < 2000; i++) {
      store.put('User:$i', {'__typename': 'User', 'id': '$i', 'name': 'U$i'});
    }
    await store.close();
    expect(File('${dir.path}/graphql_cache.json').lengthSync(),
        greaterThan(50 * 1024));

    final reopened = await open();
    expect(reopened.keys, hasLength(2000));
    expect(reopened.get('User:1999')?['name'], 'U1999');
  });

  test('a corrupt file starts an empty store', () async {
    await File('${dir.path}/graphql_cache.json').writeAsString('{not json');
    final store = await open();
    expect(store.keys, isEmpty);
  });

  test('an encryption codec is applied on disk', () async {
    final store = await PersistentStore.open(
      directoryPath: () async => dir.path,
      codec: const _Reverse(),
    );
    store.put('User:1', {'name': 'Ada'});
    await store.close();

    final raw = await File('${dir.path}/graphql_cache.json').readAsString();
    expect(raw, isNot(contains('Ada')));

    final reopened = await PersistentStore.open(
      directoryPath: () async => dir.path,
      codec: const _Reverse(),
    );
    expect(reopened.get('User:1'), {'name': 'Ada'});

    // A different key cannot read it and starts empty instead of crashing.
    final wrongKey = await open();
    expect(wrongKey.keys, isEmpty);
  });

  test('resetStore removes the previous user from disk', () async {
    final mock = MockTransport()
      ..on('Me').reply({
        'me': {'__typename': 'User', 'id': '1', 'name': 'Ada'},
      });
    final client = GraphQLClient.custom(
      transport: mock,
      cache: GraphQLCache(store: await open()),
    );
    await client.query('query Me { me { id name } }');
    await client.cache.flush();

    await client.resetStore();

    final raw = await File('${dir.path}/graphql_cache.json').readAsString();
    expect(raw, isNot(contains('Ada')));
  });

  test('a failed write does not stop later writes', () async {
    final errors = <Object>[];
    final store = await PersistentStore.open(
      directoryPath: () async => dir.path,
      writeDelay: const Duration(milliseconds: 5),
      onWriteError: (e, _) => errors.add(e),
    );
    // Make the next write fail by putting a directory where the temp file goes.
    final blocker = Directory('${dir.path}/graphql_cache.json.tmp')
      ..createSync();
    store.put('A:1', {'v': 1});
    await expectLater(store.flush(), throwsA(isA<FileSystemException>()));

    blocker.deleteSync();
    store.put('A:1', {'v': 2});
    await store.flush();
    await store.close();

    expect((await open()).get('A:1'), {'v': 2});
  });

  test('rejects names that could escape the directory', () {
    expect(
      () => PersistentStore.open(
          name: '../evil', directoryPath: () async => dir.path),
      throwsArgumentError,
    );
  });
}

/// A toy reversible codec standing in for real encryption.
class _Reverse extends Codec<String, String> {
  const _Reverse();

  @override
  Converter<String, String> get encoder => const _ReverseConverter();

  @override
  Converter<String, String> get decoder => const _ReverseConverter();
}

class _ReverseConverter extends Converter<String, String> {
  const _ReverseConverter();

  @override
  String convert(String input) =>
      String.fromCharCodes(input.codeUnits.reversed);
}
