import 'package:gql/ast.dart';
import 'package:gql/language.dart' as gql;
import 'package:source_span/source_span.dart';

import 'codegen_exception.dart';

/// Fast lookups over a schema written in SDL: types by name, the root
/// type of each operation and the concrete types behind unions and
/// interfaces.
final class SchemaIndex {
  SchemaIndex._(this._types, this._roots, this._possibleTypes);

  /// Parses [sdl]. [url] names the file in error messages.
  factory SchemaIndex.parse(String sdl, {String url = 'schema.graphql'}) {
    final DocumentNode document;
    try {
      document = gql.parseString(sdl, url: url);
    } on SourceSpanException catch (e) {
      throw CodegenException(e.message, e.span);
    }

    final types = <String, TypeDefinitionNode>{
      for (final definition in document.definitions)
        if (definition is TypeDefinitionNode) definition.name.value: definition,
    };
    final roots = {
      OperationType.query: 'Query',
      OperationType.mutation: 'Mutation',
      OperationType.subscription: 'Subscription',
      for (final schema
          in document.definitions.whereType<SchemaDefinitionNode>())
        for (final root in schema.operationTypes)
          root.operation: root.type.name.value,
    };
    final possible = <String, Set<String>>{};
    for (final type in types.values) {
      switch (type) {
        case UnionTypeDefinitionNode(:final name, types: final members):
          possible[name.value] = {for (final m in members) m.name.value};
        case ObjectTypeDefinitionNode(:final name, :final interfaces):
          for (final interface in interfaces) {
            (possible[interface.name.value] ??= {}).add(name.value);
          }
        default:
          break;
      }
    }
    return SchemaIndex._(types, roots, possible);
  }

  final Map<String, TypeDefinitionNode> _types;
  final Map<OperationType, String> _roots;
  final Map<String, Set<String>> _possibleTypes;

  /// Every type defined in the schema.
  Iterable<TypeDefinitionNode> get types => _types.values;

  /// The type named [name], or null (built-in scalars are not listed).
  TypeDefinitionNode? type(String name) => _types[name];

  /// The root type of [operation], e.g. `Query`.
  ObjectTypeDefinitionNode? rootType(OperationType operation) {
    final type = _types[_roots[operation]];
    return type is ObjectTypeDefinitionNode ? type : null;
  }

  /// The object types a union or interface named [name] can be.
  Set<String> possibleTypes(String name) => _possibleTypes[name] ?? const {};

  /// Whether [name] is a union or an interface.
  bool isAbstract(String name) =>
      _types[name] is UnionTypeDefinitionNode ||
      _types[name] is InterfaceTypeDefinitionNode;

  /// The field [fieldName] of the object or interface [typeName], or null.
  FieldDefinitionNode? field(String typeName, String fieldName) {
    final fields = switch (_types[typeName]) {
      ObjectTypeDefinitionNode(:final fields) => fields,
      InterfaceTypeDefinitionNode(:final fields) => fields,
      _ => const <FieldDefinitionNode>[],
    };
    for (final field in fields) {
      if (field.name.value == fieldName) return field;
    }
    return null;
  }
}
