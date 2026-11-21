import 'dart:async';

import 'package:flutter/material.dart';

import 'bridge.dart';
import 'json_view.dart';

/// Live list of GraphQL operations, with details for the selected one.
class OperationsView extends StatefulWidget {
  const OperationsView({super.key});

  @override
  State<OperationsView> createState() => _OperationsViewState();
}

class _OperationsViewState extends State<OperationsView> {
  final Map<String, Json> _byId = {};
  StreamSubscription<Json>? _events;
  String? _selected;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _events = Bridge.operationEvents().listen(_merge);
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    super.dispose();
  }

  Future<void> _load() async {
    final result = await Bridge.call('getOperations');
    for (final event in (result['operations'] as List? ?? const [])) {
      _merge(event as Json);
    }
  }

  /// Pending and finished events share an id; later fields win.
  void _merge(Json event) {
    final id = '${event['id']}';
    if (!mounted) return;
    setState(() => _byId[id] = {...?_byId[id], ...event});
  }

  Future<void> _clear() async {
    await Bridge.call('clearOperations');
    setState(() {
      _byId.clear();
      _selected = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final operations = _byId.entries
        .where(
          (e) => '${e.value['operationName']}'.toLowerCase().contains(
            _filter.toLowerCase(),
          ),
        )
        .toList()
        .reversed
        .toList();
    final selected = _selected == null ? null : _byId[_selected];

    return Column(
      children: [
        _Toolbar(
          onFilter: (value) => setState(() => _filter = value),
          onClear: _clear,
          count: _byId.length,
        ),
        const Divider(height: 1),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 2,
                child: operations.isEmpty
                    ? const EmptyState(
                        'No operations yet. Run a query in '
                        'your app.',
                      )
                    : ListView.builder(
                        itemCount: operations.length,
                        itemBuilder: (context, i) {
                          final MapEntry(:key, :value) = operations[i];
                          return _OperationTile(
                            operation: value,
                            selected: key == _selected,
                            onTap: () => setState(() => _selected = key),
                          );
                        },
                      ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                flex: 3,
                child: selected == null
                    ? const EmptyState('Select an operation')
                    : _OperationDetails(selected),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.onFilter,
    required this.onClear,
    required this.count,
  });

  final ValueChanged<String> onFilter;
  final VoidCallback onClear;
  final int count;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(8),
    child: Row(
      children: [
        SizedBox(
          width: 260,
          child: TextField(
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search, size: 18),
              hintText: 'Filter by operation name',
              border: OutlineInputBorder(),
            ),
            onChanged: onFilter,
          ),
        ),
        const SizedBox(width: 12),
        Text('$count operations'),
        const Spacer(),
        TextButton.icon(
          onPressed: onClear,
          icon: const Icon(Icons.block, size: 18),
          label: const Text('Clear'),
        ),
      ],
    ),
  );
}

class _OperationTile extends StatelessWidget {
  const _OperationTile({
    required this.operation,
    required this.selected,
    required this.onTap,
  });

  final Json operation;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final status = '${operation['status']}';
    final duration = operation['durationMs'];
    return ListTile(
      dense: true,
      selected: selected,
      onTap: onTap,
      leading: _StatusDot(status),
      title: Text(
        '${operation['operationName'] ?? '(anonymous)'}',
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text('${operation['type']} · $status'),
      trailing: Text(duration == null ? '…' : '$duration ms'),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot(this.status);

  final String status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'success' => Colors.green,
      'cache' => Colors.teal,
      'errors' => Colors.orange,
      'failure' => Colors.red,
      _ => Colors.grey,
    };
    return Icon(Icons.circle, size: 12, color: color);
  }
}

class _OperationDetails extends StatelessWidget {
  const _OperationDetails(this.operation);

  final Json operation;

  @override
  Widget build(BuildContext context) {
    final failure = operation['status'] == 'failure';
    return ListView(
      children: [
        Section(
          title: 'Summary',
          child: JsonView({
            'operation': operation['operationName'],
            'type': operation['type'],
            'status': operation['status'],
            'durationMs': operation['durationMs'],
            'httpStatus': operation['httpStatus'],
            'time': operation['time'],
            if (failure) 'errorKind': operation['errorKind'],
            if (failure) 'message': operation['message'],
          }),
        ),
        Section(title: 'Variables', child: JsonView(operation['variables'])),
        if (operation['errors'] case final List<dynamic> errors
            when errors.isNotEmpty)
          Section(title: 'Errors', child: JsonView(errors)),
        if (operation['data'] != null)
          Section(title: 'Response data', child: JsonView(operation['data'])),
        Section(title: 'Document', child: JsonView('${operation['document']}')),
      ],
    );
  }
}
