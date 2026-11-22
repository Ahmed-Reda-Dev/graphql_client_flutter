/// A decoded JSON object, as produced by `jsonDecode`.
typedef JsonMap = Map<String, dynamic>;

/// Whether [value] is made only of JSON types (null, bool, num, String,
/// lists and string-keyed maps), so it can be saved and restored as is.
bool isJsonValue(Object? value) => switch (value) {
      null || bool() || num() || String() => true,
      final List<Object?> list => list.every(isJsonValue),
      final Map<String, Object?> map => map.values.every(isJsonValue),
      _ => false,
    };
