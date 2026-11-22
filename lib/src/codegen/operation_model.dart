import 'package:gql/ast.dart';
import 'package:gql/language.dart' show printNode;

import 'codegen_exception.dart';
import 'naming.dart';
import 'schema_index.dart';
import 'schema_types_writer.dart' show baseName, nullable;

/// A generated data class: the fields one selection set picks from one
/// GraphQL type.
///
/// A selection on a union or interface that has type-specific fragments
/// becomes a sealed class ([variants] non-empty) with one subclass per
/// targeted type, plus one for any other type.
final class ClassModel {
  /// Creates a class model.
  ClassModel({
    required this.name,
    required this.typeName,
    required this.fields,
    this.variants = const [],
    this.superclass,
    this.keepsTypename = false,
  });

  /// The Dart class name, e.g. `GetUserData$User`.
  final String name;

  /// The GraphQL type the selection is on, e.g. `User`.
  final String typeName;

  /// The selected fields, in document order. For a sealed class: the
  /// fields every variant has, with the same Dart type.
  final List<FieldModel> fields;

  /// For a sealed class: its subclasses, the fallback one last.
  final List<ClassModel> variants;

  /// For a variant: the sealed class it extends.
  final String? superclass;

  /// Whether the concrete `__typename` is only known at runtime, so the
  /// class stores it (a union/interface without variants, or the fallback
  /// variant).
  final bool keepsTypename;

  /// Whether this is a sealed class.
  bool get isSealed => variants.isNotEmpty;
}

/// One field of a [ClassModel].
final class FieldModel {
  /// Creates a field model.
  FieldModel({
    required this.responseKey,
    required this.dartName,
    required this.type,
    this.selection,
    this.selectionSets = const [],
    this.description,
  });

  /// The selection sets merged into [selection].
  final List<SelectionSetNode> selectionSets;

  /// The field's description in the schema.
  final String? description;

  /// The key in the JSON response (the alias, if any).
  final String responseKey;

  /// The Dart member name.
  final String dartName;

  /// The field's type, made nullable when `@include`/`@skip` may drop it.
  final TypeNode type;

  /// The class for an object field's sub-selection.
  final ClassModel? selection;
}

/// An operation ready to generate: its data classes and variables.
final class OperationModel {
  /// Creates an operation model.
  OperationModel({
    required this.node,
    required this.name,
    required this.data,
    required this.classes,
  });

  /// The operation in the document.
  final OperationDefinitionNode node;

  /// The operation name, e.g. `GetUser`.
  final String name;

  /// The class for the whole `data` object.
  final ClassModel data;

  /// Every data class, nested ones first.
  final List<ClassModel> classes;
}

/// Builds [OperationModel]s from operations, checking every field against
/// the schema.
final class OperationModelBuilder {
  /// Creates a builder. [fragments] are all fragment definitions, from
  /// every document, by name.
  OperationModelBuilder(this.schema, this.fragments);

  /// The schema to check against.
  final SchemaIndex schema;

  /// Fragment definitions by name.
  final Map<String, FragmentDefinitionNode> fragments;

  /// Enum types the built operations select (to generate them).
  final usedEnums = <String>{};

  /// Builds the model for [operation].
  OperationModel build(OperationDefinitionNode operation) {
    final name = operation.name?.value;
    if (name == null) {
      throw CodegenException(
        'Name this operation (e.g. `query GetUser { ... }`): generated '
        'classes and methods are named after it',
        operation.span,
      );
    }
    final root = schema.rootType(operation.type);
    if (root == null) {
      throw CodegenException(
        'The schema has no ${operation.type.name} type',
        operation.span,
      );
    }
    final classes = <ClassModel>[];
    final data = _buildClass(
      '${Naming.pascal(name)}Data',
      root.name.value,
      [operation.selectionSet],
      classes,
    );
    final names = <String>{};
    for (final model in classes) {
      if (!names.add(model.name)) {
        throw CodegenException(
          'Two generated classes would both be named ${model.name}; '
          'alias one of the fields',
          operation.span,
        );
      }
    }
    return OperationModel(
      node: operation,
      name: name,
      data: data,
      classes: classes,
    );
  }

