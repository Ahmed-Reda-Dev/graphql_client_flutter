import 'package:gql/ast.dart';
import 'package:gql/language.dart' show printNode;

import 'codegen_exception.dart';
import 'naming.dart';
import 'operation_model.dart';
import 'schema_types_writer.dart' show nonNullable;
import 'type_mapper.dart';

/// Writes an operation's document constant, variables helper and the
/// `GraphQLClient` extension that runs it with typed variables and data.
final class OperationWriter {
  /// Creates a writer. [fragments] are all fragment definitions by name,
  /// to include the ones an operation uses in its document.
  OperationWriter(this.mapper, this.fragments);

  /// Converts types.
  final TypeMapper mapper;

  /// Fragment definitions by name.
  final Map<String, FragmentDefinitionNode> fragments;

  /// `GraphQLClient` members a generated method must not shadow (an
  /// extension method never wins over one).
  static const _clientMembers = {
    'query', 'mutate', 'subscribe', 'watchQuery', 'refetchQueries', //
    'resetStore', 'dispose', 'cache', 'offlineQueue', 'setOnline',
    'setAppVisible', 'isOnline', 'isAppVisible', 'defaultFetchPolicy',
    'defaultErrorPolicy', 'defaultMaxAge', 'addTypename',
  };

  /// Option parameters every generated method may have.
  static const _optionNames = {
    'fetchPolicy', 'errorPolicy', 'maxAge', 'pollInterval', 'headers', //
    'cancelToken', 'optimisticResponse', 'update', 'refetchQueries',
    'queueIfOffline',
  };

