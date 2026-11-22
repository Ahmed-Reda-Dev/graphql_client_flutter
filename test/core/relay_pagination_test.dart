import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_client_flutter/graphql_client_flutter.dart';
import 'package:graphql_client_flutter/testing.dart';

JsonMap page(
  List<String> ids, {
  required bool hasNextPage,
  String? endCursor,
  int totalCount = 4,
}) =>
    {
      'user': {
        '__typename': 'User',
        'id': '1',
        'posts': {
          '__typename': 'PostConnection',
          'totalCount': totalCount,
          'edges': [
            for (final id in ids)
              {
                '__typename': 'PostEdge',
                'cursor': 'c$id',
                'node': {'__typename': 'Post', 'id': id},
              },
          ],
          'pageInfo': {
            '__typename': 'PageInfo',
            'hasNextPage': hasNextPage,
            'endCursor': endCursor,
            'hasPreviousPage': false,
            'startCursor': ids.isEmpty ? null : 'c${ids.first}',
          },
        },
      },
    };

List<String> postIds(JsonMap? data) {
  final user = data?['user'] as JsonMap?;
  final posts = user?['posts'] as JsonMap?;
  return [
    for (final edge in (posts?['edges'] as List?) ?? const <Object?>[])
      ((edge as JsonMap)['node'] as JsonMap)['id'] as String,
  ];
}

void main() {
  const pagination = RelayPagination('user.posts');

  group('merge', () {
    test('appends edges and takes the new end of the page info', () {
      final merged = pagination.merge(
        page(['1', '2'], hasNextPage: true, endCursor: 'c2'),
        page(['3', '4'], hasNextPage: false, endCursor: 'c4'),
      );

      expect(postIds(merged), ['1', '2', '3', '4']);
      final posts = (merged['user'] as JsonMap)['posts'] as JsonMap;
      final pageInfo = posts['pageInfo'] as JsonMap;
      expect(pageInfo['hasNextPage'], isFalse);
      expect(pageInfo['endCursor'], 'c4');
      expect(pageInfo['startCursor'], 'c1'); // Still the first page's start.
    });

    test('keeps other fields from the newest page', () {
      final merged = pagination.merge(
        page(['1'], hasNextPage: true, endCursor: 'c1', totalCount: 3),
        page(['2'], hasNextPage: false, endCursor: 'c2', totalCount: 5),
      );
      final posts = (merged['user'] as JsonMap)['posts'] as JsonMap;
      expect(posts['totalCount'], 5);
    });

    test('appends `nodes` lists too', () {
      const nodes = RelayPagination('items');
      final merged = nodes.merge(
        {
          'items': {
            'nodes': [
              {'id': '1'},
            ],
          },
        },
        {
          'items': {
            'nodes': [
              {'id': '2'},
            ],
          },
        },
      );
      expect((merged['items'] as JsonMap)['nodes'], [
        {'id': '1'},
        {'id': '2'},
      ]);
    });

    test('does not modify its inputs', () {
      final previous = page(['1'], hasNextPage: true, endCursor: 'c1');
      pagination.merge(previous, page(['2'], hasNextPage: false));
      expect(postIds(previous), ['1']);
    });

    test('a missing connection is a clear error', () {
      expect(
        () => pagination.merge({'user': null}, page([], hasNextPage: false)),
        throwsA(isA<ArgumentError>()
            .having((e) => e.message, 'message', contains('user.posts'))),
      );
    });
  });

  test('reads whether there is a next page and its variables', () {
    final more = page(['1'], hasNextPage: true, endCursor: 'c1');
    final last = page(['2'], hasNextPage: false, endCursor: 'c2');

    expect(pagination.hasNextPage(more), isTrue);
    expect(pagination.nextPageVariables(more), {'after': 'c1'});
    expect(pagination.hasNextPage(last), isFalse);
    expect(pagination.nextPageVariables(last), isNull);
    expect(
      const RelayPagination('user.posts', cursorVariable: 'cursor')
          .nextPageVariables(more),
      {'cursor': 'c1'},
    );
  });

  test('works with fetchMore end to end', () async {
    const query = r'''
      query Posts($after: String) {
        user {
          id
          posts(first: 2, after: $after) {
            totalCount
            edges { cursor node { id } }
            pageInfo { hasNextPage endCursor hasPreviousPage startCursor }
          }
        }
      }
    ''';
    final mock = MockTransport()
      ..on('Posts', variables: {})
          .reply(page(['1', '2'], hasNextPage: true, endCursor: 'c2'))
      ..on('Posts', variables: {'after': 'c2'})
          .reply(page(['3', '4'], hasNextPage: false, endCursor: 'c4'));
    final client = GraphQLClient.custom(transport: mock);
    final watch = client.watchQuery<JsonMap>(query);
    final subscription = watch.stream.listen((_) {});
    await pumpEventQueue();

    final first = watch.latest!.dataOrThrow;
    final result = await watch.fetchMore(
      variables: pagination.nextPageVariables(first)!,
      merge: pagination.merge,
    );

    expect(postIds(result.dataOrThrow), ['1', '2', '3', '4']);
    expect(pagination.hasNextPage(result.dataOrThrow), isFalse);
    await subscription.cancel();
    await client.dispose();
  });
}
