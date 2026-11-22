import 'naming.dart';
import 'operation_model.dart';
import 'schema_types_writer.dart' show writeDoc;
import 'type_mapper.dart';

/// Writes the Dart data classes of an operation.
final class DataClassWriter {
  /// Creates a writer using [mapper] for field types.
  DataClassWriter(this.mapper);

  /// Converts types.
  final TypeMapper mapper;

  /// The Dart source of [classes].
  String write(Iterable<ClassModel> classes) {
    final out = StringBuffer();
    for (final model in classes) {
      _writeClass(out, model);
    }
    return out.toString();
  }

  void _writeClass(StringBuffer out, ClassModel model) {
    final name = model.name;
    out
      ..writeln('/// Fields selected on `${model.typeName}`.')
      ..writeln('final class $name {')
      ..writeln('  /// Creates the data, e.g. for an optimistic response.')
      ..write('  const $name(');
    if (model.fields.isNotEmpty) {
      out
        ..write('{')
        ..writeAll([
          for (final f in model.fields)
            f.type.isNonNull
                ? 'required this.${f.dartName}'
                : 'this.${f.dartName}',
        ], ', ')
        ..write(',}');
    }
    out
      ..writeln(');')
      ..writeln()
      ..writeln('  /// Reads the data from a JSON response.')
      ..writeln('  factory $name.fromJson(JsonMap json) => $name(');
    for (final f in model.fields) {
      final source = 'json[${Naming.literal(f.responseKey)}]';
      out.writeln('        ${f.dartName}: '
          '${mapper.fromJson(f.type, source, objectClass: _namer(f))},');
    }
    out
      ..writeln('      );')
      ..writeln();
    for (final f in model.fields) {
      writeDoc(out, f.description ?? 'The `${f.responseKey}` field.');
      out.writeln(
          '  final ${mapper.dartType(f.type, objectClass: _namer(f))} ${f.dartName};');
      out.writeln();
    }
    out
      ..writeln('  /// This data as JSON, with `__typename`, so it can be '
          'written to the cache.')
      ..writeln('  JsonMap toJson() => {')
      ..writeln("        '__typename': ${Naming.literal(model.typeName)},");
    for (final f in model.fields) {
      out.writeln('        ${Naming.literal(f.responseKey)}: '
          '${mapper.toJson(f.type, f.dartName)},');
    }
    out
      ..writeln('      };')
      ..writeln('}')
      ..writeln();
  }

  /// Names the class of [field]'s sub-selection.
  static ObjectClassNamer? _namer(FieldModel field) {
    final selection = field.selection;
    return selection == null ? null : (_) => selection.name;
  }
}