  /// Builds the class for [selectionSets] (merged) on [typeName], adding it
  /// and its nested classes to [classes].
  ClassModel _buildClass(
    String className,
    String typeName,
    List<SelectionSetNode> selectionSets,
    List<ClassModel> classes,
  ) {
    if (!schema.isAbstract(typeName)) {
      return _buildObject(className, typeName, selectionSets, classes);
    }
    final targets = _targetedTypes(typeName, selectionSets);
    if (targets.isEmpty) {
      return _buildObject(className, typeName, selectionSets, classes,
          keepsTypename: true);
    }

    // The fallback holds the fields every type has; variants reuse its
    // nested classes where their selection is the same, so shared fields
    // keep one Dart type.
    final fallbackName = targets.contains('Unknown')
        ? '$className\$UnknownType'
        : '$className\$Unknown';
    final fallback = _buildObject(
        fallbackName, typeName, selectionSets, classes,
        keepsTypename: true, superclass: className, nestedPrefix: className);
    final variants = [
      for (final target in targets.toList()..sort())
        _buildObject('$className\$$target', target, selectionSets, classes,
            superclass: className, reuse: fallback),
      fallback,
    ];
    final shared = [
      for (final field in fallback.fields)
        if (variants.every((v) => v.fields.any(
            (f) => f.responseKey == field.responseKey && _sameType(f, field))))
          field,
    ];
    final model = ClassModel(
      name: className,
      typeName: typeName,
      fields: shared,
      variants: variants,
    );
    classes.add(model);
    return model;
  }

  /// Builds a plain class for [selectionSets] on [typeName]. Fields whose
  /// selection matches one in [reuse] use its nested class.
  ClassModel _buildObject(
    String className,
    String typeName,
    List<SelectionSetNode> selectionSets,
    List<ClassModel> classes, {
    bool keepsTypename = false,
    String? superclass,
    ClassModel? reuse,
    String? nestedPrefix,
  }) {
    final fields = <FieldModel>[];
    for (final MapEntry(key: responseKey, value: group)
        in _collectFields(typeName, selectionSets).entries) {
      final first = group.first;
      final fieldName = first.node.name.value;
      if (fieldName == '__typename') continue; // Known, or kept separately.

      final definition = schema.field(typeName, fieldName);
      if (definition == null) {
        throw CodegenException(
          'Type "$typeName" has no field "$fieldName"',
          first.node.name.span ?? first.node.span,
        );
      }
      var type = definition.type;
      if (group.every((f) => f.conditional)) type = nullable(type);

      final subSelections = [
        for (final f in group)
          if (f.node.selectionSet case final set?) set,
      ];
      final fieldType = baseName(type);
      ClassModel? selection;
      if (subSelections.isNotEmpty) {
        final reused = reuse?.fields
            .where((f) => f.responseKey == responseKey)
            .firstOrNull;
        selection = reused?.selection != null &&
                _sameNodes(reused!.selectionSets, subSelections)
            ? reused.selection
            : _buildClass(
                '${nestedPrefix ?? className}\$${Naming.pascal(responseKey)}',
                fieldType,
                subSelections,
                classes,
              );
      } else if (schema.type(fieldType)
          case ObjectTypeDefinitionNode() ||
              InterfaceTypeDefinitionNode() ||
              UnionTypeDefinitionNode()) {
        throw CodegenException(
          'Select fields of "$fieldName" (type $fieldType)',
          first.node.span,
        );
      } else if (schema.type(fieldType) is EnumTypeDefinitionNode) {
        usedEnums.add(fieldType);
      }
      fields.add(FieldModel(
        responseKey: responseKey,
        dartName: Naming.member(responseKey),
        type: type,
        selection: selection,
        selectionSets: subSelections,
        description: definition.description?.value,
      ));
    }
    final model = ClassModel(
      name: className,
      typeName: typeName,
      fields: fields,
      superclass: superclass,
      keepsTypename: keepsTypename,
    );
    classes.add(model);
    return model;
  }

