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
    final sealed = {
      for (final model in classes)
        if (model.isSealed) model.name: model,
    };
    for (final model in classes) {
      if (model.isSealed) {
        _writeSealed(out, model);
      } else {
        _writeClass(out, model, sealed[model.superclass]);
      }
    }
    return out.toString();
  }

  /// A sealed class: `fromJson` picks the variant by `__typename`.
  void _writeSealed(StringBuffer out, ClassModel model) {
    final name = model.name;
    out
      ..writeln('/// One of the types `${model.typeName}` can be: switch on '
          'it to handle each.')
      ..writeln('sealed class $name {')
      ..writeln('  const $name();')
      ..writeln()
      ..writeln('  /// Reads the variant named by `__typename`.')
      ..writeln('  factory $name.fromJson(JsonMap json) =>')
      ..writeln("      switch (json['__typename']) {");
    for (final variant in model.variants) {
      final pattern =
          variant.keepsTypename ? '_' : Naming.literal(variant.typeName);
      out.writeln('        $pattern => ${variant.name}.fromJson(json),');
    }
    out
      ..writeln('      };')
      ..writeln();
    for (final f in model.fields) {
      writeDoc(out, f.description ?? 'The `${f.responseKey}` field.');
      out
        ..writeln('  ${mapper.dartType(f.type, objectClass: _namer(f))} '
            'get ${f.dartName};')
        ..writeln();
    }
    out
      ..writeln('  /// This data as JSON, with `__typename`.')
      ..writeln('  JsonMap toJson();')
      ..writeln('}')
      ..writeln();
  }

  void _writeClass(StringBuffer out, ClassModel model, ClassModel? parent) {
    final name = model.name;
    final shared = {
      for (final f in parent?.fields ?? const <FieldModel>[]) f.responseKey,
    };
    final params = [
      if (model.keepsTypename) 'required this.typename',
      for (final f in model.fields)
        f.type.isNonNull ? 'required this.${f.dartName}' : 'this.${f.dartName}',
    ];
    out
      ..writeln('/// Fields selected on `${model.typeName}`.')
      ..writeln(parent == null
          ? 'final class $name {'
          : 'final class $name extends ${parent.name} {')
      ..writeln('  /// Creates the data, e.g. for an optimistic response.')
      ..write('  const $name(');
    if (params.isNotEmpty) {
      out
        ..write('{')
        ..writeAll(params, ', ')
        ..write(',}');
    }
    out
      ..writeln(');')
      ..writeln()
      ..writeln('  /// Reads the data from a JSON response.')
      ..writeln('  factory $name.fromJson(JsonMap json) => $name(');
    if (model.keepsTypename) {
      out.writeln("        typename: json['__typename'] as String,");
    }
    for (final f in model.fields) {
      final source = 'json[${Naming.literal(f.responseKey)}]';
      out.writeln('        ${f.dartName}: '
          '${mapper.fromJson(f.type, source, objectClass: _namer(f))},');
    }
    out
      ..writeln('      );')
      ..writeln();
    if (model.keepsTypename) {
      out
        ..writeln('  /// The concrete type, from `__typename`.')
        ..writeln('  final String typename;')
        ..writeln();
    }
    for (final f in model.fields) {
      writeDoc(out, f.description ?? 'The `${f.responseKey}` field.');
      if (shared.contains(f.responseKey)) out.writeln('  @override');
      out.writeln(
          '  final ${mapper.dartType(f.type, objectClass: _namer(f))} ${f.dartName};');
      out.writeln();
    }
    out
      ..writeln('  /// This data as JSON, with `__typename`, so it can be '
          'written to the cache.')
      ..writeln(parent == null ? '' : '  @override')
      ..writeln('  JsonMap toJson() => {')
      ..writeln("        '__typename': "
          "${model.keepsTypename ? 'typename' : Naming.literal(model.typeName)},");
    for (final f in model.fields) {
      out.writeln('        ${Naming.literal(f.responseKey)}: '
          '${mapper.toJson(f.type, f.dartName, data: true)},');
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
