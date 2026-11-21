import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/widgets.dart';

import '../../core/client/graphql_client.dart';
import '../../core/client/observable_query.dart';
import '../../core/client/result_mapper.dart';
import '../../core/json.dart';
import '../../core/request/policies.dart';
import '../../core/response/graphql_exception.dart';
import '../../core/response/graphql_result.dart';
import '../graphql_provider.dart';
import '../query_state.dart';

/// Builds UI for a [GraphQLQuery].
typedef QueryWidgetBuilder<T> = Widget Function(
  BuildContext context,
  QueryState<T> state,
  QueryController<T> controller,
);

/// Actions available to a [GraphQLQuery] builder.
final class QueryController<T> {
  QueryController._(this._state);

  final _GraphQLQueryState<T> _state;

  /// Fetches from the network again. Use it for pull-to-refresh or retry.
  Future<GraphQLResult<T>> refetch() => _state._refetch();

  /// Loads another page and merges it into the current data.
  Future<GraphQLResult<T>> fetchMore({
    JsonMap variables = const {},
    required FetchMoreMerge merge,
  }) =>
      _state._query?.fetchMore(variables: variables, merge: merge) ??
      Future.value(_state._failure());

  /// Whether a network request is in flight.
  bool get isFetching => _state._query?.isFetching ?? false;
}

/// Runs a query and rebuilds whenever its result changes, including after
/// mutations that update the same objects in the cache.
///
/// ```dart
/// GraphQLQuery<User>(
///   document: getUser,
///   variables: {'id': id},
///   parse: (data) => User.fromJson(data['user']),
///   builder: (context, state, query) => switch (state) {
///     QueryLoading() => const CircularProgressIndicator(),
///     QueryData(:final data) => Text(data.name),
///     QueryError(:final exception) => TextButton(
///         onPressed: query.refetch,
///         child: Text('${exception.userMessage} Tap to retry.'),
///       ),
///   },
/// )
/// ```
class GraphQLQuery<T> extends StatefulWidget {
  /// Creates the widget.
  const GraphQLQuery({
    super.key,
    required this.document,
    required this.builder,
    this.variables = const {},
    this.operationName,
    this.parse,
    this.fetchPolicy = FetchPolicy.cacheAndNetwork,
    this.errorPolicy,
    this.maxAge,
    this.pollInterval,
    this.client,
  });

  /// The query document.
  final String document;

  /// The query's variables. Changing them loads the new result.
  final JsonMap variables;

  /// Selects the operation when [document] defines several.
  final String? operationName;

  /// Converts result data to [T].
  final DataParser<T>? parse;

  /// How the cache is used.
  final FetchPolicy fetchPolicy;

  /// How errors alongside data are treated.
  final ErrorPolicy? errorPolicy;

  /// How long cached data counts as fresh; fresh data is not refetched.
  final Duration? maxAge;

  /// Refetch interval, if the data should be polled.
  final Duration? pollInterval;

  /// The client to use instead of the nearest [GraphQLProvider]'s.
  final GraphQLClient? client;

  /// Builds the UI for each state.
  final QueryWidgetBuilder<T> builder;

  @override
  State<GraphQLQuery<T>> createState() => _GraphQLQueryState<T>();
}

class _GraphQLQueryState<T> extends State<GraphQLQuery<T>> {
  static const _equality = DeepCollectionEquality();

  ObservableQuery<T>? _query;
  late final QueryController<T> _controller = QueryController._(this);
  // Cancelled by _unwatch.
  // ignore: cancel_subscriptions
  StreamSubscription<GraphQLResult<T>>? _subscription;
  GraphQLClient? _client;
  QueryState<T> _state = const QueryLoading();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final client = widget.client ?? GraphQLProvider.of(context);
    if (!identical(client, _client)) {
      _client = client;
      _watch();
    }
  }

  @override
  void didUpdateWidget(GraphQLQuery<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final client = widget.client ?? GraphQLProvider.of(context);
    final shapeChanged = !identical(client, _client) ||
        widget.document != oldWidget.document ||
        widget.operationName != oldWidget.operationName ||
        widget.fetchPolicy != oldWidget.fetchPolicy ||
        widget.errorPolicy != oldWidget.errorPolicy ||
        widget.maxAge != oldWidget.maxAge ||
        widget.pollInterval != oldWidget.pollInterval;
    if (shapeChanged) {
      _client = client;
      _watch();
    } else if (!_equality.equals(widget.variables, oldWidget.variables)) {
      final query = _query;
      if (query == null) return _watch();
      _setState(const QueryLoading());
      unawaited(query.setVariables(widget.variables));
    }
  }

  @override
  void dispose() {
    _unwatch();
    super.dispose();
  }

  void _watch() {
    _unwatch();
    final ObservableQuery<T> query;
    try {
      query = _client!.watchQuery<T>(
        widget.document,
        variables: widget.variables,
        operationName: widget.operationName,
        // Always the current widget's parse, so passing a new closure on
        // every build does not restart the query.
        parse: _parse,
        fetchPolicy: widget.fetchPolicy,
        errorPolicy: widget.errorPolicy,
        maxAge: widget.maxAge,
        pollInterval: widget.pollInterval,
      );
    } on GraphQLException catch (e) {
      // An invalid document is shown as an error, not thrown during build.
      _state = QueryError(e);
      return;
    }
    _query = query;
    _state = const QueryLoading();
    _subscription = query.stream.listen(_onResult);
  }

  void _unwatch() {
    final subscription = _subscription;
    final query = _query;
    _subscription = null;
    _query = null;
    if (subscription != null) unawaited(subscription.cancel());
    if (query != null) unawaited(query.close());
  }

  T _parse(JsonMap data) => ResultMapper.parseOrCast(data, widget.parse);

  void _onResult(GraphQLResult<T> result) =>
      _setState(result.toQueryState(previous: _state.data));

  Future<GraphQLResult<T>> _refetch() async {
    final query = _query;
    if (query == null) return _failure();
    if (_state case final QueryData<T> data) {
      _setState(data.copyWith(isRefreshing: true));
    }
    final result = await query.refetch();
    // Unchanged data is not re-emitted, so clear the flag here.
    if (_state case final QueryData<T> data when data.isRefreshing) {
      _setState(data.copyWith(isRefreshing: false));
    }
    return result;
  }

  GraphQLResult<T> _failure() => GraphQLFailure(switch (_state) {
        QueryError(:final exception) => exception,
        _ => const GraphQLException(
            GraphQLErrorKind.unknown,
            'The query is not running',
          ),
      });

  void _setState(QueryState<T> state) {
    if (!mounted) return;
    setState(() => _state = state);
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _state, _controller);
}
