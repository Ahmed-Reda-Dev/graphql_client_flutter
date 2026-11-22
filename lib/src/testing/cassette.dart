import 'dart:convert';

import 'package:collection/collection.dart';

import '../core/json.dart';
import '../core/request/graphql_request.dart';
import '../core/response/graphql_error.dart';
import '../core/response/graphql_exception.dart';
import '../core/response/graphql_response.dart';
import 'cassette_file_stub.dart' if (dart.library.io) 'cassette_file_io.dart'
    as file;

/// Recorded server answers, written by `RecordingTransport` and played back
/// by `ReplayTransport`.
///
/// Saved as readable JSON, so recordings can be committed next to the
/// tests and reviewed in diffs. Responses are stored as the server sent
/// them: review recordings for personal data before committing them.
final class Cassette {
  /// Creates a cassette holding [entries].
  Cassette([Iterable<CassetteEntry> entries = const []])
      : _entries = [...entries];

  /// Reads a cassette written by [toJson].
  ///
  /// Throws a [FormatException] if [json] is not a cassette in a format
  /// this version understands.
  factory Cassette.fromJson(JsonMap json) {
    final entries = json['entries'];
    if (json['version'] != _version || entries is! List) {
      throw const FormatException(
        'Not a version $_version cassette (expected {"version": $_version, '
        '"entries": [...]}); record it again',
      );
    }
    return Cassette([
      for (final entry in entries.whereType<JsonMap>())
        CassetteEntry.fromJson(entry),
    ]);
  }

  /// Reads the cassette saved at [path]. Not available on the web.
  static Future<Cassette> load(String path) async =>
      Cassette.fromJson(jsonDecode(await file.read(path)) as JsonMap);

  static const _version = 1;

  final List<CassetteEntry> _entries;

  /// The recorded answers, in the order they were recorded.
  List<CassetteEntry> get entries => UnmodifiableListView(_entries);

  /// Adds [entry].
  void add(CassetteEntry entry) => _entries.add(entry);

  /// This cassette as JSON.
  JsonMap toJson() => {
        'version': _version,
        'entries': [for (final entry in _entries) entry.toJson()],
      };

  /// Saves this cassette to [path] as indented JSON, creating missing
  /// folders. Not available on the web.
  Future<void> save(String path) => file.write(
        path,
        '${const JsonEncoder.withIndent('  ').convert(toJson())}\n',
      );
}

/// One recorded answer: the [response] to a query or mutation, the
/// [events] of a subscription, or the transport [error] it failed with.
final class CassetteEntry {
  /// Creates an entry. Exactly one of [response], [events] and [error]
  /// should be set.
  const CassetteEntry({
    required this.operationName,
    this.variables = const {},
    this.response,
    this.events,
    this.error,
  });

  /// Reads an entry written by [toJson].
  factory CassetteEntry.fromJson(JsonMap json) {
    final error = json['error'];
    final events = json['events'];
    return CassetteEntry(
      operationName: json['operationName'] as String?,
      variables: (json['variables'] as JsonMap?) ?? const {},
      response: json.containsKey('response')
          ? GraphQLResponse.fromJson(json['response'])
          : null,
      events: events is List
          ? [for (final event in events) GraphQLResponse.fromJson(event)]
          : null,
      error: error is JsonMap ? _exceptionFromJson(error) : null,
    );
  }

  /// The operation that was sent.
  final String? operationName;

  /// The variables it was sent with.
  final JsonMap variables;

  /// The answer to a query or mutation.
  final GraphQLResponse? response;

  /// The events a subscription received.
  final List<GraphQLResponse>? events;

  /// The transport failure the request ended with (network, timeout...).
  final GraphQLException? error;

  static const _equality = DeepCollectionEquality();

  /// Whether this entry answers [request].
  bool matches(GraphQLRequest request) =>
      operationName == request.operationName &&
      _equality.equals(variables, request.variables);

  /// This entry as JSON.
  JsonMap toJson() => {
        'operationName': operationName,
        'variables': variables,
        if (response case final response?)
          'response': _responseToJson(response),
        if (events case final events?)
          'events': [for (final event in events) _responseToJson(event)],
        if (error case final error?) 'error': _exceptionToJson(error),
      };

  @override
  String toString() => '$operationName $variables';

  static JsonMap _responseToJson(GraphQLResponse response) => {
        'data': response.data,
        if (response.hasErrors)
          'errors': [for (final error in response.errors) error.toJson()],
        if (response.extensions case final extensions?)
          'extensions': extensions,
      };

  static JsonMap _exceptionToJson(GraphQLException error) => {
        'kind': error.kind.name,
        'message': error.message,
        if (error.statusCode case final status?) 'statusCode': status,
        if (error.errors.isNotEmpty)
          'errors': [for (final e in error.errors) e.toJson()],
      };

  static GraphQLException _exceptionFromJson(JsonMap json) {
    final errors = json['errors'];
    return GraphQLException(
      GraphQLErrorKind.values.asNameMap()[json['kind']] ??
          GraphQLErrorKind.unknown,
      json['message'] as String? ?? 'Recorded failure',
      statusCode: json['statusCode'] as int?,
      errors: errors is List
          ? [
              for (final error in errors.whereType<JsonMap>())
                GraphQLError.fromJson(error),
            ]
          : const [],
    );
  }
}
