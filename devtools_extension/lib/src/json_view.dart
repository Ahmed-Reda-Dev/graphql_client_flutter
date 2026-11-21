import 'dart:convert';

import 'package:flutter/material.dart';

/// Pretty-printed, selectable JSON.
class JsonView extends StatelessWidget {
  const JsonView(this.value, {super.key});

  final Object? value;

  static const _encoder = JsonEncoder.withIndent('  ');

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(12),
    child: SelectableText(
      value is String ? value! as String : _encoder.convert(value),
      style: const TextStyle(fontFamily: 'RobotoMono', fontSize: 12),
    ),
  );
}

/// A titled section in a details pane.
class Section extends StatelessWidget {
  const Section({super.key, required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        child: Text(title, style: Theme.of(context).textTheme.titleSmall),
      ),
      child,
    ],
  );
}

/// A message shown when there is nothing to display.
class EmptyState extends StatelessWidget {
  const EmptyState(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Text(message, style: Theme.of(context).textTheme.bodyMedium),
  );
}
