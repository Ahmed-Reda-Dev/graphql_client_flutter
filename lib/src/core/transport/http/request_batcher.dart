import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';

import '../../request/cancellation_token.dart';
import '../../request/graphql_request.dart';
import '../../response/graphql_exception.dart';
import '../../response/graphql_response.dart';

/// Configures automatic query batching: queries started within [window] of
/// each other are sent together as one HTTP request (a JSON array).
///
/// The server must accept batched requests (Apollo Server with
/// `allowBatchedHttpRequests`, Hasura, graphql-java and others). If it does
/// not, the transport notices and sends requests individually instead.
@immutable
final class BatchOptions {
  /// Creates batching options.
  const BatchOptions({
    this.window = const Duration(milliseconds: 10),
    this.maxBatchSize = 10,
  }) : assert(maxBatchSize > 1, 'maxBatchSize must be at least 2');

  /// How long to wait for more queries before sending a batch.
  final Duration window;

  /// Batches are sent as soon as they reach this many operations.
  final int maxBatchSize;
}

/// Sends several requests in one round trip; returns one response per
/// request, in order.
typedef BatchSender = Future<List<GraphQLResponse>> Function(
  List<GraphQLRequest> requests,
);

/// Collects requests into batches. Requests with different headers are
/// never batched together.
final class RequestBatcher {
  /// Creates a batcher that sends through [send].
  RequestBatcher(this.options, this._send);

  /// When and how much to batch.
  final BatchOptions options;

  final BatchSender _send;
  final Map<String, _Batch> _open = {};

  /// Queues [request] and completes with its response.
  Future<GraphQLResponse> add(
    GraphQLRequest request,
    CancellationToken? cancelToken,
  ) {
    final key = jsonEncode(Map.fromEntries(
      request.headers.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    ));
    final batch = _open[key] ??= _Batch();
    final pending = _Pending(request);
    batch.items.add(pending);

    unawaited(cancelToken?.whenCancelled.then((_) {
      // Only requests still waiting can be withdrawn.
      if (batch.items.remove(pending)) {
        pending.completer.completeError(GraphQLException(
          GraphQLErrorKind.cancelled,
          'The request was cancelled',
          operationName: request.operationName,
        ));
      }
    }));

    if (batch.items.length >= options.maxBatchSize) {
      _flush(key);
    } else {
      batch.timer ??= Timer(options.window, () => _flush(key));
    }
    return pending.completer.future;
  }

  /// Fails every queued request; used when the transport is disposed.
  void dispose() {
    for (final batch in _open.values) {
      batch.timer?.cancel();
      for (final pending in batch.items) {
        pending.completer.completeError(const GraphQLException(
          GraphQLErrorKind.cancelled,
          'The transport was disposed',
        ));
      }
    }
    _open.clear();
  }

  void _flush(String key) {
    final batch = _open.remove(key);
    if (batch == null) return;
    batch.timer?.cancel();
    final items = List.of(batch.items);
    batch.items.clear(); // Late cancellations no longer apply.
    if (items.isEmpty) return;

    _send([for (final pending in items) pending.request]).then(
      (responses) {
        for (var i = 0; i < items.length; i++) {
          items[i].completer.complete(responses[i]);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        for (final pending in items) {
          pending.completer.completeError(error, stackTrace);
        }
      },
    );
  }
}

final class _Batch {
  final List<_Pending> items = [];
  Timer? timer;
}

final class _Pending {
  _Pending(this.request);

  final GraphQLRequest request;
  final Completer<GraphQLResponse> completer = Completer();
}
