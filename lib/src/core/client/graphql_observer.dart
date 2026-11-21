import 'dart:async';

import '../request/graphql_request.dart';
import '../response/graphql_exception.dart';
import '../response/graphql_response.dart';

/// Receives events for every operation, for logging, analytics or tracing.
///
/// Override only the callbacks you need. Exceptions thrown by an observer
/// are reported to the current [Zone] and never affect the operation.
abstract class GraphQLObserver {
  /// Creates an observer.
  const GraphQLObserver();

  /// A network request is about to be sent.
  void onRequest(GraphQLRequest request) {}

  /// A network response arrived after [elapsed].
  void onResponse(
    GraphQLRequest request,
    GraphQLResponse response,
    Duration elapsed,
  ) {}

  /// A network request failed after [elapsed].
  void onError(
    GraphQLRequest request,
    GraphQLException exception,
    Duration elapsed,
  ) {}

  /// A query was answered from the cache without a network request.
  void onCacheHit(GraphQLRequest request) {}
}

/// Calls every observer, isolating their failures.
extension ObserverNotifier on List<GraphQLObserver> {
  /// Invokes [event] on each observer.
  void notify(void Function(GraphQLObserver observer) event) {
    for (final observer in this) {
      try {
        event(observer);
      } catch (e, stackTrace) {
        Zone.current.handleUncaughtError(e, stackTrace);
      }
    }
  }
}
