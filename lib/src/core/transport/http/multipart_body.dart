import 'dart:convert';

import 'package:dio/dio.dart';

import '../../json.dart';
import '../../request/graphql_request.dart';

/// Encodes requests with file variables as a
/// [GraphQL multipart request](https://github.com/jaydenseric/graphql-multipart-request-spec).
abstract final class MultipartBody {
  /// Whether [variables] contain any [MultipartFile], at any depth.
  static bool hasFiles(Object? variables) => switch (variables) {
        MultipartFile() => true,
        final Map<dynamic, dynamic> map => map.values.any(hasFiles),
        final List<dynamic> list => list.any(hasFiles),
        _ => false,
      };

  /// Builds the multipart form: `operations` (files replaced by null),
  /// `map` (file index to variable paths) and one field per file.
  static FormData encode(GraphQLRequest request) {
    final files = <MultipartFile>[];
    final paths = <String, List<String>>{};

    Object? strip(Object? value, String path) {
      switch (value) {
        case MultipartFile():
          paths['${files.length}'] = [path];
          files.add(value);
          return null;
        case final Map<dynamic, dynamic> map:
          return {
            for (final MapEntry(:key, :value) in map.entries)
              '$key': strip(value, '$path.$key'),
          };
        case final List<dynamic> list:
          return [
            for (var i = 0; i < list.length; i++) strip(list[i], '$path.$i'),
          ];
        default:
          return value;
      }
    }

    final variables = strip(request.variables, 'variables') as JsonMap;
    final operations = request.withVariables(variables).toJson();

    return FormData.fromMap({
      'operations': jsonEncode(operations),
      'map': jsonEncode(paths),
      for (var i = 0; i < files.length; i++) '$i': files[i],
    });
  }
}
