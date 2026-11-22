import 'package:flutter/widgets.dart';

import '../core/client/graphql_client.dart';

/// Makes a [GraphQLClient] available to the widgets below it.
///
/// ```dart
/// runApp(GraphQLProvider(client: client, child: const MyApp()));
/// ```
///
/// It also tells the client when the app goes to the background and comes
/// back (see [GraphQLClient.setAppVisible]): polling pauses while the app
/// is hidden, and watched queries refresh when it returns. Pass
/// `handleAppLifecycle: false` to manage that yourself.
///
/// The provider does not own the client: dispose it yourself when the app
/// no longer needs it.
class GraphQLProvider extends StatefulWidget {
  /// Provides [client] to [child].
  const GraphQLProvider({
    super.key,
    required this.client,
    required this.child,
    this.handleAppLifecycle = true,
  });

  /// The provided client.
  final GraphQLClient client;

  /// The widget below this one.
  final Widget child;

  /// Whether to call [GraphQLClient.setAppVisible] when the app is hidden
  /// or shown.
  final bool handleAppLifecycle;

  /// The nearest client, or null if there is no [GraphQLProvider] above.
  static GraphQLClient? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_GraphQLScope>()?.client;

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
  State<GraphQLProvider> createState() => _GraphQLProviderState();
}

class _GraphQLProviderState extends State<GraphQLProvider> {
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    _syncLifecycle();
  }

  @override
  void didUpdateWidget(GraphQLProvider oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncLifecycle();
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    super.dispose();
  }

  /// Listens to the app lifecycle only while [GraphQLProvider.handleAppLifecycle]
  /// is true. The callbacks read the current client, so swapping clients
  /// needs no new listener.
  void _syncLifecycle() {
    if (widget.handleAppLifecycle == (_lifecycle != null)) return;
    if (widget.handleAppLifecycle) {
      _lifecycle = AppLifecycleListener(
        onHide: () => widget.client.setAppVisible(false),
        onShow: () => widget.client.setAppVisible(true),
      );
    } else {
      _lifecycle?.dispose();
      _lifecycle = null;
    }
  }

  @override
  Widget build(BuildContext context) =>
      _GraphQLScope(client: widget.client, child: widget.child);
}

class _GraphQLScope extends InheritedWidget {
  const _GraphQLScope({required this.client, required super.child});

  final GraphQLClient client;

  @override
  bool updateShouldNotify(_GraphQLScope oldWidget) =>
      !identical(client, oldWidget.client);
}

/// Shorthand for [GraphQLProvider.of].
extension GraphQLContext on BuildContext {
  /// The nearest [GraphQLClient].
  GraphQLClient get graphQLClient => GraphQLProvider.of(this);
}
