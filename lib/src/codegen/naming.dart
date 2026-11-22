/// Turns GraphQL names into Dart identifiers.
abstract final class Naming {
  /// `get_user`, `getUser` or `GET_USER` → `GetUser`.
  static String pascal(String name) {
    final camel = Naming.camel(name);
    return camel.isEmpty ? camel : camel[0].toUpperCase() + camel.substring(1);
  }

  /// `SUPER_USER` → `superUser`, `GetUser` → `getUser`, `avatarUrl` stays.
  static String camel(String name) {
    final words = name.split('_').where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return name;
    final allCaps = !name.contains(RegExp('[a-z]'));
    final buffer = StringBuffer();
    for (final (i, word) in words.indexed) {
      final w = allCaps ? word.toLowerCase() : word;
      buffer.write(i == 0
          ? w[0].toLowerCase() + w.substring(1)
          : w[0].toUpperCase() + w.substring(1));
    }
    return buffer.toString();
  }

  /// [name] as a Dart member name: keywords get a `$` suffix.
  static String member(String name) {
    final camel = Naming.camel(name);
    return _reserved.contains(camel) ? '$camel\$' : camel;
  }

  /// A Dart string literal for [value].
  static String literal(String value) =>
      "'${value.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll(r'$', r'\$')}'";

  static const _reserved = {
    'abstract', 'as', 'assert', 'async', 'await', 'base', 'break', 'case', //
    'catch', 'class', 'const', 'continue', 'covariant', 'default', 'deferred',
    'do', 'dynamic', 'else', 'enum', 'export', 'extends', 'extension',
    'external', 'factory', 'false', 'final', 'finally', 'for', 'Function',
    'get', 'hide', 'if', 'implements', 'import', 'in', 'interface', 'is',
    'late', 'library', 'mixin', 'new', 'null', 'of', 'on', 'operator', 'part',
    'required', 'rethrow', 'return', 'sealed', 'set', 'show', 'static',
    'super', 'switch', 'sync', 'this', 'throw', 'true', 'try', 'type',
    'typedef', 'var', 'void', 'when', 'while', 'with', 'yield',
    // Members every generated class has.
    'hashCode', 'runtimeType', 'toString', 'toJson', 'fromJson', 'values',
  };
}
