import 'dart:collection';

import '../core/request/cancellation_token.dart';
import '../core/request/graphql_request.dart';
import '../core/response/graphql_exception.dart';
import '../core/response/graphql_response.dart';
import '../core/transport/graphql_transport.dart';
import 'cassette.dart';

/// A [GraphQLTransport] for tests that answers from a [Cassette] recorded
/// by `RecordingTransport`, with no server.
///
/// ```dart
/// final client = GraphQLClient.custom(
///   transport: ReplayTransport(await Cassette.load('test/fixtures/home.json')),
/// );
/// ```
///
/// Requests are matched by operation name and variables. When the same
/// request was recorded several times, the answers are replayed in order,
/// then the last one repeats. A request that was not recorded fails with a
/// [GraphQLException] listing what was.
final class ReplayTransport implements GraphQLTransport {
  /// Replays [cassette].
  ReplayTransport(this.cassette);

  /// The recording being played.
  final Cassette cassette;

  final _requests = <GraphQLRequest>[];
  final _played = Set<CassetteEntry>.identity();

  /// Every request received, in order.
  List<GraphQLRequest> get requests => UnmodifiableListView(_requests);

  @override
  Future<GraphQLResponse> execute(
    GraphQLRequest request, {
    CancellationToken? cancelToken,
  }) async {
    final entry = _next(request);
    if (entry.error case final error?) throw error;
    if (entry.response case final response?) return response;
    throw _mismatch(request, 'was recorded as a subscription');
  }

  @override
  Stream<GraphQLResponse> subscribe(GraphQLRequest request) async* {
    final entry = _next(request);
    if (entry.error case final error?) throw error;
    if (entry.events case final events?) {
      yield* Stream.fromIterable(events);
    } else if (entry.response case final response?) {
      yield response;
    }
  }

  @override
  Future<void> dispose() async {}

  CassetteEntry _next(GraphQLRequest request) {
    _requests.add(request);
    final candidates = cassette.entries.where((e) => e.matches(request));
    if (candidates.isEmpty) {
      throw _mismatch(request, 'has no recorded response');
    }
    final entry = candidates.firstWhere(
      (e) => !_played.contains(e),
      orElse: () => candidates.last,
    );
    _played.add(entry);
    return entry;
  }

  GraphQLException _mismatch(GraphQLRequest request, String problem) {
    final recorded = cassette.entries.map((e) => '$e').toSet().join(', ');
    return GraphQLException(
      GraphQLErrorKind.unknown,
      'No recorded response for ${request.operationName ?? 'an anonymous '
          'operation'} with variables ${request.variables}: it $problem. '
      'Recorded: ${recorded.isEmpty ? 'nothing' : recorded}. '
      'Record it again with RecordingTransport.',
      operationName: request.operationName,
    );
  }
}
