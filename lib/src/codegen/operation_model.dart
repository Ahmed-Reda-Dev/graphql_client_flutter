import 'package:gql/ast.dart';

import 'codegen_exception.dart';
import 'naming.dart';
import 'schema_index.dart';
import 'schema_types_writer.dart' show baseName, nullable;

/// A generated data class: the fields one selection set picks from one
/// GraphQL type.
final class ClassModel {
  /// Creates a class model.
  ClassModel({
    required this.name,
    required this.typeName,
    required this.fields,
  });

  /// The Dart class name, e.g. `GetUserData$User`.
  final String name;

  /// The GraphQL type the selection is on, e.g. `User`.
  final String typeName;

  /// The selected fields, in document order.
  final List<FieldModel> fields;
}

/// One field of a [ClassModel].
final class FieldModel {
  /// Creates a field model.
  FieldModel({
    required this.responseKey,
    required this.dartName,
    required this.type,
    this.selection,
    this.description,
  });

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
    final fields = <FieldModel>[];
    for (final MapEntry(key: responseKey, value: group)
        in _collectFields(typeName, selectionSets).entries) {
      final first = group.first;
      final fieldName = first.node.name.value;
      if (fieldName == '__typename') continue; // Constant per class.

      final definition = schema.field(typeName, fieldName);
      if (definition == null) {
        throw CodegenException(
          'Type "$typeName" has no field "$fieldName"',
          first.node.name.span ?? first.node.span,
        );
      }
      var type = definition.type;
      if (group.every((f) => f.conditional)) type = nullable(type);

      ClassModel? selection;
      final subSelections = [
        for (final f in group)
          if (f.node.selectionSet case final set?) set,
      ];
      final fieldType = baseName(type);
      if (subSelections.isNotEmpty) {
        selection = _buildClass(
          '$className\$${Naming.pascal(responseKey)}',
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
        description: definition.description?.value,
      ));
    }
    final model =
        ClassModel(name: className, typeName: typeName, fields: fields);
    classes.add(model);
    return model;
  }

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
            if (_applies(on, typeName, selection)) {
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
            if (_applies(
              fragment.typeCondition.on.name.value,
              typeName,
              selection,
            )) {
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

  /// Whether a fragment on [condition] always applies to an object of
  /// [typeName]: the same type, or an interface or union it belongs to.
  bool _applies(String condition, String typeName, Node at) {
    if (condition == typeName) return true;
    if (schema.possibleTypes(condition).contains(typeName)) return true;
    if (schema.isAbstract(typeName)) {
      throw CodegenException(
        'Fragments on "$condition" inside "$typeName" are not supported yet',
        at.span,
      );
    }
    return false; // A fragment on another concrete type never applies.
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
