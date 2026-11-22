import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_client_flutter/graphql_client_flutter.dart';
import 'package:graphql_client_flutter/testing.dart';

/// Mutations whose variables hold a file must still write their result to
/// the cache, without reporting an error to the zone.
void main() {
  const upload = r'''
    mutation Upload($file: Upload!, $meta: ReceiptInput) {
      uploadReceipt(file: $file, meta: $meta) { __typename id url }
    }
  ''';
  const receiptFragment = 'fragment R on Receipt { id url }';
  const receiptId = {'__typename': 'Receipt', 'id': 'r1'};

  late MockTransport mock;
  late GraphQLClient client;

  setUp(() {
    mock = MockTransport()
      ..on('Upload').reply({
        'uploadReceipt': {
          '__typename': 'Receipt',
          'id': 'r1',
          'url': 'https://cdn.example/r1.jpg',
        },
      });
    client = GraphQLClient.custom(transport: mock);
  });

  tearDown(() => client.dispose());

  /// Runs [body] and returns the errors it reported to the zone.
  Future<List<Object>> zoneErrors(Future<void> Function() body) async {
    final errors = <Object>[];
    final done = Completer<void>();
    unawaited(
      runZonedGuarded(
        () => body().whenComplete(done.complete),
        (error, _) => errors.add(error),
      ),
    );
    await done.future;
    await pumpEventQueue();
    return errors;
  }

  test('normalizes the result of a file upload', () async {
    late GraphQLResult<JsonMap> result;
    final errors = await zoneErrors(() async {
      result = await client.mutate<JsonMap>(
        upload,
        variables: {
          'file': MultipartFile.fromString('jpeg', filename: 'r1.jpg'),
        },
      );
    });

    expect(errors, isEmpty);
    expect(result, isA<GraphQLSuccess<JsonMap>>());
    expect(
      client.cache.readFragment(receiptFragment, idFields: receiptId),
      {
        '__typename': 'Receipt',
        'id': 'r1',
        'url': 'https://cdn.example/r1.jpg',
      },
    );
    // The file itself reached the transport untouched.
    expect(
      mock.requestsFor('Upload').single.variables['file'],
      isA<MultipartFile>(),
    );
  });

  test('files nested in lists and input objects are handled too', () async {
    final errors = await zoneErrors(() async {
      final result = await client.mutate<JsonMap>(
        upload,
        variables: {
          'file': MultipartFile.fromString('jpeg', filename: 'r1.jpg'),
          'meta': {
            'note': 'lunch',
            'pages': [MultipartFile.fromString('p', filename: 'p1.jpg')],
          },
        },
      );
      expect(result.isSuccess, isTrue);
    });

    expect(errors, isEmpty);
    expect(
      client.cache.readFragment(receiptFragment, idFields: receiptId),
      isNotNull,
    );
  });

  test('optimistic responses and update callbacks work with files', () async {
    JsonMap? optimisticRead;
    final errors = await zoneErrors(() async {
      final pending = client.mutate<JsonMap>(
        upload,
        variables: {
          'file': MultipartFile.fromString('jpeg', filename: 'r1.jpg'),
        },
        optimisticResponse: {
          'uploadReceipt': {
            '__typename': 'Receipt',
            'id': 'r1',
            'url': 'pending',
          },
        },
      );
      optimisticRead =
          client.cache.readFragment(receiptFragment, idFields: receiptId);
      await pending;
    });

    expect(errors, isEmpty);
    expect(optimisticRead?['url'], 'pending');
    expect(
      client.cache.readFragment(receiptFragment, idFields: receiptId)?['url'],
      'https://cdn.example/r1.jpg',
    );
  });

  test('the cache reads and writes requests with file variables', () {
    final request = GraphQLRequest(
      document: GraphQLDocument.parse(upload),
      variables: {
        'file': MultipartFile.fromString('jpeg', filename: 'r1.jpg'),
      },
    );
    final data = {
      'uploadReceipt': {'__typename': 'Receipt', 'id': 'r1', 'url': 'u'},
    };

    client.cache.writeQuery(request, data);

    expect(client.cache.readQuery(request), data);
  });
}
