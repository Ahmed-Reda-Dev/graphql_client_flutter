import '../../../graphql_client_flutter.dart';

/// Utility class for transforming GraphQL queries
class QueryTransformer {

   // Add new validation method
  static void validateOrThrow(String query) {
    if (!isValidQuery(query)) {
      throw GraphQLException(
        message: 'Invalid GraphQL query',
        extensions: {'type': 'validation_error'},
      );
    }
  }

  // Add method to normalize queries
  static String normalize(String query) {
    return minify(query)
        .replaceAll(RegExp(r'\s*,\s*'), ',') // Normalize commas
        .replaceAll(RegExp(r'\s*:\s*'), ':') // Normalize colons
        .replaceAll(RegExp(r'\s*\(\s*'), '(') // Normalize parentheses
        .replaceAll(RegExp(r'\s*\)\s*'), ')');
  }
  /// Transforms a query by adding fields
  static String addFields(String query, List<String> fields) {
    final pattern = RegExp(r'{([^{}]*)}');
    return query.replaceAllMapped(pattern, (match) {
      final existingFields = match.group(1)?.trim() ?? '';
      final newFields = fields.join('\n  ');
      return '{\n  $existingFields\n  $newFields\n}';
    });
  }

  /// Gets operation name from a query
  static String? getOperationName(String query) {
    final matches =
        RegExp(r'(query|mutation|subscription)\s+(\w+)').firstMatch(query);
    return matches?.group(2);
  }

  /// Gets operation type (query/mutation/subscription)
  static String? getOperationType(String query) {
    final matches =
        RegExp(r'^(?:\s)*(query|mutation|subscription)').firstMatch(query);
    return matches?.group(1);
  }

  /// Validates query string
  static bool isValidQuery(String query) {
    try {
      if (query.trim().isEmpty) return false;

      // Check for required operation type
      if (!RegExp(r'(query|mutation|subscription)').hasMatch(query)) {
        return false;
      }

      // Check balanced braces
      int depth = 0;
      for (var char in query.split('')) {
        if (char == '{') depth++;
        if (char == '}') depth--;
        if (depth < 0) return false;
      }
      return depth == 0;
    } catch (e) {
      return false;
    }
  }

  /// Minifies query by removing whitespace and comments
  static String minify(String query) {
    return query
        .replaceAll(RegExp(r'#.*\n'), '') // Remove comments
        .replaceAll(RegExp(r'\s+'), ' ') // Collapse whitespace
        .trim();
  }

  /// Pretty prints a query with proper indentation
  static String prettyPrint(String query) {
    var indent = 0;
    var result = StringBuffer();
    var lines = query.split('\n');

    for (var line in lines) {
      line = line.trim();
      if (line.isEmpty) continue;

      if (line.contains('}')) indent--;
      result.writeln('  ' * indent + line);
      if (line.contains('{')) indent++;
    }

    return result.toString().trim();
  }

  /// Adds error handling fields to a query
  static String addErrorFields(String query) {
    const errorFields = '''
      errors {
        message
        locations {
          line
          column
        }
        path
        extensions
      }''';

    return query.replaceFirst(
      RegExp(r'{'),
      '{\n  $errorFields\n',
    );
  }

  /// Adds pagination fields to a query
  static String addPaginationFields(
    String query, {
    bool hasNextPage = true,
    bool hasPreviousPage = true,
    bool totalCount = true,
  }) {
    final paginationFields = [
      if (hasNextPage) 'hasNextPage',
      if (hasPreviousPage) 'hasPreviousPage',
      if (totalCount) 'totalCount',
    ];

    return query.replaceAllMapped(
      RegExp(r'{([^{}]*)}'),
      (match) {
        final existingFields = match.group(1)?.trim() ?? '';
        final pageInfoFields = paginationFields.join('\n    ');
        return '{\n  $existingFields\n  pageInfo {\n    $pageInfoFields\n  }\n}';
      },
    );
  }

  /// Extracts variables from query
  static List<String> extractVariables(String query) {
    final pattern = RegExp(r'\$(\w+):\s*([!\[\]\w]+)');
    return pattern.allMatches(query).map((m) => m.group(1)!).toList();
  }
}
