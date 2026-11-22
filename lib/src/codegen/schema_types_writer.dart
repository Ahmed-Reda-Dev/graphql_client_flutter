import 'package:gql/ast.dart';

import 'naming.dart';
import 'type_mapper.dart';

/// Writes the Dart enums and input classes that operations share.
final class SchemaTypesWriter {
  /// Creates a writer over [mapper]'s schema.
  SchemaTypesWriter(this.mapper);

  /// Converts types.
  final TypeMapper mapper;

  /// Enum and input type names reachable from [typeNames] (e.g. the types
  /// of operation variables and selected enum fields), including the
  /// fields of input types, recursively.
  Set<String> reachable(Iterable<String> typeNames) {
    final found = <String>{};
    void visit(String name) {
      if (!found.add(name)) return;
      if (mapper.schema.type(name)
          case InputObjectTypeDefinitionNode(
            :final fields,
          )) {
        for (final field in fields) {
          visit(baseName(field.type));
        }
      }
    }

    typeNames.forEach(visit);
    return {
      for (final name in found)
        if (mapper.isEnum(name) || mapper.isInput(name)) name,
    };
  }

  /// The Dart source declaring [typeNames] (enums and inputs), sorted by
  /// name so the output is stable.
  String write(Iterable<String> typeNames) {
    final buffer = StringBuffer();
    for (final name in typeNames.toList()..sort()) {
      switch (mapper.schema.type(name)) {
        case final EnumTypeDefinitionNode type:
          _writeEnum(buffer, type);
        case final InputObjectTypeDefinitionNode type:
          _writeInput(buffer, type);
        default:
          break;
      }
    }
    return buffer.toString();
  }

  void _writeEnum(StringBuffer out, EnumTypeDefinitionNode type) {
    final name = type.name.value;
    writeDoc(out, type.description?.value);
    out.writeln('enum $name {');
    for (final value in type.values) {
      writeDoc(out, value.description?.value);
      out.writeln('${_enumValue(value.name.value)}'
          '(${Naming.literal(value.name.value)}),');
    }
    out
      ..writeln()
      ..writeln('  /// A value added to the schema after this code was '
          'generated.')
      ..writeln(r'  $unknown(null);')
      ..writeln()
      ..writeln('  const $name(this.value);')
      ..writeln()
      ..writeln('  /// The value as named in the schema.')
      ..writeln('  final String? value;')
      ..writeln()
      ..writeln('  /// The value for [json], or [\$unknown].')
      ..writeln('  static $name fromJson(Object? json) => values.firstWhere(')
      ..writeln('        (v) => v.value == json,')
      ..writeln('        orElse: () => $name.\$unknown,')
      ..writeln('      );')
      ..writeln()
      ..writeln('  /// The schema name. [\$unknown] cannot be sent.')
      ..writeln('  String toJson() =>')
      ..writeln('      value ?? (throw StateError('
          "'$name.\\\$unknown cannot be sent to the server'));")
      ..writeln('}')
      ..writeln();
  }

  void _writeInput(StringBuffer out, InputObjectTypeDefinitionNode type) {
    final name = type.name.value;
    final fields = [
      for (final field in type.fields)
        (
          node: field,
          dart: Naming.member(field.name.value),
          required: field.type.isNonNull && field.defaultValue == null,
        ),
    ];

    writeDoc(out, type.description?.value);
    out
      ..writeln('final class $name {')
      ..writeln('  /// Creates the input.')
      ..write('  const $name(')
      ..write(fields.isEmpty ? '' : '{')
      ..writeAll([
        for (final f in fields)
          f.required ? 'required this.${f.dart}' : 'this.${f.dart}',
      ], ', ')
      ..writeln(fields.isEmpty ? ');' : ',});')
      ..writeln();
    for (final f in fields) {
      writeDoc(
          out,
          f.node.description?.value ??
              'The `${f.node.name.value}` '
                  'field.');
      final type = f.required ? f.node.type : nullable(f.node.type);
      out.writeln('  final ${mapper.dartType(type)} ${f.dart};');
    }
    out
      ..writeln()
      ..writeln('  /// This input as JSON. Unset optional fields are left out.')
      ..writeln('  JsonMap toJson() => {');
    for (final f in fields) {
      final key = Naming.literal(f.node.name.value);
      final nonNull = nonNullable(f.node.type);
      if (f.required) {
        out.writeln('        $key: ${mapper.toJson(nonNull, f.dart)},');
      } else {
        out.writeln('        if (${f.dart} case final ${f.dart}?) '
            '$key: ${mapper.toJson(nonNull, f.dart)},');
      }
    }
    out
      ..writeln('      };')
      ..writeln('}')
      ..writeln();
  }

  /// Dart enums already have `index`, `name` and `values`, and generated
  /// ones add `value`.
  static String _enumValue(String name) {
    final member = Naming.member(name);
    return const {'index', 'name', 'values', 'value'}.contains(member)
        ? '$member\$'
        : member;
  }
}

/// The named type at the bottom of [type] (`[User!]!` → `User`).
String baseName(TypeNode type) => switch (type) {
      ListTypeNode(type: final of) => baseName(of),
      NamedTypeNode(:final name) => name.value,
      _ => throw UnsupportedError('Unknown type node $type'),
    };

/// [type] made nullable at the top level.
TypeNode nullable(TypeNode type) => switch (type) {
      ListTypeNode(type: final of) => ListTypeNode(type: of, isNonNull: false),
      NamedTypeNode(:final name) => NamedTypeNode(name: name, isNonNull: false),
      _ => throw UnsupportedError('Unknown type node $type'),
    };

/// [type] made non-null at the top level.
TypeNode nonNullable(TypeNode type) => switch (type) {
      ListTypeNode(type: final of) => ListTypeNode(type: of, isNonNull: true),
      NamedTypeNode(:final name) => NamedTypeNode(name: name, isNonNull: true),
      _ => throw UnsupportedError('Unknown type node $type'),
    };

/// Writes [text] as a `///` comment, if any.
void writeDoc(StringBuffer out, String? text) {
  if (text == null || text.trim().isEmpty) return;
  for (final line in text.trim().split('\n')) {
    out.writeln('  /// ${line.trim()}'.trimRight());
  }
}
