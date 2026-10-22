import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_client.dart';
import '../../core/auth/session.dart';
import '../../core/l10n/l10n.dart';
import '../../shared/widgets/common.dart';

/// Point the app at a different API server (local development, staging or production).
class ServerScreen extends ConsumerStatefulWidget {
  const ServerScreen({super.key});

  @override
  ConsumerState<ServerScreen> createState() => _ServerScreenState();
}

class _ServerScreenState extends ConsumerState<ServerScreen> {
  late final _url = TextEditingController(text: ref.read(apiProvider).baseUrl);
  String? _status;
  bool _busy = false;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    final api = ApiClient(baseUrl: _url.text.trim().replaceAll(RegExp(r'/+$'), ''));
    try {
      final h = await api.get('/health') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() => _status = context.t('server.ok', {'version': h['version'], 'db': h['database']}));
    } catch (e) {
      if (mounted) setState(() => _status = errorText(context, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    await ref.read(sessionProvider.notifier).setServer(_url.text);
    if (mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.t('server.title'))),
      body: PageList(width: 520, children: [
        Text(context.t('server.body')),
        const SizedBox(height: 16),
        TextField(controller: _url, keyboardType: TextInputType.url, decoration: InputDecoration(labelText: context.t('server.url'))),
        const SizedBox(height: 12),
        Wrap(spacing: 8, children: [
          OutlinedButton(onPressed: _busy ? null : _test, child: Text(context.t('server.test'))),
          FilledButton(onPressed: _save, child: Text(context.t('common.save'))),
          TextButton(
              onPressed: () => setState(() => _url.text = ApiClient.platformDefaultUrl), child: Text(context.t('server.default'))),
        ]),
        if (_status != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(_status!)),
      ]),
    );
  }
}
