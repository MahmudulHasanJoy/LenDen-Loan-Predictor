import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/auth/session.dart';

/// The borrower's loan draft: wizard answers, autosaved to the server after each change.
/// Works before sign-up (anonymous draft token) and carries over when the user creates an account.
@immutable
class DraftState {
  final int? id;
  final int step;
  final Map<String, Object> inputs;
  final Map<String, String> demographics;
  final bool saving;
  final bool loading;
  final String? savedAt;
  final Object? error;

  const DraftState(
      {this.id,
      this.step = 1,
      this.inputs = const {},
      this.demographics = const {},
      this.saving = false,
      this.loading = false,
      this.savedAt,
      this.error});

  bool has(String field) => inputs.containsKey(field);

  DraftState copyWith(
          {int? id,
          int? step,
          Map<String, Object>? inputs,
          Map<String, String>? demographics,
          bool? saving,
          bool? loading,
          String? savedAt,
          Object? error,
          bool clearError = false}) =>
      DraftState(
        id: id ?? this.id,
        step: step ?? this.step,
        inputs: inputs ?? this.inputs,
        demographics: demographics ?? this.demographics,
        saving: saving ?? this.saving,
        loading: loading ?? this.loading,
        savedAt: savedAt ?? this.savedAt,
        error: clearError ? null : (error ?? this.error),
      );
}

class DraftController extends Notifier<DraftState> {
  Timer? _debounce;
  final Map<String, Object> _pending = {};

  ApiClient get _api => ref.read(apiProvider);

  @override
  DraftState build() {
    ref.onDispose(() => _debounce?.cancel());
    return const DraftState();
  }

  /// Resume the saved draft (if any) or start a new one.
  Future<void> ensure() async {
    if (state.id != null || state.loading) return;
    state = state.copyWith(loading: true, clearError: true);
    final prefs = ref.read(prefsProvider);
    final saved = prefs.getInt(Keys.draftId);
    try {
      if (saved != null) {
        try {
          final res = await _api.get('/drafts/$saved') as Map<String, dynamic>;
          _load(res['draft'] as Map);
          return;
        } on ApiException catch (e) {
          if (e.status != 404) rethrow;          // expired or not ours: start again
        }
      }
      await _create();
    } catch (e) {
      state = state.copyWith(loading: false, error: e);
    }
  }

  Future<void> _create() async {
    final locale = ref.read(localeProvider).languageCode;
    final res = await _api.post('/drafts', {'inputs': <String, Object>{}, 'step': 1, 'locale': locale}) as Map<String, dynamic>;
    final prefs = ref.read(prefsProvider);
    final token = res['anon_token'] as String?;
    if (token != null) {
      _api.draftToken = token;
      await prefs.setString(Keys.draftToken, token);
    }
    _load(res['draft'] as Map);
    await prefs.setInt(Keys.draftId, state.id!);
  }

  void _load(Map raw) {
    final d = Map<String, dynamic>.from(raw);
    state = DraftState(
      id: d['id'] as int,
      step: (d['step'] as num).toInt(),
      inputs: Map<String, dynamic>.from(d['inputs'] as Map).map((k, v) => MapEntry(k, v as Object)),
      demographics: Map<String, dynamic>.from(d['demographics'] as Map? ?? const {}).map((k, v) => MapEntry(k, '$v')),
      savedAt: d['updated_at'] as String?,
    );
  }

  /// Change one answer; saved automatically half a second after the last change.
  void set(String field, Object value) {
    state = state.copyWith(inputs: {...state.inputs, field: value});
    _pending[field] = value;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () => save());
  }

  void setDemographic(String key, String value) {
    state = state.copyWith(demographics: {...state.demographics, key: value});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () => save());
  }

  /// Apply several values at once (e.g. "use these numbers" from the simulator).
  Future<void> setMany(Map<String, Object> values) async {
    state = state.copyWith(inputs: {...state.inputs, ...values});
    _pending.addAll(values);
    await save();
  }

  Future<void> goToStep(int step) async {
    state = state.copyWith(step: step);
    await save(step: step);
  }

  Future<void> save({int? step}) async {
    _debounce?.cancel();
    final id = state.id;
    if (id == null) return;
    final changes = Map<String, Object>.from(_pending);
    _pending.clear();
    state = state.copyWith(saving: true, clearError: true);
    try {
      final res = await _api.put('/drafts/$id', {
        'inputs': changes,
        'step': step ?? state.step,
        'demographics': state.demographics,
        'locale': ref.read(localeProvider).languageCode,
      }) as Map<String, dynamic>;
      final d = Map<String, dynamic>.from(res['draft'] as Map);
      state = state.copyWith(saving: false, savedAt: d['updated_at'] as String?);
    } catch (e) {
      _pending.addAll(changes);              // keep them for the next attempt
      state = state.copyWith(saving: false, error: e);
    }
  }

  /// Forget the current draft (after applying, or "start over").
  Future<void> reset() async {
    _debounce?.cancel();
    _pending.clear();
    final prefs = ref.read(prefsProvider);
    await prefs.remove(Keys.draftId);
    state = const DraftState();
  }

  /// Use a specific draft (e.g. "continue" from the home screen).
  Future<void> open(int id) async {
    await ref.read(prefsProvider).setInt(Keys.draftId, id);
    state = const DraftState();
    await ensure();
  }
}

final draftProvider = NotifierProvider<DraftController, DraftState>(DraftController.new);
