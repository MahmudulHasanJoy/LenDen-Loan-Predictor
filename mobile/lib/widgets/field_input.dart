import 'package:flutter/material.dart';

import '../core/format.dart';
import '../models/field_spec.dart';

/// Renders the right control for a field: segmented buttons for short option
/// lists, a dropdown for longer ones, and a slider for numeric ranges.
class FieldInput extends StatelessWidget {
  final FieldSpec spec;
  final Object value;
  final ValueChanged<Object> onChanged;

  const FieldInput({
    super.key,
    required this.spec,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (spec.hasOptions && spec.options.length <= 3) return _segmented(context);
    if (spec.hasOptions) return _dropdown(context);
    return _slider(context);
  }

  Widget _label(BuildContext context, {String? trailing}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(child: Text(spec.label, style: theme.textTheme.bodyMedium)),
          if (trailing != null)
            Text(trailing,
                style: theme.textTheme.titleSmall
                    ?.copyWith(color: theme.colorScheme.primary)),
        ],
      ),
    );
  }

  Widget _segmented(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label(context),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<Object>(
              showSelectedIcon: false,
              segments: [
                for (final o in spec.options)
                  ButtonSegment<Object>(
                      value: o, label: Text(formatValue(spec.name, o))),
              ],
              selected: {value},
              onSelectionChanged: (s) => onChanged(s.first),
            ),
          ),
        ],
      ),
    );
  }

  Widget _dropdown(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: DropdownMenu<Object>(
        key: ValueKey('dropdown-${spec.name}'),
        label: Text(spec.label),
        initialSelection: value,
        expandedInsets: EdgeInsets.zero,
        dropdownMenuEntries: [
          for (final o in spec.options)
            DropdownMenuEntry<Object>(value: o, label: formatValue(spec.name, o)),
        ],
        onSelected: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
  }

  /// Step size per field so sliders land on sensible values.
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
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label(context, trailing: formatValue(spec.name, value)),
          Slider(
            min: min,
            max: max,
            value: current,
            divisions: ((max - min) / step).round(),
            onChanged: (v) {
              if (spec.isInteger) {
                onChanged(v.round());
              } else {
                onChanged(double.parse(v.toStringAsFixed(2)));
              }
            },
          ),
        ],
      ),
    );
  }
}
