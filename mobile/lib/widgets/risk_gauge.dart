import 'package:flutter/material.dart';

/// Circular gauge showing the estimated chance of default.
class RiskGauge extends StatelessWidget {
  final double probability; // 0..1
  final Color color;
  final double size;

  const RiskGauge({
    super.key,
    required this.probability,
    required this.color,
    this.size = 150,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CircularProgressIndicator(
            value: probability.clamp(0.0, 1.0),
            strokeWidth: 12,
            strokeCap: StrokeCap.round,
            color: color,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${(probability * 100).toStringAsFixed(1)}%',
                  style: theme.textTheme.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                Text('chance of default', style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
