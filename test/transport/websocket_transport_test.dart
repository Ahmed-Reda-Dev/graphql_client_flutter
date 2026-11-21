import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_client_flutter/graphql_client_flutter.dart';

import '../support/fake_ws_server.dart';

GraphQLRequest sub(String document) => GraphQLRequest(
      document: GraphQLDocument.parse(document, addTypename: false),
    );

void main() {
  late FakeWsServer server;
  late WebSocketTransport transport;

  WebSocketTransport create({
    SubscriptionProtocol protocol = SubscriptionProtocol.graphqlTransportWs,
    ConnectionParamsProvider? connectionParams,
    Duration idleTimeout = const Duration(seconds: 3),
  }) =>
      transport = WebSocketTransport(
        server.url,
        protocol: protocol,
        connectionParams: connectionParams,
        idleTimeout: idleTimeout,
        reconnectBaseDelay: const Duration(milliseconds: 20),
      );

  setUp(() async => server = await FakeWsServer.start());
  tearDown(() async {
    await transport.dispose();
    await server.close();
  });

  test('graphql-transport-ws: events, completion and sub-protocol', () async {
    server.events = [
      {'n': 1},
      {'n': 2},
    ];
    create();

    final events = await transport
        .subscribe(sub('subscription S { n }'))
        .map((r) => r.data?['n'])
        .toList();

    expect(events, [1, 2]);
    expect(server.requestedProtocols.single, ['graphql-transport-ws']);
  });

  test('legacy subscriptions-transport-ws', () async {
    server.events = [
      {'n': 7},
    ];
    create(protocol: SubscriptionProtocol.subscriptionsTransportWs);

    final events = await transport
        .subscribe(sub('subscription S { n }'))
        .map((r) => r.data?['n'])
        .toList();

    expect(events, [7]);
    expect(server.requestedProtocols.single, ['graphql-ws']);
    await server.waitFor('start');
  });

  test('cancelling sends complete for that operation', () async {
    server
      ..events = [
        {'n': 1},
      ]
      ..completeAfterEvents = false;
    create();

    await transport.subscribe(sub('subscription S { n }')).first;

    final complete = (await server.waitFor('complete')).single;
    final started = (await server.waitFor('subscribe')).single;
    expect(complete['id'], started['id']);
    expect(transport.activeOperations, 0);
  });

  test('server error messages become GraphQLException', () async {
    server.errorPayload = [
      {
        'message': 'Unknown field',
        'extensions': {'code': 'GRAPHQL_VALIDATION_FAILED'}
      },
    ];
    create();

    await expectLater(
      transport.subscribe(sub('subscription S { x }')),
      emitsError(isA<GraphQLException>()
          .having((e) => e.kind, 'kind', GraphQLErrorKind.invalidRequest)
          .having((e) => e.operationName, 'operation', 'S')),
    );
  });

  test('reconnects and restarts subscriptions after a drop', () async {
    server.completeAfterEvents = false;
    create();
    final events = <Object?>[];
    final subscription = transport
        .subscribe(sub('subscription S { n }'))
        .listen((r) => events.add(r.data?['n']));

    final first = (await server.waitFor('subscribe')).single;
    server.push(first['id'] as String, {'n': 1});
    await server.dropConnections();

    final restarted = (await server.waitFor('subscribe', count: 2)).last;
    server.push(restarted['id'] as String, {'n': 2});
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(server.connectionCount, 2);
    expect(events, [1, 2]);
    await subscription.cancel();
  });

  test('does not reconnect after a fatal close code', () async {
    server.rejectInitWithCode = 4401;
    create();

    await expectLater(
      transport.subscribe(sub('subscription S { n }')),
      emitsError(isA<GraphQLException>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(server.connectionCount, 1);
  });

  test('connectionParams are read for every connection', () async {
    server.completeAfterEvents = false;
    var token = 'first';
    create(connectionParams: () => {'token': token});
    final subscription =
        transport.subscribe(sub('subscription S { n }')).listen((_) {});

    await server.waitFor('subscribe');
    token = 'refreshed';
    await server.dropConnections();
    await server.waitFor('subscribe', count: 2);

    expect(server.initPayloads, [
      {'token': 'first'},
      {'token': 'refreshed'},
    ]);
    await subscription.cancel();
  });

  test('closes the socket when idle and reopens on demand', () async {
    server.events = [
      {'n': 1},
    ];
    create(idleTimeout: const Duration(milliseconds: 20));

    await transport.subscribe(sub('subscription S { n }')).toList();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(transport.isConnected, isFalse);

    await transport.subscribe(sub('subscription S { n }')).toList();
    expect(server.connectionCount, 2);
  });

  test('a server that acks then closes cannot cause endless retries', () async {
    server.completeAfterEvents = false;
    final sub0 = create().subscribe(sub('subscription S { n }'));
    final errors = <Object>[];
    final subscription = sub0.listen((_) {}, onError: errors.add);

    // Drop every connection as soon as its subscription starts.
    var dropped = 0;
    for (var tick = 0; tick < 400 && errors.isEmpty; tick++) {
      final started = server.received.where((m) => m['type'] == 'subscribe');
      if (started.length > dropped) {
        dropped = started.length;
        await server.dropConnections();
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(errors, hasLength(1));
    expect(server.connectionCount, lessThanOrEqualTo(6));
    await subscription.cancel();
  });

  test('a connection that stops answering pings is replaced', () async {
    server
      ..completeAfterEvents = false
      ..answerPings = false;
    transport = WebSocketTransport(
      server.url,
      keepAliveInterval: const Duration(milliseconds: 30),
      reconnectBaseDelay: const Duration(milliseconds: 10),
    );
    final subscription =
        transport.subscribe(sub('subscription S { n }')).listen((_) {});

    await server.waitFor('subscribe', count: 2);
    expect(server.connectionCount, greaterThanOrEqualTo(2));
    await subscription.cancel();
  });

  test('execute runs a query over the socket', () async {
    server.events = [
      {'answer': 42},
    ];
    create();
    final response = await transport.execute(sub('query Q { answer }'));
    expect(response.data, {'answer': 42});
  });
}
