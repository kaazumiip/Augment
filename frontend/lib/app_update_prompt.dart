import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

/// Optional release checks never block sign-in or normal app use.
class AppUpdatePrompt extends StatefulWidget {
  const AppUpdatePrompt({super.key, required this.child});
  final Widget child;

  @override
  State<AppUpdatePrompt> createState() => _AppUpdatePromptState();
}

class _AppUpdatePromptState extends State<AppUpdatePrompt>
    with WidgetsBindingObserver {
  static const _build =
      int.fromEnvironment('AUGMENT_APP_BUILD', defaultValue: 9);
  static final _download = Uri.parse(
    'https://augment-production-f590.up.railway.app/download/',
  );
  Timer? _timer;
  bool _checking = false;
  bool _prompted = false;
  DateTime? _lastCheck;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer(const Duration(seconds: 8), _check);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    if (_checking || _prompted || !mounted) return;
    if (_lastCheck != null &&
        DateTime.now().difference(_lastCheck!) < const Duration(hours: 1)) {
      return;
    }
    _checking = true;
    _lastCheck = DateTime.now();
    final client = http.Client();
    try {
      final response = await client
          .get(
            _download.resolve('downloads/release.json').replace(
              queryParameters: {
                'check': DateTime.now().millisecondsSinceEpoch.toString()
              },
            ),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return;
      final release = jsonDecode(response.body.replaceFirst('\uFEFF', ''))
          as Map<String, dynamic>;
      final latest = int.tryParse('${release['build']}');
      if (latest == null || latest <= _build || !mounted) return;
      _prompted = true;
      final update = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon:
              const Icon(Icons.system_update_rounded, color: Color(0xFFBA0007)),
          title: const Text('New update available'),
          content: const Text(
            'A new version of Augment is ready. Download the latest app from our landing page.',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Later')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Update')),
          ],
        ),
      );
      if (update == true && mounted) {
        final opened =
            await launchUrl(_download, mode: LaunchMode.externalApplication);
        if (!opened && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text(
                    'Could not open the download page. Please try again.')),
          );
        }
      }
    } catch (_) {
      // Offline or unavailable release servers must not interrupt the app.
    } finally {
      client.close();
      _checking = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
