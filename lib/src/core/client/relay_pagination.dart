import '../json.dart';

/// Cursor pagination for a [Relay-style connection](https://relay.dev/graphql/connections.htm)
/// (`edges`/`nodes` plus `pageInfo`), to use with `fetchMore`.
///
/// ```dart
/// const posts = RelayPagination('user.posts');
///
/// if (posts.hasNextPage(data)) {
///   await query.fetchMore(
///     variables: posts.nextPageVariables(data)!,
///     merge: posts.merge,
///   );
/// }
/// ```
///
/// Select `pageInfo { hasNextPage endCursor }` in the query.
final class RelayPagination {
  /// Paginates the connection at [path], a dot-separated list of fields from
  /// the root of the data (e.g. `'user.posts'`). The cursor is passed to the
  /// next page as [cursorVariable].
  const RelayPagination(this.path, {this.cursorVariable = 'after'});

  /// Where the connection is in the data, e.g. `'user.posts'`.
  final String path;

  /// The variable that receives the next page's cursor.
  final String cursorVariable;

  /// Appends [more]'s edges (and nodes) to [previous]'s.
  ///
  /// Other connection fields (like `totalCount`) come from [more];
  /// `pageInfo` takes [more]'s end and keeps [previous]'s start. The inputs
  /// are not modified.
  JsonMap merge(JsonMap previous, JsonMap more) {
    final old = _connection(previous);
    final next = _connection(more);
    final merged = <String, dynamic>{
      ...next,
      for (final list in const ['edges', 'nodes'])
        if (old[list] is List || next[list] is List)
          list: [...?old[list] as List?, ...?next[list] as List?],
      if (next['pageInfo'] case final JsonMap pageInfo)
        'pageInfo': {
          ...pageInfo,
          if (old['pageInfo'] case final JsonMap first) ...{
            'hasPreviousPage': first['hasPreviousPage'],
            'startCursor': first['startCursor'],
          },
        },
    };
    return _replace(more, _fields, merged);
  }

  /// Whether [data] says another page follows.
  bool hasNextPage(JsonMap data) => _pageInfo(data)['hasNextPage'] == true;

  /// The variables that load the page after [data], or null on the last
  /// page.
  JsonMap? nextPageVariables(JsonMap data) {
    if (!hasNextPage(data)) return null;
    return {cursorVariable: _pageInfo(data)['endCursor']};
  }

  List<String> get _fields => path.split('.');

  JsonMap _pageInfo(JsonMap data) {
    final pageInfo = _connection(data)['pageInfo'];
    if (pageInfo is JsonMap) return pageInfo;
    throw ArgumentError.value(
      data,
      'data',
      'No pageInfo at "$path"; select pageInfo { hasNextPage endCursor }',
    );
  }

  JsonMap _connection(JsonMap data) {
    Object? node = data;
    for (final field in _fields) {
      node = node is JsonMap ? node[field] : null;
    }
    if (node is JsonMap) return node;
    throw ArgumentError.value(data, 'data', 'No connection at "$path"');
  }

  /// A copy of [data] with the value at [fields] replaced by [value].
  static JsonMap _replace(JsonMap data, List<String> fields, JsonMap value) {
    final [field, ...rest] = fields;
    return {
      ...data,
      field:
          rest.isEmpty ? value : _replace(data[field] as JsonMap, rest, value),
    };
  }
}
