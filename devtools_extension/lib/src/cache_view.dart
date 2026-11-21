import 'dart:async';

import 'package:flutter/material.dart';

import 'bridge.dart';
import 'json_view.dart';

/// Browses the normalized cache of a client in the running app.
class CacheView extends StatefulWidget {
  const CacheView({super.key});

  @override
  State<CacheView> createState() => _CacheViewState();
}

class _CacheViewState extends State<CacheView> {
  List<Json> _clients = const [];
  String? _clientId;
  Json _entities = const {};
  String? _selected;
  String _filter = '';
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final clients =
        ((await Bridge.call('getClients'))['clients'] as List?)?.cast<Json>() ??
        const <Json>[];
    final clientId =
        _clientId ?? (clients.isEmpty ? null : '${clients.last['id']}');
    final entities = clientId == null
        ? const <String, dynamic>{}
        : ((await Bridge.call('getCache', {'clientId': clientId}))['entities']
                  as Json? ??
              const {});
    if (!mounted) return;
    setState(() {
      _clients = clients;
      _clientId = clientId;
      _entities = entities;
      _loading = false;
      if (!_entities.containsKey(_selected)) _selected = null;
    });
  }

  Future<void> _clear() async {
    final id = _clientId;
    if (id == null) return;
    await Bridge.call('clearCache', {'clientId': id});
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final ids =
        _entities.keys
            .where((id) => id.toLowerCase().contains(_filter.toLowerCase()))
            .toList()
          ..sort();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              DropdownButton<String>(
                value: _clientId,
                hint: const Text('No clients'),
                items: [
                  for (final client in _clients)
                    DropdownMenuItem(
                      value: '${client['id']}',
                      child: Text('#${client['id']} ${client['label']}'),
                    ),
                ],
                onChanged: (id) {
                  setState(() => _clientId = id);
                  unawaited(_refresh());
                },
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 240,
                child: TextField(
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 18),
                    hintText: 'Filter ids (e.g. User:)',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) => setState(() => _filter = value),
                ),
              ),
              const SizedBox(width: 12),
              Text('${_entities.length} entries'),
              const Spacer(),
              IconButton(
                tooltip: 'Refresh',
                onPressed: _loading ? null : _refresh,
                icon: const Icon(Icons.refresh),
              ),
              TextButton.icon(
                onPressed: _clientId == null ? null : _clear,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('Clear cache'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 2,
                child: ids.isEmpty
                    ? const EmptyState('The cache is empty')
                    : ListView.builder(
                        itemCount: ids.length,
                        itemBuilder: (context, i) => ListTile(
                          dense: true,
                          selected: ids[i] == _selected,
                          title: Text(
                            ids[i],
                            style: const TextStyle(fontFamily: 'RobotoMono'),
                          ),
                          onTap: () => setState(() => _selected = ids[i]),
                        ),
                      ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                flex: 3,
                child: _selected == null
                    ? const EmptyState('Select an entry')
                    : JsonView(_entities[_selected]),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
