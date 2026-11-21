import 'package:flutter/widgets.dart';

import '../../core/client/graphql_client.dart';
import '../../core/client/query_manager.dart';
import '../../core/client/result_mapper.dart';
import '../../core/json.dart';
import '../../core/request/policies.dart';
import '../../core/response/graphql_exception.dart';
import '../../core/response/graphql_result.dart';
import '../graphql_provider.dart';
import '../query_state.dart';

/// Runs the mutation of a [GraphQLMutation].
typedef MutationRunner<T> = Future<GraphQLResult<T>> Function({
  JsonMap variables,
  JsonMap? optimisticResponse,
});

/// Builds UI for a [GraphQLMutation].
typedef MutationWidgetBuilder<T> = Widget Function(
  BuildContext context,
  MutationState<T> state,
  MutationRunner<T> run,
);

/// Provides a function that runs a mutation, and rebuilds with its state.
///
/// ```dart
/// GraphQLMutation<Post>(
///   document: createPost,
///   parse: (data) => Post.fromJson(data['createPost']),
///   refetchQueries: const ['Feed'],
///   onCompleted: (post) => Navigator.pop(context),
///   builder: (context, state, run) => ElevatedButton(
///     onPressed: state is MutationRunning
///         ? null
///         : () => run(variables: {'title': title}),
///     child: const Text('Publish'),
///   ),
/// )
/// ```
class GraphQLMutation<T> extends StatefulWidget {
  /// Creates the widget.
  const GraphQLMutation({
    super.key,
    required this.document,
    required this.builder,
    this.operationName,
    this.parse,
    this.errorPolicy,
    this.update,
    this.refetchQueries = const [],
    this.onCompleted,
    this.onError,
    this.client,
  });

  /// The mutation document.
  final String document;

  /// Selects the operation when [document] defines several.
  final String? operationName;

  /// Converts result data to [T].
  final DataParser<T>? parse;

  /// How errors alongside data are treated.
  final ErrorPolicy? errorPolicy;

  /// Edits the cache with the mutation's result.
  final CacheUpdater? update;

  /// Watched queries to refetch after success, by operation name.
  final List<String> refetchQueries;

  /// Called with the parsed data after success, while the widget is still
  /// mounted (so it can safely use its context, e.g. to navigate).
  final void Function(T data)? onCompleted;

  /// Called after failure, while the widget is still mounted.
  final void Function(GraphQLException exception)? onError;

  /// The client to use instead of the nearest [GraphQLProvider]'s.
  final GraphQLClient? client;

  /// Builds the UI for each state.
  final MutationWidgetBuilder<T> builder;

  @override
  State<GraphQLMutation<T>> createState() => _GraphQLMutationState<T>();
}

class _GraphQLMutationState<T> extends State<GraphQLMutation<T>> {
  MutationState<T> _state = const MutationIdle();
  int _runId = 0;

  Future<GraphQLResult<T>> _run({
    JsonMap variables = const {},
    JsonMap? optimisticResponse,
  }) async {
    final runId = ++_runId;
    final client = widget.client ?? GraphQLProvider.of(context);
    _setState(const MutationRunning());

    final result = await client.mutate<T>(
      widget.document,
      variables: variables,
      operationName: widget.operationName,
      parse: widget.parse,
      errorPolicy: widget.errorPolicy,
      optimisticResponse: optimisticResponse,
      update: widget.update,
      refetchQueries: widget.refetchQueries,
    );

    // Callbacks need a live context; a later run supersedes the UI state.
    if (!mounted) return result;
    switch (result) {
      case GraphQLSuccess(:final data):
        if (runId == _runId) _setState(MutationSuccess(data));
        widget.onCompleted?.call(data);
      case GraphQLFailure(:final exception):
        if (runId == _runId) _setState(MutationFailure(exception));
        widget.onError?.call(exception);
    }
    return result;
  }

  void _setState(MutationState<T> state) {
    if (!mounted) return;
    setState(() => _state = state);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _state, _run);
}
