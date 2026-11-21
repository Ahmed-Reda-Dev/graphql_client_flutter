import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_client_flutter/graphql_client_flutter.dart';
import 'package:graphql_client_flutter/testing.dart';

const getUser = r'query GetUser($id: ID!) { user(id: $id) { id name } }';
const renameUser = r'''
  mutation Rename($id: ID!, $name: String!) {
    renameUser(id: $id, name: $name) { id name }
  }
''';

JsonMap userJson(String id, String name) => {
      'user': {'__typename': 'User', 'id': id, 'name': name},
    };

String parseName(JsonMap data) => (data['user'] as JsonMap)['name'] as String;

Widget app(GraphQLClient client, Widget child) => GraphQLProvider(
      client: client,
      child: MaterialApp(home: Scaffold(body: child)),
    );

Widget userName({String id = '1'}) => GraphQLQuery<String>(
      document: getUser,
      variables: {'id': id},
      parse: parseName,
      builder: (context, state, query) => switch (state) {
        QueryLoading() => const Text('loading'),
        QueryData(:final data) => Text('name: $data'),
        QueryError(:final exception) => TextButton(
            onPressed: query.refetch,
            child: Text('error: ${exception.kind.name}'),
          ),
      },
    );

void main() {
  late MockTransport mock;
  late GraphQLClient client;

  setUp(() {
    mock = MockTransport();
    client = GraphQLClient.custom(transport: mock);
  });

  group('GraphQLQuery', () {
    testWidgets('shows loading, then data', (tester) async {
      mock.on('GetUser').reply(userJson('1', 'Ada'));

      await tester.pumpWidget(app(client, userName()));
      expect(find.text('loading'), findsOneWidget);

      await tester.pump();
      expect(find.text('name: Ada'), findsOneWidget);
    });

    testWidgets('shows errors and recovers with refetch', (tester) async {
      mock.on('GetUser')
        ..fail(GraphQLErrorKind.network)
        ..reply(userJson('1', 'Ada'));

      await tester.pumpWidget(app(client, userName()));
      await tester.pump();
      expect(find.text('error: network'), findsOneWidget);

      await tester.tap(find.byType(TextButton));
      await tester.pump();
      expect(find.text('name: Ada'), findsOneWidget);
    });

    testWidgets('loads new data when variables change', (tester) async {
      mock
        ..on('GetUser', variables: {'id': '1'}).reply(userJson('1', 'Ada'))
        ..on('GetUser', variables: {'id': '2'}).reply(userJson('2', 'Alan'));

      await tester.pumpWidget(app(client, userName(id: '1')));
      await tester.pump();
      await tester.pumpWidget(app(client, userName(id: '2')));
      await tester.pump();

      expect(find.text('name: Alan'), findsOneWidget);
    });

    testWidgets('an inline parse closure does not refetch on rebuild',
        (tester) async {
      mock.on('GetUser').reply(userJson('1', 'Ada'));
      late StateSetter rebuild;

      await tester.pumpWidget(app(
        client,
        StatefulBuilder(builder: (context, setState) {
          rebuild = setState;
          return GraphQLQuery<String>(
            document: getUser,
            variables: const {'id': '1'},
            parse: (data) => parseName(data), // ignore: unnecessary_lambdas
            builder: (context, state, _) => Text('${state.data}'),
          );
        }),
      ));
      await tester.pump();
      rebuild(() {});
      await tester.pump();

      expect(mock.requests, hasLength(1));
      expect(find.text('Ada'), findsOneWidget);
    });

    testWidgets('updates when a mutation changes the same object',
        (tester) async {
      mock
        ..on('GetUser').reply(userJson('1', 'Ada'))
        ..on('Rename').reply({
          'renameUser': {'__typename': 'User', 'id': '1', 'name': 'Countess'},
        });

      await tester.pumpWidget(app(
        client,
        Column(children: [
          userName(),
          GraphQLMutation<JsonMap>(
            document: renameUser,
            builder: (context, state, run) => ElevatedButton(
              onPressed: () => run(variables: {'id': '1', 'name': 'Countess'}),
              child: const Text('rename'),
            ),
          ),
        ]),
      ));
      await tester.pump();
      expect(find.text('name: Ada'), findsOneWidget);

      await tester.tap(find.text('rename'));
      await tester.pump();
      await tester.pump();

      expect(find.text('name: Countess'), findsOneWidget);
      expect(mock.requestsFor('GetUser'), hasLength(1));
    });
  });

  group('GraphQLMutation', () {
    testWidgets('moves through idle, running and success', (tester) async {
      mock = MockTransport(latency: const Duration(milliseconds: 10));
      client = GraphQLClient.custom(transport: mock);
      mock.on('Rename').reply({
        'renameUser': {'__typename': 'User', 'id': '1', 'name': 'B'},
      });
      String? completed;

      await tester.pumpWidget(app(
        client,
        GraphQLMutation<String>(
          document: renameUser,
          parse: (data) => (data['renameUser'] as JsonMap)['name'] as String,
          onCompleted: (name) => completed = name,
          builder: (context, state, run) => TextButton(
            onPressed: () => run(variables: {'id': '1', 'name': 'B'}),
            child: Text(switch (state) {
              MutationIdle() => 'idle',
              MutationRunning() => 'running',
              MutationSuccess(:final data) => 'done $data',
              MutationFailure() => 'failed',
            }),
          ),
        ),
      ));
      expect(find.text('idle'), findsOneWidget);

      await tester.tap(find.byType(TextButton));
      await tester.pump();
      expect(find.text('running'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('done B'), findsOneWidget);
      expect(completed, 'B');
    });

    testWidgets('reports failures through onError', (tester) async {
      mock.on('Rename').fail(GraphQLErrorKind.forbidden);
      GraphQLException? error;

      await tester.pumpWidget(app(
        client,
        GraphQLMutation<JsonMap>(
          document: renameUser,
          onError: (e) => error = e,
          builder: (context, state, run) => TextButton(
            onPressed: () => run(variables: {'id': '1', 'name': 'B'}),
            child: Text(state is MutationFailure ? 'failed' : 'idle'),
          ),
        ),
      ));
      await tester.tap(find.byType(TextButton));
      await tester.pump();

      expect(find.text('failed'), findsOneWidget);
      expect(error?.kind, GraphQLErrorKind.forbidden);
    });
  });

  group('GraphQLSubscription', () {
    testWidgets('shows each event', (tester) async {
      mock.on('OnMessage').emit([
        {'message': 'hi'},
        {'message': 'there'},
      ]);
      final seen = <String>[];

      await tester.pumpWidget(app(
        client,
        GraphQLSubscription<String>(
          document: 'subscription OnMessage { message }',
          parse: (data) => data['message'] as String,
          onData: seen.add,
          builder: (context, state) => Text(switch (state) {
            QueryLoading() => 'waiting',
            QueryData(:final data) => data,
            QueryError() => 'error',
          }),
        ),
      ));
      expect(find.text('waiting'), findsOneWidget);

      await tester.pump();
      await tester.pump();
      expect(find.text('there'), findsOneWidget);
      expect(seen, ['hi', 'there']);
    });
  });

  testWidgets('an invalid document shows an error instead of throwing',
      (tester) async {
    await tester.pumpWidget(app(
      client,
      GraphQLQuery<JsonMap>(
        document: 'query { broken',
        builder: (context, state, _) => Text(switch (state) {
          QueryError(:final exception) => 'error ${exception.kind.name}',
          _ => 'other',
        }),
      ),
    ));
    expect(find.text('error invalidRequest'), findsOneWidget);
  });

  testWidgets('refetch with unchanged data clears isRefreshing',
      (tester) async {
    mock = MockTransport(latency: const Duration(milliseconds: 10));
    client = GraphQLClient.custom(transport: mock);
    mock.on('GetUser').reply(userJson('1', 'Ada'));
    late QueryController<String> controller;

    await tester.pumpWidget(app(
      client,
      GraphQLQuery<String>(
        document: getUser,
        variables: const {'id': '1'},
        parse: parseName,
        builder: (context, state, query) {
          controller = query;
          return Text(switch (state) {
            QueryData(:final isRefreshing) when isRefreshing => 'refreshing',
            QueryData(:final data) => data,
            _ => 'other',
          });
        },
      ),
    ));
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('Ada'), findsOneWidget);

    final refetch = controller.refetch();
    await tester.pump();
    expect(find.text('refreshing'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 20));
    await refetch;
    await tester.pump();
    expect(find.text('Ada'), findsOneWidget);
  });

  testWidgets('a missing provider explains the fix', (tester) async {
    await tester.pumpWidget(MaterialApp(home: userName()));
    final error = tester.takeException();
    expect(error, isA<FlutterError>());
    expect(error.toString(), contains('GraphQLProvider(client: client'));
  });
}
