import 'package:flutter/widgets.dart';

import '../core/client/graphql_client.dart';

/// Makes a [GraphQLClient] available to the widgets below it.
///
/// ```dart
/// runApp(GraphQLProvider(client: client, child: const MyApp()));
/// ```
///
/// The provider does not own the client: dispose it yourself when the app
/// no longer needs it.
class GraphQLProvider extends InheritedWidget {
  /// Provides [client] to [child].
  const GraphQLProvider(
      {super.key, required this.client, required super.child});

  /// The provided client.
  final GraphQLClient client;

  /// The nearest client, or null if there is no [GraphQLProvider] above.
  static GraphQLClient? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GraphQLProvider>()?.client;

  /// The nearest client.
  ///
  /// Throws a [FlutterError] explaining the fix when there is no
  /// [GraphQLProvider] above [context].
  static GraphQLClient of(BuildContext context) {
    final client = maybeOf(context);
    if (client != null) return client;
    throw FlutterError.fromParts([
      ErrorSummary('No GraphQLProvider found in the widget tree.'),
      ErrorDescription(
        '${context.widget.runtimeType} needs a GraphQLClient, but none of its '
        'ancestors is a GraphQLProvider.',
      ),
      ErrorHint(
        'Wrap your app in GraphQLProvider(client: client, child: ...), or '
        'pass client: directly to the widget.',
      ),
    ]);
  }

  @override
  bool updateShouldNotify(GraphQLProvider oldWidget) =>
      !identical(client, oldWidget.client);
}

/// Shorthand for [GraphQLProvider.of].
extension GraphQLContext on BuildContext {
  /// The nearest [GraphQLClient].
  GraphQLClient get graphQLClient => GraphQLProvider.of(this);
}