  /// The Dart source for [operation].
  String write(OperationModel operation) {
    final out = StringBuffer();
    final name = operation.name;
    final method = Naming.member(name);
    final node = operation.node;
    if (_clientMembers.contains(method)) {
      throw CodegenException(
        'An operation named "$name" would generate client.$method, which '
        'GraphQLClient already has; rename the operation',
        node.name?.span ?? node.span,
      );
    }
    final variables = [
      for (final v in node.variableDefinitions) _variable(v),
    ];
    final document = '${Naming.camel(name)}Document';
    final data = operation.data.name;

    _writeDocument(out, operation, document);
    _writeVariables(out, name, variables);
    final args = variables.isEmpty
        ? ''
        : '${Naming.camel(name)}Variables(${[
            for (final v in variables) '${v.dart}: ${v.dart}',
          ].join(', ')})';
    final params = [
      for (final v in variables) v.param,
    ];

    if (node.type != OperationType.mutation) {
      _writeTypedOperation(out, name, document, data, params, args);
    }
    out
      ..writeln('/// Runs `$name` with typed variables and data.')
      ..writeln('extension ${Naming.pascal(name)}Operation on GraphQLClient {');
    switch (node.type) {
      case OperationType.query:
        _writeQuery(out, name, method, document, data, params, args);
      case OperationType.mutation:
        _writeMutation(out, name, method, document, data, params, args);
      case OperationType.subscription:
        _writeSubscription(out, name, method, document, data, params, args);
    }
    out
      ..writeln('}')
      ..writeln();
    return out.toString();
  }

  void _writeDocument(
    StringBuffer out,
    OperationModel operation,
    String constant,
  ) {
    final used = <String>{};
    void visit(SelectionSetNode set) {
      for (final selection in set.selections) {
        switch (selection) {
          case FieldNode(selectionSet: final inner?):
            visit(inner);
          case InlineFragmentNode(:final selectionSet):
            visit(selectionSet);
          case FragmentSpreadNode(:final name):
            final fragment = fragments[name.value];
            if (fragment != null && used.add(name.value)) {
              visit(fragment.selectionSet);
            }
          default:
            break;
        }
      }
    }

    visit(operation.node.selectionSet);
    final parts = [
      printNode(operation.node),
      for (final name in used.toList()..sort()) printNode(fragments[name]!),
    ];
    out
      ..writeln('/// The `${operation.name}` document.')
      ..writeln("const $constant = r'''")
      ..writeln(parts.join('\n\n'))
      ..writeln("''';")
      ..writeln();
  }

  void _writeVariables(StringBuffer out, String name, List<_Variable> vars) {
    if (vars.isEmpty) return;
    out
      ..writeln('/// The variables of `$name` as JSON. Unset optional ones '
          'are left out.')
      ..writeln('JsonMap ${Naming.camel(name)}Variables({')
      ..writeAll([for (final v in vars) '  ${v.param},\n'])
      ..writeln('}) =>')
      ..writeln('    {');
    for (final v in vars) {
      final key = Naming.literal(v.name);
      final value = mapper.toJson(nonNullable(v.node.type), v.dart);
      out.writeln(v.required
          ? '      $key: $value,'
          : '      if (${v.dart} case final ${v.dart}?) $key: $value,');
    }
    out
      ..writeln('    };')
      ..writeln();
  }

  /// A `TypedOperation` factory, for `GraphQLQuery.operation` and
  /// `GraphQLSubscription.operation`.
  void _writeTypedOperation(
    StringBuffer out,
    String name,
    String document,
    String data,
    List<String> params,
    String args,
  ) {
    out
      ..writeln('/// `$name` as a typed operation, e.g. for '
          '`GraphQLQuery.operation`.')
      ..write('TypedOperation<$data> ${Naming.camel(name)}Operation(')
      ..write(params.isEmpty ? '' : '{${params.join(', ')},}')
      ..writeln(') =>')
      ..writeln('    TypedOperation(')
      ..writeln('      document: $document,')
      ..write(args.isEmpty ? '' : '      variables: $args,\n')
      ..writeln('      parse: $data.fromJson,')
      ..writeln('    );')
      ..writeln();
  }

  void _writeQuery(
    StringBuffer out,
    String name,
    String method,
    String document,
    String data,
    List<String> params,
    String args,
  ) {
    out
      ..writeln('  /// Runs the `$name` query.')
      ..writeln('  Future<GraphQLResult<$data>> $method({')
      ..writeAll([for (final p in params) '    $p,\n'])
      ..writeln('    FetchPolicy? fetchPolicy,')
      ..writeln('    ErrorPolicy? errorPolicy,')
      ..writeln('    Duration? maxAge,')
      ..writeln('    Map<String, String> headers = const {},')
      ..writeln('    CancellationToken? cancelToken,')
      ..writeln('  }) =>')
      ..writeln('      query(')
      ..writeln('        $document,')
      ..write(args.isEmpty ? '' : '        variables: $args,\n')
      ..writeln('        parse: $data.fromJson,')
      ..writeln('        fetchPolicy: fetchPolicy,')
      ..writeln('        errorPolicy: errorPolicy,')
      ..writeln('        maxAge: maxAge,')
      ..writeln('        headers: headers,')
      ..writeln('        cancelToken: cancelToken,')
      ..writeln('      );')
      ..writeln()
      ..writeln('  /// Watches the `$name` query (see `watchQuery`).')
      ..writeln('  ObservableQuery<$data> watch${Naming.pascal(name)}({')
      ..writeAll([for (final p in params) '    $p,\n'])
      ..writeln('    FetchPolicy fetchPolicy = FetchPolicy.cacheAndNetwork,')
      ..writeln('    ErrorPolicy? errorPolicy,')
      ..writeln('    Duration? maxAge,')
      ..writeln('    Duration? pollInterval,')
      ..writeln('    Map<String, String> headers = const {},')
      ..writeln('  }) =>')
      ..writeln('      watchQuery(')
      ..writeln('        $document,')
      ..write(args.isEmpty ? '' : '        variables: $args,\n')
      ..writeln('        parse: $data.fromJson,')
      ..writeln('        fetchPolicy: fetchPolicy,')
      ..writeln('        errorPolicy: errorPolicy,')
      ..writeln('        maxAge: maxAge,')
      ..writeln('        pollInterval: pollInterval,')
      ..writeln('        headers: headers,')
      ..writeln('      );');
  }

  void _writeMutation(
    StringBuffer out,
    String name,
    String method,
    String document,
    String data,
    List<String> params,
    String args,
  ) {
    out
      ..writeln('  /// Runs the `$name` mutation.')
      ..writeln('  ///')
      ..writeln('  /// [update] receives the typed result to edit the cache.')
      ..writeln('  Future<GraphQLResult<$data>> $method({')
      ..writeAll([for (final p in params) '    $p,\n'])
      ..writeln('    ErrorPolicy? errorPolicy,')
      ..writeln('    $data? optimisticResponse,')
      ..writeln('    void Function(GraphQLCache cache, $data data)? update,')
      ..writeln('    List<String> refetchQueries = const [],')
      ..writeln('    Map<String, String> headers = const {},')
      ..writeln('    CancellationToken? cancelToken,')
      ..writeln('    bool queueIfOffline = false,')
      ..writeln('  }) =>')
      ..writeln('      mutate(')
      ..writeln('        $document,')
      ..write(args.isEmpty ? '' : '        variables: $args,\n')
      ..writeln('        parse: $data.fromJson,')
      ..writeln('        errorPolicy: errorPolicy,')
      ..writeln('        optimisticResponse: optimisticResponse?.toJson(),')
      ..writeln('        update: update == null')
      ..writeln('            ? null')
      ..writeln('            : (cache, json) => update(cache, '
          '$data.fromJson(json)),')
      ..writeln('        refetchQueries: refetchQueries,')
      ..writeln('        headers: headers,')
      ..writeln('        cancelToken: cancelToken,')
      ..writeln('        queueIfOffline: queueIfOffline,')
      ..writeln('      );');
  }

  void _writeSubscription(
    StringBuffer out,
    String name,
    String method,
    String document,
    String data,
    List<String> params,
    String args,
  ) {
    out
      ..writeln('  /// Starts the `$name` subscription.')
      ..writeln('  Stream<GraphQLResult<$data>> $method({')
      ..writeAll([for (final p in params) '    $p,\n'])
      ..writeln('    ErrorPolicy? errorPolicy,')
      ..writeln('  }) =>')
      ..writeln('      subscribe(')
      ..writeln('        $document,')
      ..write(args.isEmpty ? '' : '        variables: $args,\n')
      ..writeln('        parse: $data.fromJson,')
      ..writeln('        errorPolicy: errorPolicy,')
      ..writeln('      );');
  }

  _Variable _variable(VariableDefinitionNode node) {
    final name = node.variable.name.value;
    final dart = Naming.member(name);
    if (_optionNames.contains(dart)) {
      throw CodegenException(
        'A variable named "\$$name" clashes with the generated "$dart" '
        'option; rename the variable',
        node.span,
      );
    }
    // gql always sets defaultValue; its value is null when there is none.
    final required = node.type.isNonNull && node.defaultValue?.value == null;
    final type = mapper.dartType(nonNullable(node.type));
    return _Variable(
      node: node,
      name: name,
      dart: dart,
      required: required,
      param: required ? 'required $type $dart' : '$type? $dart',
    );
  }
}

final class _Variable {
  _Variable({
    required this.node,
    required this.name,
    required this.dart,
    required this.required,
    required this.param,
  });

  final VariableDefinitionNode node;
  final String name;
  final String dart;
  final bool required;
  final String param;
}
