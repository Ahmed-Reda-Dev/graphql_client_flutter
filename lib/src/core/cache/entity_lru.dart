import 'dart:math' as math;

import 'package:normalize/normalize.dart';

/// Tracks the order in which cache entities were used, so the least
/// recently used ones can be evicted once there are more than
/// [maxEntities].
///
/// Root operation types (`Query`, or the type a [TypePolicy] marks as a
/// root) and bookkeeping ids starting with `$` are never tracked, so they
/// are never evicted.
final class EntityLru {
  /// Starts tracking [existing] ids, treating their order as oldest first.
  EntityLru(
    this.maxEntities, {
    required Iterable<String> existing,
    Map<String, TypePolicy> typePolicies = const {},
  })  : assert(maxEntities > 0, 'maxEntities must be positive'),
        _roots = {
          'Query',
          'Mutation',
          'Subscription',
          for (final MapEntry(:key, :value) in typePolicies.entries)
            if (value.queryType || value.mutationType || value.subscriptionType)
              key,
        } {
    existing.forEach(touch);
  }

  /// How many entities may stay in the cache.
  final int maxEntities;

  final Set<String> _roots;

  /// Insertion order is use order: the first id is the least recently used.
  final _order = <String>{};

  /// Marks [id] as just used.
  void touch(String id) {
    if (id.startsWith(r'$') || _roots.contains(id)) return;
    _order
      ..remove(id)
      ..add(id);
  }

  /// Stops tracking [id] (it was deleted).
  void remove(String id) => _order.remove(id);

  /// Stops tracking everything (the cache was cleared).
  void clear() => _order.clear();

  /// Removes and returns the ids over the limit, least recently used first.
  List<String> takeOverflow() {
    final overflow = _order
        .take(math.max(0, _order.length - maxEntities))
        .toList(growable: false);
    overflow.forEach(_order.remove);
    return overflow;
  }
}