  /// The concrete types of [typeName] that fragments in [selectionSets]
  /// single out (a fragment on the type itself, or on an interface it
  /// implements other than [typeName]).
  Set<String> _targetedTypes(
    String typeName,
    List<SelectionSetNode> selectionSets,
  ) {
    final possible = schema.possibleTypes(typeName);
    final targets = <String>{};
    void visit(SelectionSetNode set) {
      for (final selection in set.selections) {
        final (condition, inner) = switch (selection) {
          InlineFragmentNode(:final typeCondition, :final selectionSet) => (
              typeCondition?.on.name.value,
              selectionSet,
            ),
          FragmentSpreadNode(:final name) => (
              fragments[name.value]?.typeCondition.on.name.value,
              fragments[name.value]?.selectionSet,
            ),
          _ => (null, null),
        };
        if (inner == null) continue;
        if (condition != null && !_applies(condition, typeName)) {
          targets.addAll(condition == typeName
              ? const {}
              : schema.isAbstract(condition)
                  ? schema.possibleTypes(condition).intersection(possible)
                  : possible.intersection({condition}));
        }
        visit(inner);
      }
    }

    selectionSets.forEach(visit);
    return targets;
  }

  /// Whether [a] and [b] have the same Dart type (same schema type, and the
  /// same nested class for object fields).
  static bool _sameType(FieldModel a, FieldModel b) =>
      identical(a.selection, b.selection) &&
      printNode(a.type) == printNode(b.type);

  static bool _sameNodes(List<SelectionSetNode> a, List<SelectionSetNode> b) =>
      a.length == b.length &&
      [for (var i = 0; i < a.length; i++) identical(a[i], b[i])]
          .every((same) => same);

  /// The fields [selectionSets] select on [typeName], grouped by response
  /// key in document order, with fragments flattened.
  Map<String, List<_CollectedField>> _collectFields(
    String typeName,
    List<SelectionSetNode> selectionSets,
  ) {
    final fields = <String, List<_CollectedField>>{};
    void collect(SelectionSetNode set, {required bool conditional}) {
      for (final selection in set.selections) {
        final isConditional = conditional || _isConditional(selection);
        switch (selection) {
          case FieldNode():
            final key = (selection.alias ?? selection.name).value;
            (fields[key] ??= []).add(_CollectedField(selection, isConditional));
          case InlineFragmentNode(:final typeCondition, :final selectionSet):
            final on = typeCondition?.on.name.value ?? typeName;
            if (_applies(on, typeName)) {
              collect(selectionSet, conditional: isConditional);
            }
          case FragmentSpreadNode(:final name):
            final fragment = fragments[name.value];
            if (fragment == null) {
              throw CodegenException(
                'Unknown fragment "${name.value}"',
                selection.span,
              );
            }
            if (_applies(fragment.typeCondition.on.name.value, typeName)) {
              collect(fragment.selectionSet, conditional: isConditional);
            }
          default:
            break;
        }
      }
    }

    for (final set in selectionSets) {
      collect(set, conditional: false);
    }
    return fields;
  }

  /// Whether a fragment on [condition] applies to every object of
  /// [typeName]: the same type, or a union/interface covering all of its
  /// possible types.
  bool _applies(String condition, String typeName) {
    if (condition == typeName) return true;
    final covers = schema.possibleTypes(condition);
    if (!schema.isAbstract(typeName)) return covers.contains(typeName);
    return covers.containsAll(schema.possibleTypes(typeName));
  }

  static bool _isConditional(SelectionNode selection) {
    final directives = switch (selection) {
      FieldNode(:final directives) ||
      InlineFragmentNode(:final directives) ||
      FragmentSpreadNode(:final directives) =>
        directives,
      _ => const <DirectiveNode>[],
    };
    return directives
        .any((d) => d.name.value == 'include' || d.name.value == 'skip');
  }
}

final class _CollectedField {
  _CollectedField(this.node, this.conditional);

  final FieldNode node;

  /// Whether `@include`/`@skip` (here or on an enclosing fragment) may drop
  /// it.
  final bool conditional;
}
