import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:gql/ast.dart' as gql_ast;
import 'package:gql/language.dart' as gql;
import 'package:meta/meta.dart';
import 'package:normalize/utils.dart' show AddTypenameVisitor;
import 'package:source_span/source_span.dart';

import '../response/graphql_exception.dart';

/// The kind of a GraphQL operation.
enum GraphQLOperationType {
  /// A read.
  query,

  /// A write.
  mutation,

  /// A stream of events.
  subscription,
}

/// A parsed, validated GraphQL document ready to send.
///
/// Create one with [GraphQLDocument.parse]. Parsing is cached, so calling it
/// repeatedly with the same source is cheap.
@immutable
final class GraphQLDocument {
  const GraphQLDocument._({
    required this.source,
    required this.ast,
    required this.printed,
    required this.type,
    required this.operationName,
  });

  /// Parses [source] and selects the operation to run.
  ///
  /// [operationName] is required when the document defines more than one
  /// operation. With [addTypename], `__typename` is added to every selection
  /// set so the cache can normalize results.
  ///
  /// Throws a [GraphQLException] of kind [GraphQLErrorKind.invalidRequest]
  /// when the document is not valid.
  factory GraphQLDocument.parse(
    String source, {
    String? operationName,
    bool addTypename = true,
  }) {
    final key = '${addTypename ? 1 : 0}|${operationName ?? ''}|$source';
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached; // Mark as most recently used.
      return cached;
    }
    final parsed = _parse(source, operationName, addTypename);
    _cache[key] = parsed;
    if (_cache.length > _maxCacheSize) _cache.remove(_cache.keys.first);
    return parsed;
  }

  static const _maxCacheSize = 256;
  static final _cache = <String, GraphQLDocument>{};

  /// The document as written by the caller.
  final String source;

  /// The parsed (and possibly `__typename`-augmented) document.
  final gql_ast.DocumentNode ast;

  /// The document text that is sent to the server.
  final String printed;

  /// The kind of the selected operation.
  final GraphQLOperationType type;

  /// The name of the selected operation, if it has one.
  final String? operationName;

  /// SHA-256 of [printed], used by Automatic Persisted Queries.
  String get sha256Hash => sha256.convert(utf8.encode(printed)).toString();

  static GraphQLDocument _parse(
    String source,
    String? operationName,
    bool addTypename,
  ) {
    gql_ast.DocumentNode document;
    try {
      document = gql.parseString(source);
    } on SourceSpanException catch (e, stackTrace) {
      throw GraphQLException(
        GraphQLErrorKind.invalidRequest,
        'Invalid GraphQL document: ${e.toString()}',
        cause: e,
        stackTrace: stackTrace,
        operationName: operationName,
      );
    }

    final operation = _selectOperation(document, operationName);
    if (addTypename) {
      document = gql_ast.transform(document, const [AddTypenameVisitor()]);
    }

    return GraphQLDocument._(
      source: source,
      ast: document,
      printed: gql.printNode(document),
      type: switch (operation.type) {
        gql_ast.OperationType.query => GraphQLOperationType.query,
        gql_ast.OperationType.mutation => GraphQLOperationType.mutation,
        gql_ast.OperationType.subscription => GraphQLOperationType.subscription,
      },
      operationName: operation.name?.value,
    );
  }

  static gql_ast.OperationDefinitionNode _selectOperation(
    gql_ast.DocumentNode document,
    String? operationName,
  ) {
    final operations = document.definitions
        .whereType<gql_ast.OperationDefinitionNode>()
        .toList();

    if (operations.isEmpty) {
      throw GraphQLException(
        GraphQLErrorKind.invalidRequest,
        'The document has no query, mutation or subscription.',
        operationName: operationName,
      );
    }
    if (operationName != null) {
      final match = operations.where((o) => o.name?.value == operationName);
      if (match.isEmpty) {
        throw GraphQLException(
          GraphQLErrorKind.invalidRequest,
          'No operation named "$operationName" in the document.',
          operationName: operationName,
        );
      }
      return match.first;
    }
    if (operations.length > 1) {
      final names = operations.map((o) => o.name?.value ?? '<anonymous>');
      throw GraphQLException(
        GraphQLErrorKind.invalidRequest,
        'The document defines ${operations.length} operations '
        '(${names.join(', ')}); pass operationName to choose one.',
      );
    }
    return operations.single;
  }

  @override
  bool operator ==(Object other) =>
      other is GraphQLDocument &&
      other.printed == printed &&
      other.operationName == operationName;

  @override
  int get hashCode => Object.hash(printed, operationName);

  @override
  String toString() => 'GraphQLDocument(${operationName ?? type.name})';
}
