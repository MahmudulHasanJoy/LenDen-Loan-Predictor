import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/session.dart';

/// Lets the user point the app at a local or deployed API.
class ServerScreen extends StatefulWidget {
  const ServerScreen({super.key});

  @override
  State<ServerScreen> createState() => _ServerScreenState();
}

class _ServerScreenState extends State<ServerScreen> {
  late final TextEditingController _url =
      TextEditingController(text: AppScope.read(context).api.baseUrl);
  String? _status;
  bool _busy = false;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _saveAndTest() async {
    final session = AppScope.read(context);
    setState(() {
      _busy = true;
      _status = null;
    });
    await session.setBaseUrl(_url.text);
    String status;
    try {
      final res = await session.api.get('/health') as Map<String, dynamic>;
      status = 'Connected to LenDen ${res['version']} (${res['model']}).';
    } catch (e) {
      status = e.toString();
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = status;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Server')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'API address',
              hintText: 'http://192.168.0.10:8000',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : _saveAndTest,
            icon: const Icon(Icons.wifi_tethering),
            label: const Text('Save and test'),
          ),
          if (_status != null) ...[
            const SizedBox(height: 12),
            Text(_status!),
          ],
          const SizedBox(height: 24),
          Text('Which address?', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(
            '- Android emulator: http://10.0.2.2:8000\n'
            '- iOS simulator, web or desktop: http://localhost:8000\n'
            '- Phone on the same Wi-Fi: http://<computer IP>:8000\n'
            '- Deployed server: its https:// address',
            style: theme.textTheme.bodySmall,
          ),
          TextButton(
            onPressed: () => _url.text = Api.platformDefaultUrl,
            child: const Text('Reset to default'),
          ),
        ],
      ),
    );
  }
}
