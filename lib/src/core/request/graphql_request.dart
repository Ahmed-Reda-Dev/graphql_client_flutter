import 'dart:convert';

import 'package:meta/meta.dart';

import '../json.dart';
import 'graphql_document.dart';

/// A single GraphQL operation to execute: a document plus its variables.
///
/// Transports receive this; app code normally uses `GraphQLClient` methods
/// and never builds one directly.
@immutable
final class GraphQLRequest {
  /// Creates a request.
  const GraphQLRequest({
    required this.document,
    this.variables = const {},
    this.headers = const {},
  });

  /// The parsed operation.
  final GraphQLDocument document;

  /// Values for the operation's variables. May contain upload files.
  final JsonMap variables;

  /// Extra HTTP headers for this request only.
  final Map<String, String> headers;

  /// The operation's name, if it has one.
  String? get operationName => document.operationName;

  /// Whether this is a query, mutation or subscription.
  GraphQLOperationType get type => document.type;

  /// Returns a copy with different [variables].
  GraphQLRequest withVariables(JsonMap variables) => GraphQLRequest(
        document: document,
        variables: variables,
        headers: headers,
      );

  /// The standard GraphQL-over-HTTP body.
  ///
  /// Set [includeQuery] to false to send only [extensions] (persisted
  /// queries).
  JsonMap toJson({bool includeQuery = true, JsonMap? extensions}) => {
        if (includeQuery) 'query': document.printed,
        if (variables.isNotEmpty) 'variables': variables,
        if (operationName != null) 'operationName': operationName,
        if (extensions != null) 'extensions': extensions,
      };

  /// A key that is equal for requests that would return the same result.
  ///
  /// Used to deduplicate identical in-flight queries.
  String get identity =>
      '${document.printed}|${operationName ?? ''}|${_canonicalJson(variables)}'
      '|${_canonicalJson(headers)}';

  static String _canonicalJson(Object? value) =>
      jsonEncode(_canonicalize(value), toEncodable: (o) => o.toString());

  static Object? _canonicalize(Object? value) => switch (value) {
        final Map<dynamic, dynamic> map => {
            for (final key in map.keys.map((k) => '$k').toList()..sort())
              key: _canonicalize(map[key]),
          },
        final List<dynamic> list => list.map(_canonicalize).toList(),
        _ => value,
      };

  @override
  bool operator ==(Object other) =>
      other is GraphQLRequest && other.identity == identity;

  @override
  int get hashCode => identity.hashCode;

  @override
  String toString() =>
      'GraphQLRequest(${operationName ?? type.name}, variables: $variables)';
}
