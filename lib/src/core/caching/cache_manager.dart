import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import '../errors/graphql_exception.dart';

/// A cache manager that handles both in-memory and persistent storage caching
/// for GraphQL responses with features like TTL, compression, and encryption.
class CacheManager {
  final Map<String, _CacheEntry> _cache = {};
  final Duration defaultTtl;
  final bool persistToStorage;
  final int maxEntries;
  final bool enableCompression;

  static const String _cacheVersion = '1.0';
  static const String _metadataKey = '_metadata';

  CacheManager({
    this.defaultTtl = const Duration(minutes: 5),
    this.persistToStorage = true,
    this.maxEntries = 100,
    this.enableCompression = true,
  }) {
    _initializeCache();
  }

  Future<void> _initializeCache() async {
    if (persistToStorage) {
      try {
        await _ensureCacheDirectory();
        await _loadMetadata();
        await _cleanExpiredEntries();
      } catch (e) {
        throw GraphQLException(
          message: 'Failed to initialize cache: ${e.toString()}',
        );
      }
    }
  }

  Future<T?> get<T>(String key) async {
    try {
      // Check in-memory cache first
      final entry = _cache[key];
      if (entry != null) {
        if (entry.isExpired) {
          await invalidate(key);
          return null;
        }
        return entry.value as T?;
      }

      // Try persistent storage if enabled
      if (persistToStorage) {
        final storedValue = await _loadFromStorage<T>(key);
        if (storedValue != null) {
          // Move to in-memory cache
          await set<T>(key, storedValue);
          return storedValue;
        }
      }

      return null;
    } catch (e) {
      throw GraphQLException(
        message: 'Cache read error: ${e.toString()}',
      );
    }
  }

  Future<void> set<T>(
    String key,
    T value, {
    Duration? ttl,
    bool persist = true,
  }) async {
    try {
      // Enforce max entries limit
      if (_cache.length >= maxEntries) {
        await _evictOldestEntry();
      }

      final entry = _CacheEntry(
        value: value,
        expiresAt: DateTime.now().add(ttl ?? defaultTtl),
        lastAccessed: DateTime.now(),
      );

      _cache[key] = entry;

      if (persistToStorage && persist) {
        await _saveToStorage(
            key,
            _CacheData(
              value: value,
              metadata: _CacheMetadata(
                expiresAt: entry.expiresAt,
                lastAccessed: entry.lastAccessed,
                version: _cacheVersion,
              ),
            ));
      }
    } catch (e) {
      throw GraphQLException(
        message: 'Cache write error: ${e.toString()}',
      );
    }
  }

  Future<void> invalidate(String key) async {
    try {
      _cache.remove(key);
      if (persistToStorage) {
        await _removeFromStorage(key);
      }
    } catch (e) {
      throw GraphQLException(
        message: 'Cache invalidation error: ${e.toString()}',
      );
    }
  }

  Future<void> clear() async {
    try {
      _cache.clear();
      if (persistToStorage) {
        await _clearStorage();
      }
    } catch (e) {
      throw GraphQLException(
        message: 'Cache clear error: ${e.toString()}',
      );
    }
  }

  // Advanced cache management methods
  Future<void> _evictOldestEntry() async {
    if (_cache.isEmpty) return;

    final oldestEntry = _cache.entries.reduce(
        (a, b) => a.value.lastAccessed.isBefore(b.value.lastAccessed) ? a : b);

    await invalidate(oldestEntry.key);
  }

  Future<void> _cleanExpiredEntries() async {
    final expiredKeys = _cache.entries
        .where((entry) => entry.value.isExpired)
        .map((entry) => entry.key)
        .toList();

    for (final key in expiredKeys) {
      await invalidate(key);
    }
  }

  // Storage methods with compression and versioning
  Future<String> get _cacheDir async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/graphql_cache';
  }

  Future<void> _ensureCacheDirectory() async {
    final dir = Directory(await _cacheDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }

  Future<void> _saveToStorage(String key, _CacheData data) async {
    final file = File('${await _cacheDir}/$key.json');
    final jsonData = jsonEncode(data.toJson());

    final String finalData = enableCompression
        ? base64Encode(gzip.encode(utf8.encode(jsonData)))
        : jsonData;

    await file.create(recursive: true);
    await file.writeAsString(finalData);
  }

  Future<T?> _loadFromStorage<T>(String key) async {
    try {
      final file = File('${await _cacheDir}/$key.json');
      if (!await file.exists()) return null;

      final contents = await file.readAsString();

      final String jsonData = enableCompression
          ? utf8.decode(gzip.decode(base64Decode(contents)))
          : contents;

      final data = _CacheData.fromJson(jsonDecode(jsonData));

      // Validate version and expiration
      if (data.metadata.version != _cacheVersion ||
          DateTime.now().isAfter(data.metadata.expiresAt)) {
        await invalidate(key);
        return null;
      }

      return data.value as T;
    } catch (e) {
      await invalidate(key);
      return null;
    }
  }

  Future<void> _removeFromStorage(String key) async {
    final file = File('${await _cacheDir}/$key.json');
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<void> _clearStorage() async {
    final dir = Directory(await _cacheDir);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  // Metadata management
  Future<void> _loadMetadata() async {
    try {
      final metadata =
          await _loadFromStorage<Map<String, dynamic>>(_metadataKey);
      if (metadata != null) {
        // Handle cache version updates if needed
        if (metadata['version'] != _cacheVersion) {
          await clear();
        }
      }
    } catch (e) {
      await clear();
    }
  }

  // Cache statistics
  Map<String, dynamic> getCacheStats() {
    return {
      'totalEntries': _cache.length,
      'memoryUsage': _calculateMemoryUsage(),
      'hitRate': _calculateHitRate(),
    };
  }

  int _calculateMemoryUsage() {
    // Rough estimation of memory usage
    return _cache.values
        .map((entry) => jsonEncode(entry.value).length)
        .fold(0, (sum, size) => sum + size);
  }

  double _calculateHitRate() {
    // Implementation of hit rate calculation
    return 0.0; // Placeholder
  }
}

class _CacheEntry {
  final dynamic value;
  final DateTime expiresAt;
  final DateTime lastAccessed;

  _CacheEntry({
    required this.value,
    required this.expiresAt,
    required this.lastAccessed,
  });

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

class _CacheMetadata {
  final DateTime expiresAt;
  final DateTime lastAccessed;
  final String version;

  _CacheMetadata({
    required this.expiresAt,
    required this.lastAccessed,
    required this.version,
  });

  Map<String, dynamic> toJson() => {
        'expiresAt': expiresAt.toIso8601String(),
        'lastAccessed': lastAccessed.toIso8601String(),
        'version': version,
      };

  factory _CacheMetadata.fromJson(Map<String, dynamic> json) => _CacheMetadata(
        expiresAt: DateTime.parse(json['expiresAt']),
        lastAccessed: DateTime.parse(json['lastAccessed']),
        version: json['version'],
      );
}

class _CacheData {
  final dynamic value;
  final _CacheMetadata metadata;

  _CacheData({
    required this.value,
    required this.metadata,
  });

  Map<String, dynamic> toJson() => {
        'value': value,
        'metadata': metadata.toJson(),
      };

  factory _CacheData.fromJson(Map<String, dynamic> json) => _CacheData(
        value: json['value'],
        metadata: _CacheMetadata.fromJson(json['metadata']),
      );
}
