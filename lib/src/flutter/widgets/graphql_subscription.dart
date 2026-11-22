import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/widgets.dart';

import '../../core/client/graphql_client.dart';
import '../../core/client/result_mapper.dart';
import '../../core/json.dart';
import '../../core/request/policies.dart';
import '../../core/request/typed_operation.dart';
import '../../core/response/graphql_result.dart';
import '../graphql_provider.dart';
import '../query_state.dart';

/// Builds UI for a [GraphQLSubscription].
typedef SubscriptionWidgetBuilder<T> = Widget Function(
  BuildContext context,
  QueryState<T> state,
);

/// Subscribes while mounted and rebuilds with every event.
///
/// The subscription restarts when [document], [variables] or the client
/// change, and stops when the widget is removed.
///
/// ```dart
/// GraphQLSubscription<Message>(
///   document: onMessage,
///   variables: {'room': roomId},
///   parse: (data) => Message.fromJson(data['messageAdded']),
///   builder: (context, state) => switch (state) {
///     QueryLoading() => const Text('Waiting for messages…'),
///     QueryData(:final data) => Text(data.text),
///     QueryError(:final exception) => Text(exception.userMessage),
///   },
/// )
/// ```
class GraphQLSubscription<T> extends StatefulWidget {
  /// Creates the widget.
  const GraphQLSubscription({
    super.key,
    required this.document,
    required this.builder,
    this.variables = const {},
    this.operationName,
    this.parse,
    this.errorPolicy,
    this.onData,
    this.client,
  });

  /// Runs a generated [operation] (see `TypedOperation`), so the document,
  /// variables and parser come from one typed value.
  GraphQLSubscription.operation(
    TypedOperation<T> operation, {
    super.key,
    required this.builder,
    this.errorPolicy,
    this.onData,
    this.client,
  })  : document = operation.document,
        variables = operation.variables,
        operationName = null,
        parse = operation.parse;

  /// The subscription document.
  final String document;

  /// The subscription's variables.
  final JsonMap variables;

  /// Selects the operation when [document] defines several.
  final String? operationName;

  /// Converts event data to [T].
  final DataParser<T>? parse;

  /// How errors alongside data are treated.
  final ErrorPolicy? errorPolicy;

  /// Called for every successful event, e.g. to show a notification.
  final void Function(T data)? onData;

  /// The client to use instead of the nearest [GraphQLProvider]'s.
  final GraphQLClient? client;

  /// Builds the UI for each state.
  final SubscriptionWidgetBuilder<T> builder;

  @override
  State<GraphQLSubscription<T>> createState() => _GraphQLSubscriptionState<T>();
}

class _GraphQLSubscriptionState<T> extends State<GraphQLSubscription<T>> {
  static const _equality = DeepCollectionEquality();

  StreamSubscription<GraphQLResult<T>>? _subscription;
  GraphQLClient? _client;
  QueryState<T> _state = const QueryLoading();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final client = widget.client ?? GraphQLProvider.of(context);
    if (!identical(client, _client)) {
      _client = client;
      _subscribe();
    }
  }

  @override
  void didUpdateWidget(GraphQLSubscription<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final client = widget.client ?? GraphQLProvider.of(context);
    if (!identical(client, _client) ||
        widget.document != oldWidget.document ||
        widget.operationName != oldWidget.operationName ||
        widget.errorPolicy != oldWidget.errorPolicy ||
        !_equality.equals(widget.variables, oldWidget.variables)) {
      _client = client;
      _subscribe();
    }
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  void _subscribe() {
    unawaited(_subscription?.cancel());
    _state = const QueryLoading();
    _subscription = _client!
        .subscribe<T>(
          widget.document,
          variables: widget.variables,
          operationName: widget.operationName,
          parse: _parse,
          errorPolicy: widget.errorPolicy,
        )
        .listen(_onResult);
  }

  T _parse(JsonMap data) => ResultMapper.parseOrCast(data, widget.parse);

  void _onResult(GraphQLResult<T> result) {
    if (!mounted) return;
    if (result case GraphQLSuccess(:final data)) widget.onData?.call(data);
    setState(() => _state = result.toQueryState(previous: _state.data));
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _state);
}
