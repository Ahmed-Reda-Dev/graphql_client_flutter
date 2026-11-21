import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_client_flutter/graphql_client_flutter.dart';
import 'package:graphql_client_flutter/testing.dart';

void main() {
  late MockTransport mock;
  late GraphQLClient client;

  setUp(() {
    mock = MockTransport();
    client = GraphQLClient.custom(transport: mock);
  });

  Future<GraphQLResult<JsonMap>> ping({JsonMap variables = const {}}) =>
      client.query<JsonMap>(r'query Ping($n: Int) { ping(n: $n) }',
          variables: variables, fetchPolicy: FetchPolicy.noCache);

  test('queued replies are consumed in order; the last one repeats', () async {
    mock.on('Ping')
      ..reply({'ping': 1})
      ..reply({'ping': 2});

    final values = [
      for (var i = 0; i < 3; i++) (await ping()).dataOrThrow['ping'],
    ];
    expect(values, [1, 2, 2]);
  });

  test('variable-specific replies take precedence when registered later',
      () async {
    mock
      ..on('Ping').reply({'ping': 'any'})
      ..on('Ping', variables: {'n': 5}).reply({'ping': 'five'});

    expect((await ping(variables: {'n': 5})).dataOrThrow['ping'], 'five');
    expect((await ping(variables: {'n': 1})).dataOrThrow['ping'], 'any');
  });

  test('replyErrors and respond', () async {
    mock.on('Ping').replyErrors(['nope'], code: 'FORBIDDEN');
    expect((await ping()).exceptionOrNull?.kind, GraphQLErrorKind.forbidden);

    mock.on('Ping').respond(
        (request) => GraphQLResponse(data: {'ping': request.variables['n']}));
    expect((await ping(variables: {'n': 9})).dataOrThrow['ping'], 9);
  });

  test('unmatched operations fail with a helpful message', () async {
    mock.on('Other').reply({});
    final result = await ping();
    expect(result.exceptionOrNull?.message, contains('no reply for Ping'));
    expect(result.exceptionOrNull?.message, contains('on("Other")'));
  });

  test('records requests', () async {
    mock.on('Ping').reply({'ping': 1});
    await ping(variables: {'n': 3});
    expect(mock.requestsFor('Ping').single.variables, {'n': 3});
    expect(mock.on('Ping').callCount, 0);
  });
}
