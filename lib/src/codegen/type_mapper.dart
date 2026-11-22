import 'package:gql/ast.dart';

import 'codegen_exception.dart';
import 'schema_index.dart';

/// Names the generated class for an object, interface or union type.
typedef ObjectClassNamer = String Function(String typeName);

/// Maps GraphQL types to Dart types, and writes the expressions that
/// convert between the two and JSON.
final class TypeMapper {
  /// Creates a mapper. [scalars] maps custom scalar names to one of
  /// [supportedScalarTypes]; unmapped custom scalars become `Object`.
  TypeMapper(this.schema, {Map<String, String> scalars = const {}})
      : _scalars = {..._builtInScalars, ..._validated(scalars)};

  /// The Dart types a custom scalar can map to.
  static const supportedScalarTypes = {
    'String', 'int', 'double', 'num', 'bool', 'DateTime', 'Object', //
  };

  static const _builtInScalars = {
    'ID': 'String',
    'String': 'String',
    'Int': 'int',
    'Float': 'double',
    'Boolean': 'bool',
  };

  /// The schema the types come from.
  final SchemaIndex schema;

  final Map<String, String> _scalars;

  static Map<String, String> _validated(Map<String, String> scalars) {
    for (final MapEntry(:key, :value) in scalars.entries) {
      if (!supportedScalarTypes.contains(value)) {
        throw CodegenException(
          'Scalar "$key" maps to "$value"; use one of '
          '${supportedScalarTypes.join(', ')}',
        );
      }
    }
    return scalars;
  }

  /// The Dart type of [type], e.g. `List<String?>?`.
  String dartType(TypeNode type, {ObjectClassNamer? objectClass}) {
    final base = switch (type) {
      ListTypeNode(type: final of) =>
        'List<${dartType(of, objectClass: objectClass)}>',
      NamedTypeNode(:final name) => _namedType(name.value, objectClass),
      _ => throw UnsupportedError('Unknown type node $type'),
    };
    return type.isNonNull ? base : '$base?';
  }

  /// An expression converting the JSON value [source] to [type].
  String fromJson(
    TypeNode type,
    String source, {
    ObjectClassNamer? objectClass,
    int depth = 0,
  }) {
    if (type case NamedTypeNode(:final name, isNonNull: false)) {
      if (_nullableScalarFromJson(name.value, source) case final simple?) {
        return simple;
      }
    }
    final value = switch (type) {
      ListTypeNode(type: final of) => '($source as List).map((e$depth) => '
          '${fromJson(of, 'e$depth', objectClass: objectClass, depth: depth + 1)})'
          '.toList()',
      NamedTypeNode(:final name) =>
        _namedFromJson(name.value, source, objectClass),
      _ => throw UnsupportedError('Unknown type node $type'),
    };
    return type.isNonNull ? value : '$source == null ? null : $value';
  }

  /// An expression converting the Dart value [source] of [type] to JSON.
  String toJson(TypeNode type, String source, {int depth = 0}) {
    if (_isIdentityToJson(type)) return source;
    final access = type.isNonNull ? '.' : '?.';
    return switch (type) {
      ListTypeNode(type: final of) => '$source${access}map((e$depth) => '
          '${toJson(of, 'e$depth', depth: depth + 1)}).toList()',
      NamedTypeNode(:final name) => _scalars[name.value] == 'DateTime'
          ? '$source${access}toIso8601String()'
          : '$source${access}toJson()',
      _ => throw UnsupportedError('Unknown type node $type'),
    };
  }

  /// Whether [name] is an enum type.
  bool isEnum(String name) => schema.type(name) is EnumTypeDefinitionNode;

  /// Whether [name] is an input object type.
  bool isInput(String name) =>
      schema.type(name) is InputObjectTypeDefinitionNode;

  String _namedType(String name, ObjectClassNamer? objectClass) {
    if (_scalarType(name) case final scalar?) return scalar;
    if (isEnum(name) || isInput(name)) return name;
    if (objectClass == null) {
      throw CodegenException('Type "$name" cannot be used here');
    }
    return objectClass(name);
  }

  String _namedFromJson(
    String name,
    String source,
    ObjectClassNamer? objectClass,
  ) =>
      switch (_scalarType(name)) {
        'String' => '$source as String',
        'int' => '($source as num).toInt()',
        'double' => '($source as num).toDouble()',
        'num' => '$source as num',
        'bool' => '$source as bool',
        'DateTime' => 'DateTime.parse($source as String)',
        'Object' => '$source as Object',
        _ when isEnum(name) => '$name.fromJson($source)',
        _ => '${_namedType(name, objectClass)}.fromJson($source as JsonMap)',
      };

  /// A direct cast for nullable scalars (`json['x'] as String?`), or null
  /// for types that need the `== null ? null :` form.
  String? _nullableScalarFromJson(String name, String source) =>
      switch (_scalarType(name)) {
        'String' => '$source as String?',
        'int' => '($source as num?)?.toInt()',
        'double' => '($source as num?)?.toDouble()',
        'num' => '$source as num?',
        'bool' => '$source as bool?',
        'Object' => '$source as Object?',
        _ => null,
      };

  /// The Dart type of a scalar named [name], or null if it is not one.
  String? _scalarType(String name) =>
      _scalars[name] ??
      (schema.type(name) is ScalarTypeDefinitionNode ? 'Object' : null);

  /// Scalars other than `DateTime` (and lists of them) are already JSON.
  bool _isIdentityToJson(TypeNode type) => switch (type) {
        ListTypeNode(type: final of) => _isIdentityToJson(of),
        NamedTypeNode(:final name) => switch (_scalarType(name.value)) {
            null || 'DateTime' => false,
            _ => true,
          },
        _ => throw UnsupportedError('Unknown type node $type'),
      };
}
