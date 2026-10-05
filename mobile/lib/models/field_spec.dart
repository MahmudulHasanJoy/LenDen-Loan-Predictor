/// One input field, as described by the API's /metadata endpoint.
class FieldSpec {
  final String name;
  final String label;
  final String type; // 'integer', 'number' or 'category'
  final double? min;
  final double? max;
  final List<Object> options;
  final Object? defaultValue;

  const FieldSpec({
    required this.name,
    required this.label,
    required this.type,
    this.min,
    this.max,
    this.options = const [],
    this.defaultValue,
  });

  bool get isCategory => type == 'category';
  bool get isInteger => type == 'integer';
  bool get hasOptions => options.isNotEmpty;

  factory FieldSpec.fromJson(Map<String, dynamic> j) {
    final type = j['type'] as String;
    final rawOptions = (j['options'] as List<dynamic>?) ?? const [];
    final options = rawOptions
        .map<Object>((o) => type == 'category' ? o.toString() : (o as num).toInt())
        .toList();
    Object? def = j['default'];
    if (def is num && type == 'integer') def = def.round();
    return FieldSpec(
      name: j['name'] as String,
      label: j['label'] as String,
      type: type,
      min: (j['min'] as num?)?.toDouble(),
      max: (j['max'] as num?)?.toDouble(),
      options: options,
      defaultValue: def,
    );
  }
}

/// Everything the app needs from /metadata.
class ModelMetadata {
  final String model;
  final String version;
  final double threshold;
  final int defaultCostRatio;
  final int maxCostRatio;
  final List<FieldSpec> fields;
  final Map<String, dynamic> performance;

  const ModelMetadata({
    required this.model,
    required this.version,
    required this.threshold,
    required this.defaultCostRatio,
    required this.maxCostRatio,
    required this.fields,
    required this.performance,
  });

  factory ModelMetadata.fromJson(Map<String, dynamic> j) => ModelMetadata(
        model: j['model'] as String,
        version: j['version'] as String,
        threshold: (j['threshold'] as num).toDouble(),
        defaultCostRatio: (j['default_cost_ratio'] as num).toInt(),
        maxCostRatio: (j['max_cost_ratio'] as num).toInt(),
        fields: (j['fields'] as List<dynamic>)
            .map((f) => FieldSpec.fromJson(f as Map<String, dynamic>))
            .toList(),
        performance: Map<String, dynamic>.from(j['performance'] as Map),
      );
}
