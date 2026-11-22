import 'dart:async';

import '../core/json.dart';
import '../core/request/cancellation_token.dart';
import '../core/request/graphql_request.dart';
import '../core/response/graphql_exception.dart';
import '../core/response/graphql_response.dart';
import '../core/transport/graphql_transport.dart';
import 'cassette.dart';

/// Wraps a real transport and records every answer into [cassette], for
/// `ReplayTransport` to play back in tests without a server.
///
/// ```dart
/// final recorder = RecordingTransport(HttpTransport(url));
/// final client = GraphQLClient.custom(transport: recorder);
/// // ... run the flows to record ...
/// await recorder.cassette.save('test/fixtures/home.json');
/// ```
///
/// Responses, GraphQL errors, transport failures and subscription events
/// are recorded; request headers never are. Variables and responses are
/// saved as sent: record with test accounts (see [Cassette]). Requests
/// whose variables are not JSON (file uploads) are passed through but not
/// recorded.
final class RecordingTransport implements GraphQLTransport {
  /// Records what [inner] answers, adding to [cassette] if given.
  RecordingTransport(this.inner, {Cassette? cassette})
      : cassette = cassette ?? Cassette();

  /// The transport that talks to the server.
  final GraphQLTransport inner;

  /// The recording so far.
  final Cassette cassette;

  @override
  Future<GraphQLResponse> execute(
    GraphQLRequest request, {
    CancellationToken? cancelToken,
  }) async {
    try {
      final response = await inner.execute(request, cancelToken: cancelToken);
      _record(request, response: response);
      return response;
    } on GraphQLException catch (e) {
      // A cancellation is the caller's choice, not the server's answer.
      if (e.kind != GraphQLErrorKind.cancelled) _record(request, error: e);
      rethrow;
    }
  }

  /// Records the events received until the subscription ends, fails
  /// (the failure is recorded too) or is cancelled. A subscription
  /// cancelled before any event is not recorded.
  @override
  Stream<GraphQLResponse> subscribe(GraphQLRequest request) {
    final events = <GraphQLResponse>[];
    var recorded = false;
    void record([GraphQLException? error]) {
      if (recorded) return;
      recorded = true;
      _record(request, events: events, error: error);
    }

    StreamSubscription<GraphQLResponse>? subscription;
    late final StreamController<GraphQLResponse> controller;
    controller = StreamController<GraphQLResponse>(
      onListen: () => subscription = inner.subscribe(request).listen(
        (event) {
          events.add(event);
          controller.add(event);
        },
        onError: (Object error, StackTrace stackTrace) {
          if (error is GraphQLException) record(error);
          controller.addError(error, stackTrace);
        },
        onDone: () {
          record();
          unawaited(controller.close());
        },
      ),
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () {
        if (events.isNotEmpty) record();
        return subscription?.cancel();
      },
    );
    return controller.stream;
  }

  @override
  Future<void> dispose() => inner.dispose();

  void _record(
    GraphQLRequest request, {
    GraphQLResponse? response,
    List<GraphQLResponse>? events,
    GraphQLException? error,
  }) {
    if (!isJsonValue(request.variables)) return;
    cassette.add(CassetteEntry.of(
      request,
      response: response,
      events: events,
      error: error,
    ));
  }
}
