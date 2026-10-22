import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';

/// One input field, as described by the API's /metadata endpoint.
class FieldSpec {
  final String name;
  final String type; // 'integer', 'number' or 'category'
  final double? min;
  final double? max;
  final List<Object> options;
  final Object? defaultValue;

  const FieldSpec(
      {required this.name, required this.type, this.min, this.max, this.options = const [], this.defaultValue});

  bool get isCategory => type == 'category';
  bool get isInteger => type == 'integer';
  bool get hasOptions => options.isNotEmpty;

  factory FieldSpec.fromJson(Map<String, dynamic> j) {
    final type = j['type'] as String;
    final raw = (j['options'] as List<dynamic>?) ?? const [];
    final options = raw.map<Object>((o) => type == 'category' ? o.toString() : (o as num).toInt()).toList();
    Object? def = j['default'];
    final d = def;
    if (d is num && type == 'integer') {
      if (options.isNotEmpty) {
        var best = options.first as int;
        for (final o in options.cast<int>()) {
          if ((o - d).abs() < (best - d).abs()) best = o;
        }
        def = best;
      } else {
        def = d.round();
      }
    }
    return FieldSpec(
      name: j['name'] as String,
      type: type,
      min: (j['min'] as num?)?.toDouble(),
      max: (j['max'] as num?)?.toDouble(),
      options: options,
      defaultValue: def,
    );
  }
}

/// Everything the app needs from /metadata: fields, wizard steps, optional profile questions.
class ModelMetadata {
  final String modelVersion;
  final List<FieldSpec> fields;
  final Map<int, List<String>> steps;
  final Map<String, List<String>> demographics;

  const ModelMetadata(
      {required this.modelVersion, required this.fields, required this.steps, required this.demographics});

  FieldSpec? field(String name) {
    for (final f in fields) {
      if (f.name == name) return f;
    }
    return null;
  }

  Map<String, Object> defaults() => {
        for (final f in fields)
          if (f.defaultValue != null) f.name: f.defaultValue!,
      };

  factory ModelMetadata.fromJson(Map<String, dynamic> j) {
    final fields = (j['fields'] as List).map((f) => FieldSpec.fromJson(Map<String, dynamic>.from(f as Map))).toList();
    final names = fields.map((f) => f.name).toSet();
    final steps = <int, List<String>>{};
    (j['steps'] as Map? ?? const {}).forEach((k, v) {
      steps[int.parse(k.toString())] = (v as List).map((e) => e.toString()).where(names.contains).toList();
    });
    final demo = <String, List<String>>{};
    (j['demographics'] as Map? ?? const {}).forEach((k, v) {
      demo[k.toString()] = (v as List).map((e) => e.toString()).toList();
    });
    return ModelMetadata(
        modelVersion: (j['model_version'] ?? j['version'] ?? '').toString(),
        fields: fields,
        steps: steps,
        demographics: demo);
  }
}

final metadataProvider = FutureProvider<ModelMetadata>((ref) async {
  final api = ref.watch(apiProvider);
  return ModelMetadata.fromJson(await api.get('/metadata') as Map<String, dynamic>);
});

final lendersProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final res = await ref.watch(apiProvider).get('/lenders') as List;
  return res.map((e) => Map<String, dynamic>.from(e as Map)).toList();
});
