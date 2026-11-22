import 'dart:convert';
import 'dart:io';

import '../core/json.dart';
import 'codegen_exception.dart';

/// The standard introspection query: everything needed to rebuild the
/// schema as SDL.
const introspectionQuery = r'''
query IntrospectionQuery {
  __schema {
    queryType { name }
    mutationType { name }
    subscriptionType { name }
    types { ...FullType }
  }
}
fragment FullType on __Type {
  kind name description
  fields(includeDeprecated: true) {
    name description isDeprecated deprecationReason
    args { ...InputValue }
    type { ...TypeRef }
  }
  inputFields { ...InputValue }
  interfaces { ...TypeRef }
  enumValues(includeDeprecated: true) {
    name description isDeprecated deprecationReason
  }
  possibleTypes { ...TypeRef }
}
fragment InputValue on __InputValue {
  name description defaultValue
  type { ...TypeRef }
}
fragment TypeRef on __Type {
  kind name
  ofType { kind name ofType { kind name ofType { kind name ofType {
    kind name ofType { kind name ofType { kind name ofType { kind name } } }
  } } } }
}''';

/// Asks the server at [url] for its schema and returns it as SDL.
///
/// [headers] are sent as they are (e.g. `Authorization`). Throws a
/// [CodegenException] when the server cannot be reached, answers with an
/// error, or has introspection disabled.
Future<String> downloadSchema(
  Uri url, {
  Map<String, String> headers = const {},
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final request = await client.postUrl(url);
    request.headers.contentType = ContentType.json;
    headers.forEach(request.headers.set);
    request.write(jsonEncode({'query': introspectionQuery}));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    final Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      throw CodegenException(
        '$url answered HTTP ${response.statusCode} without a GraphQL '
        'response; is this the GraphQL endpoint?',
      );
    }
    final data = json is JsonMap ? json['data'] : null;
    if (data is! JsonMap || data['__schema'] == null) {
      final errors = json is JsonMap ? json['errors'] : null;
      throw CodegenException(
        'Could not read the schema from $url (HTTP ${response.statusCode})'
        '${errors is List ? ': ${errors.map((e) => e is JsonMap ? e['message'] : e).join('; ')}' : ''}. '
        'The server may have introspection disabled, or need --header '
        '"Authorization: ...".',
      );
    }
    return introspectionToSdl(data);
  } on SocketException catch (e) {
    throw CodegenException('Could not reach $url: ${e.message}');
  } on HttpException catch (e) {
    throw CodegenException('Could not reach $url: ${e.message}');
  } finally {
    client.close(force: true);
  }
}

/// Converts the `data` of an [introspectionQuery] response to SDL, with
/// types sorted by name so a changed schema gives a readable diff.
String introspectionToSdl(JsonMap data) {
  final schema = data['__schema'];
  if (schema is! JsonMap) {
    throw const CodegenException('Not an introspection result (no __schema)');
  }
  final out = StringBuffer();
  String? rootName(String key) => (schema[key] as JsonMap?)?['name'] as String?;
  final roots = {
    'query': rootName('queryType'),
    'mutation': rootName('mutationType'),
    'subscription': rootName('subscriptionType'),
  };
  final defaults = {
    'query': 'Query',
    'mutation': 'Mutation',
    'subscription': 'Subscription',
  };
  if (roots.entries.any((r) => r.value != null && r.value != defaults[r.key])) {
    out.writeln('schema {');
    for (final MapEntry(:key, :value) in roots.entries) {
      if (value != null) out.writeln('  $key: $value');
    }
    out
      ..writeln('}')
      ..writeln();
  }

  final types = [
    for (final type in (schema['types'] as List).whereType<JsonMap>())
      if (!(type['name'] as String).startsWith('__') &&
          !_builtInScalars.contains(type['name']))
        type,
  ]..sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
  for (final type in types) {
    _writeType(out, type);
    out.writeln();
  }
  return out.toString();
}

const _builtInScalars = {'String', 'Int', 'Float', 'Boolean', 'ID'};

void _writeType(StringBuffer out, JsonMap type) {
  final name = type['name'] as String;
  _description(out, type['description'], '');
  switch (type['kind']) {
    case 'SCALAR':
      out.writeln('scalar $name');
    case 'OBJECT' || 'INTERFACE':
      final keyword = type['kind'] == 'OBJECT' ? 'type' : 'interface';
      final interfaces = [
        for (final i in (type['interfaces'] as List?) ?? const [])
          (i as JsonMap)['name'],
      ];
      out.writeln('$keyword $name'
          '${interfaces.isEmpty ? '' : ' implements ${interfaces.join(' & ')}'} {');
      for (final field in (type['fields'] as List?) ?? const []) {
        _writeField(out, field as JsonMap);
      }
      out.writeln('}');
    case 'UNION':
      final members = [
        for (final t in (type['possibleTypes'] as List?) ?? const [])
          (t as JsonMap)['name'],
      ];
      out.writeln('union $name = ${members.join(' | ')}');
    case 'ENUM':
      out.writeln('enum $name {');
      for (final value in (type['enumValues'] as List?) ?? const []) {
        final v = value as JsonMap;
        _description(out, v['description'], '  ');
        out.writeln('  ${v['name']}${_deprecated(v)}');
      }
      out.writeln('}');
    case 'INPUT_OBJECT':
      out.writeln('input $name {');
      for (final field in (type['inputFields'] as List?) ?? const []) {
        final f = field as JsonMap;
        _description(out, f['description'], '  ');
        out.writeln('  ${_inputValue(f)}');
      }
      out.writeln('}');
  }
}

void _writeField(StringBuffer out, JsonMap field) {
  _description(out, field['description'], '  ');
  final args = [
    for (final arg in (field['args'] as List?) ?? const [])
      _inputValue(arg as JsonMap),
  ];
  out.writeln('  ${field['name']}'
      '${args.isEmpty ? '' : '(${args.join(', ')})'}'
      ': ${_typeRef(field['type'] as JsonMap)}${_deprecated(field)}');
}

String _inputValue(JsonMap value) {
  final defaultValue = value['defaultValue'];
  return '${value['name']}: ${_typeRef(value['type'] as JsonMap)}'
      '${defaultValue == null ? '' : ' = $defaultValue'}';
}

String _typeRef(JsonMap type) => switch (type['kind']) {
      'NON_NULL' => '${_typeRef(type['ofType'] as JsonMap)}!',
      'LIST' => '[${_typeRef(type['ofType'] as JsonMap)}]',
      _ => type['name'] as String,
    };

String _deprecated(JsonMap member) {
  if (member['isDeprecated'] != true) return '';
  final reason = member['deprecationReason'];
  return reason is String && reason.isNotEmpty
      ? ' @deprecated(reason: ${jsonEncode(reason)})'
      : ' @deprecated';
}

void _description(StringBuffer out, Object? description, String indent) {
  if (description is! String || description.trim().isEmpty) return;
  final text = description.trim().replaceAll('"""', r'\"""');
  out.writeln('$indent"""');
  for (final line in text.split('\n')) {
    out.writeln('$indent$line'.trimRight());
  }
  out.writeln('$indent"""');
}
