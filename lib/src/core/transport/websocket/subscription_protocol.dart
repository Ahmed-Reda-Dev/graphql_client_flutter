/// WebSocket sub-protocols for GraphQL subscriptions.
enum SubscriptionProtocol {
  /// `graphql-transport-ws`, implemented by the `graphql-ws` library.
  /// The current standard (Apollo Server 4+, GraphQL Yoga, Hasura,
  /// Hot Chocolate, graphql-java and others).
  graphqlTransportWs(
    webSocketProtocol: 'graphql-transport-ws',
    subscribe: 'subscribe',
    next: 'next',
    stop: 'complete',
  ),

  /// The legacy Apollo `subscriptions-transport-ws` protocol, whose
  /// sub-protocol name is `graphql-ws`. Use it only for servers that do not
  /// support [graphqlTransportWs].
  subscriptionsTransportWs(
    webSocketProtocol: 'graphql-ws',
    subscribe: 'start',
    next: 'data',
    stop: 'stop',
  );

  const SubscriptionProtocol({
    required this.webSocketProtocol,
    required this.subscribe,
    required this.next,
    required this.stop,
  });

  /// Value of the `Sec-WebSocket-Protocol` header.
  final String webSocketProtocol;

  /// Message type that starts an operation.
  final String subscribe;

  /// Message type that carries a result.
  final String next;

  /// Message type the client sends to stop an operation.
  final String stop;

  /// Whether the client sends keep-alive pings (the legacy protocol relies
  /// on server `ka` messages instead).
  bool get clientPings => this == graphqlTransportWs;
}
