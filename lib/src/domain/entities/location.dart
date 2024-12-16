/// Represents a location in a GraphQL document where an error occurred
class Location {
  /// The line number in the GraphQL document (1-based)
  final int line;

  /// The column number in the GraphQL document (1-based)
  final int column;

  /// Creates a new Location instance
  const Location({
    required this.line,
    required this.column,
  });

  /// Creates a Location from a JSON map
  factory Location.fromJson(Map<String, dynamic> json) {
    return Location(
      line: json['line'] as int,
      column: json['column'] as int,
    );
  }

  /// Converts the location to a JSON map
  Map<String, dynamic> toJson() {
    return {
      'line': line,
      'column': column,
    };
  }

  /// Creates a copy of this location with the given fields replaced with new values
  Location copyWith({
    int? line,
    int? column,
  }) {
    return Location(
      line: line ?? this.line,
      column: column ?? this.column,
    );
  }

  /// Returns a string representation of the location in the format "line:column"
  String toPositionString() => '$line:$column';

  /// Whether this location comes before another location in the document
  bool isBefore(Location other) {
    return line < other.line || (line == other.line && column < other.column);
  }

  /// Whether this location comes after another location in the document
  bool isAfter(Location other) {
    return line > other.line || (line == other.line && column > other.column);
  }

  @override
  String toString() => 'Location(line: $line, column: $column)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Location && line == other.line && column == other.column;

  @override
  int get hashCode => line.hashCode ^ column.hashCode;

  /// Compares two locations for ordering
  static int compare(Location a, Location b) {
    final lineComparison = a.line.compareTo(b.line);
    if (lineComparison != 0) return lineComparison;
    return a.column.compareTo(b.column);
  }
}

/// Extension methods for lists of locations
extension LocationListExtension on List<Location> {
  /// Sorts locations in document order
  void sortInDocumentOrder() {
    sort(Location.compare);
  }

  /// Gets the earliest location in the list
  Location? get earliest =>
      isEmpty ? null : reduce((a, b) => a.isBefore(b) ? a : b);

  /// Gets the latest location in the list
  Location? get latest =>
      isEmpty ? null : reduce((a, b) => a.isAfter(b) ? a : b);
}
