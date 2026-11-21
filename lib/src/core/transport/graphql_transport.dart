import '../request/cancellation_token.dart';
import '../request/graphql_document.dart';
import '../request/graphql_request.dart';
import '../response/graphql_exception.dart';
import '../response/graphql_response.dart';

/// Sends GraphQL requests to a server.
///
/// Implementations return a [GraphQLResponse] for every response that has a
/// GraphQL body (even one carrying errors) and throw a [GraphQLException]
/// for transport failures (network, timeout, cancellation, bad body).
///
/// `GraphQLClient` depends only on this interface, so it can be swapped for
/// a custom transport or for `MockTransport` in tests.
abstract interface class GraphQLTransport {
  /// Executes a query or mutation and returns its single response.
  Future<GraphQLResponse> execute(
    GraphQLRequest request, {
    CancellationToken? cancelToken,
  });

  /// Starts a subscription. Cancelling the stream stops it.
  Stream<GraphQLResponse> subscribe(GraphQLRequest request);

  /// Releases connections and other resources.
  Future<void> dispose();
}

/// Routes subscriptions to [subscriptions] and everything else to
/// [operations].
final class SplitTransport implements GraphQLTransport {
  /// Creates a router.
  const SplitTransport({required this.operations, required this.subscriptions});

  /// Handles queries and mutations (usually `HttpTransport`).
  final GraphQLTransport operations;

  /// Handles subscriptions (usually `WebSocketTransport`).
  final GraphQLTransport subscriptions;

  @override
  Future<GraphQLResponse> execute(
    GraphQLRequest request, {
    CancellationToken? cancelToken,
  }) {
    final target = request.type == GraphQLOperationType.subscription
        ? subscriptions
        : operations;
    return target.execute(request, cancelToken: cancelToken);
  }

  @override
  Stream<GraphQLResponse> subscribe(GraphQLRequest request) =>
      subscriptions.subscribe(request);

  @override
  Future<void> dispose() async {
    await Future.wait([operations.dispose(), subscriptions.dispose()]);
  }
}
