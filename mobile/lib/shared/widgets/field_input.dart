import 'package:flutter/material.dart';

import '../../core/l10n/l10n.dart';
import '../models/metadata.dart';

/// The right control for a field: segmented buttons for short option lists, a dropdown for
/// longer ones, and a slider with a typed value for numeric ranges.
class FieldInput extends StatelessWidget {
  final FieldSpec spec;
  final Object value;
  final ValueChanged<Object> onChanged;
  final String currency;

  const FieldInput(
      {super.key, required this.spec, required this.value, required this.onChanged, this.currency = 'BDT'});

  @override
  Widget build(BuildContext context) {
    if (spec.hasOptions && spec.options.length <= 3) return _segmented(context);
    if (spec.hasOptions) return _dropdown(context);
    return _slider(context);
  }

  String _label(BuildContext context) => context.field(spec.name);

  String _option(BuildContext context, Object o) =>
      o is String ? context.code('option.${spec.name}', o, fallback: o) : context.value(spec.name, o, currency: currency);

  Widget _title(BuildContext context, {String? trailing}) {
    final theme = Theme.of(context);
    final help = context.code('help', spec.name, fallback: '');
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(_label(context), style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600))),
          if (trailing != null)
            Text(trailing, style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.primary)),
        ]),
        if (help.isNotEmpty) Text(help, style: theme.textTheme.bodySmall),
      ]),
    );
  }

  Widget _segmented(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _title(context),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<Object>(
            showSelectedIcon: false,
            segments: [for (final o in spec.options) ButtonSegment<Object>(value: o, label: Text(_option(context, o)))],
            selected: {value},
            onSelectionChanged: (s) => onChanged(s.first),
          ),
        ),
      ]),
    );
  }

  Widget _dropdown(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _title(context),
        DropdownMenu<Object>(
          key: ValueKey('dropdown-${spec.name}'),
          initialSelection: value,
          expandedInsets: EdgeInsets.zero,
          dropdownMenuEntries: [
            for (final o in spec.options) DropdownMenuEntry<Object>(value: o, label: _option(context, o)),
          ],
          onSelected: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ]),
    );
  }

  double get _step {
    final range = (spec.max ?? 1.0) - (spec.min ?? 0.0);
    if (spec.isInteger) return range > 5000 ? 1000.0 : 1.0;
    return range <= 1 ? 0.01 : 0.1;
  }

  Widget _slider(BuildContext context) {
    final min = spec.min ?? 0.0;
    final max = spec.max ?? 1.0;
    final step = _step;
    final current = (value as num).toDouble().clamp(min, max).toDouble();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _title(context, trailing: context.value(spec.name, value, currency: currency)),
        Slider(
          min: min,
          max: max,
          value: current,
          divisions: ((max - min) / step).round().clamp(1, 1000),
          semanticFormatterCallback: (v) => context.value(spec.name, v, currency: currency),
          onChanged: (v) {
            final snapped = (v / step).round() * step;
            onChanged(spec.isInteger ? snapped.round() : double.parse(snapped.toStringAsFixed(2)));
          },
        ),
      ]),
    );
  }
}
