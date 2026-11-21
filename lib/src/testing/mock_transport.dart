import 'dart:async';
import 'dart:collection';

import 'package:collection/collection.dart';

import '../core/json.dart';
import '../core/request/cancellation_token.dart';
import '../core/request/graphql_request.dart';
import '../core/response/graphql_error.dart';
import '../core/response/graphql_exception.dart';
import '../core/response/graphql_response.dart';
import '../core/transport/graphql_transport.dart';

/// Produces a response for a matched request.
typedef MockHandler = FutureOr<GraphQLResponse> Function(
    GraphQLRequest request);

/// A [GraphQLTransport] for tests: answers operations from canned replies
/// and records every request.
///
/// ```dart
/// final mock = MockTransport()
///   ..on('GetUser', variables: {'id': '1'})
///       .reply({'user': {'__typename': 'User', 'id': '1', 'name': 'Ada'}})
///   ..on('CreatePost').fail(GraphQLErrorKind.network);
///
/// final client = GraphQLClient.custom(transport: mock);
/// ```
final class MockTransport implements GraphQLTransport {
  /// Creates a mock. [latency] delays every reply.
  MockTransport({this.latency = Duration.zero});

  /// Delay applied to every reply.
  final Duration latency;

  final List<MockResponder> _responders = [];
  final List<GraphQLRequest> _requests = [];

  /// Every request received, in order.
  List<GraphQLRequest> get requests => UnmodifiableListView(_requests);

  /// Requests received for [operationName].
  List<GraphQLRequest> requestsFor(String operationName) =>
      _requests.where((r) => r.operationName == operationName).toList();

  /// Registers a reply for [operationName].
  ///
  /// With [variables], only requests with exactly these variables match.
  /// Later registrations take precedence over earlier ones.
  MockResponder on(String operationName, {JsonMap? variables}) {
    final responder = MockResponder._(operationName, variables);
    _responders.add(responder);
    return responder;
  }

  /// Removes all replies and recorded requests.
  void reset() {
    _responders.clear();
    _requests.clear();
  }

  @override
  Future<GraphQLResponse> execute(
    GraphQLRequest request, {
    CancellationToken? cancelToken,
  }) async {
    _requests.add(request);
    final responder = _match(request);
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    if (cancelToken?.isCancelled ?? false) {
      throw GraphQLException(
        GraphQLErrorKind.cancelled,
        'The request was cancelled',
        operationName: request.operationName,
      );
    }
    return responder._next(request);
  }

  @override
  Stream<GraphQLResponse> subscribe(GraphQLRequest request) async* {
    _requests.add(request);
    final responder = _match(request);
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    yield* responder._stream(request);
  }

  @override
  Future<void> dispose() async {}

  MockResponder _match(GraphQLRequest request) {
    final responder = _responders.reversed.firstWhereOrNull(
      (r) => r._matches(request),
    );
    if (responder != null) return responder;
    final registered = _responders.map((r) => r.toString()).join(', ');
    throw GraphQLException(
      GraphQLErrorKind.unknown,
      'MockTransport has no reply for ${request.operationName ?? 'an '
          'anonymous operation'} with variables ${request.variables}. '
      'Registered: ${registered.isEmpty ? 'none' : registered}. '
      'Name your operations and add mock.on(...) for each.',
      operationName: request.operationName,
    );
  }
}

/// The replies for one mocked operation.
///
/// Calling a reply method several times queues the replies; once the queue
/// has one reply left, that reply is repeated.
final class MockResponder {
  MockResponder._(this.operationName, this.variables);

  /// The operation this responder answers.
  final String operationName;

  /// The variables it requires, or null for any.
  final JsonMap? variables;

  final Queue<MockHandler> _replies = Queue();
  List<JsonMap>? _events;
  Duration _eventInterval = Duration.zero;
  int _callCount = 0;

  static const _equality = DeepCollectionEquality();

  /// How many requests this responder has answered.
  int get callCount => _callCount;

  /// Replies with [data] (and optional partial [errors]).
  void reply(JsonMap data, {List<GraphQLError> errors = const []}) =>
      respond((_) => GraphQLResponse(data: data, errors: errors));

  /// Replies with GraphQL errors and no data.
  void replyErrors(List<String> messages, {String? code}) => respond(
        (_) => GraphQLResponse(errors: [
          for (final message in messages)
            GraphQLError(
              message: message,
              extensions: code == null ? const {} : {'code': code},
            ),
        ]),
      );

  /// Fails at the transport level, as a network outage or timeout would.
  void fail(GraphQLErrorKind kind, [String? message]) => respond(
        (request) => throw GraphQLException(
          kind,
          message ?? 'Mocked ${kind.name} failure',
          operationName: request.operationName,
        ),
      );

  /// Replies using [handler], e.g. to echo variables back.
  void respond(MockHandler handler) => _replies.add(handler);

  /// For subscriptions: emits each of [events] as a result, then completes.
  void emit(List<JsonMap> events, {Duration interval = Duration.zero}) {
    _events = events;
    _eventInterval = interval;
  }

  bool _matches(GraphQLRequest request) =>
      request.operationName == operationName &&
      (variables == null || _equality.equals(variables, request.variables));

  Future<GraphQLResponse> _next(GraphQLRequest request) async {
    _callCount++;
    if (_replies.isEmpty) {
      throw StateError('No reply configured for $this; call reply(), '
          'replyErrors(), fail() or respond().');
    }
    final handler =
        _replies.length > 1 ? _replies.removeFirst() : _replies.first;
    return handler(request);
  }

  Stream<GraphQLResponse> _stream(GraphQLRequest request) async* {
    _callCount++;
    final events = _events;
    if (events == null) {
      // No events configured: fall back to the regular replies.
      yield await _next(request);
      return;
    }
    for (final event in events) {
      if (_eventInterval > Duration.zero) {
        await Future<void>.delayed(_eventInterval);
      }
      yield GraphQLResponse(data: event);
    }
  }

  @override
  String toString() => variables == null
      ? 'on("$operationName")'
      : 'on("$operationName", variables: $variables)';
}
