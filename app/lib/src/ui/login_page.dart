import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../app_state.dart';
import 'theme.dart';

/// In-app login. Mirrors the official mobile flow: open the same /remote/v4
/// link, let the user sign in to Z.ai (or BigModel), then pull the issued
/// `zcodejwttoken` from localStorage — it authorizes terminal-token minting
/// and pairing without a separate browser.
class LoginWebViewPage extends StatefulWidget {
  const LoginWebViewPage({super.key, required this.state});

  final AppState state;

  @override
  State<LoginWebViewPage> createState() => _LoginWebViewPageState();
}

class _LoginWebViewPageState extends State<LoginWebViewPage> {
  late final WebViewController _controller;
  Timer? _poll;
  int _elapsedSec = 0;

  @override
  void initState() {
    super.initState();
    final url = widget.state.activeDevice?.url ??
        'https://zcode.z.ai/remote/v4';
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Color(0xFF0B0D10))
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) => _scan(),
      ))
      ..loadRequest(Uri.parse(url));
    _poll = Timer.periodic(Duration(milliseconds: 900), (_) => _scan());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  bool _busy = false;

  Future<void> _scan() async {
    if (_busy || !mounted) return;
    _busy = true;
    _elapsedSec++;
    try {
      for (final key in const ['zcodejwttoken', 'oauth:zai:access_token']) {
        Object? value;
        try {
          value = await _controller.runJavaScriptReturningResult(
              'localStorage.getItem("$key")');
        } catch (_) {
          break; // page not ready yet
        }
        final text = value.toString();
        final token = _clean(text);
        if (token != null && token.isNotEmpty && token.length > 40) {
          _poll!.cancel();
          if (mounted) {
            await widget.state.setJwt(token);
            if (mounted && Navigator.of(context).canPop()) {
              Navigator.of(context).pop(true);
            }
          }
          return;
        }
      }
      if (_elapsedSec > 240 && mounted) {
        _poll?.cancel();
        Navigator.of(context).pop(false);
      }
    } finally {
      _busy = false;
    }
  }

  String? _clean(String raw) {
    var s = raw.trim();
    if (s.startsWith('"') && s.endsWith('"')) {
      s = s.substring(1, s.length - 1);
    }
    if (s == 'null' || s.isEmpty) return null;
    return s;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Pal.bg,
      appBar: AppBar(
        title: Text('Вход в аккаунт Z.ai'),
        actions: [
          IconButton(
            tooltip: 'Проверить снова',
            onPressed: _scan,
            icon: Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: WebViewWidget(controller: _controller)),
          Container(
            color: Pal.surface,
            padding: EdgeInsets.fromLTRB(16, 10, 16, 16),
            child: Text(
              'Выбери того же провайдера и аккаунт, что на компьютере (Z.ai или '
              'BigModel). После входа пара закроется сама — токен уйдёт только '
              'в это приложение.',
              style: TextStyle(color: Pal.muted, fontSize: 12, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}
