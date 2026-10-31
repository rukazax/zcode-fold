import 'package:flutter/material.dart';

import '../app_state.dart';
import 'fold_layout.dart';
import 'theme.dart';

class ConnectPage extends StatefulWidget {
  const ConnectPage({super.key, required this.state});

  final AppState state;

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  final _url = TextEditingController();
  final _token = TextEditingController();
  final _name = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final url = _url.text.trim();
    final token = _token.text.trim();
    if (url.isEmpty || token.isEmpty) {
      setState(() => _error = 'Нужны адрес hub и токен');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await widget.state.validateConnection(url, token);
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _busy = false;
        _error = error;
      });
      return;
    }
    await widget.state.addProfile(_name.text, url, token);
    if (!mounted) return;
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final fold = FoldInfo.of(context);
    final wide = fold.isUnfolded;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: wide ? 860 : 460),
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: _brand(fold)),
                        const SizedBox(width: 32),
                        Expanded(child: _form()),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [_brand(fold), const SizedBox(height: 28), _form()],
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _brand(FoldInfo fold) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: kAccent,
            borderRadius: BorderRadius.circular(16),
          ),
          alignment: Alignment.center,
          child: const Text('Z',
              style: TextStyle(
                  color: Color(0xFF06231A), fontSize: 30, fontWeight: FontWeight.w900)),
        ),
        const SizedBox(height: 20),
        const Text('ZCode Fold',
            style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: -0.8)),
        const SizedBox(height: 8),
        const Text(
          'Пульт для ZCode с компьютера. Соединение идёт через твой hub, '
          'поэтому работает из мобильного интернета, а не только по Wi-Fi.',
          style: TextStyle(color: kMuted, height: 1.5, fontSize: 14),
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _chip(Icons.devices_fold_outlined, fold.hasVerticalHinge ? 'шарнир найден' : 'адаптив по ширине'),
            _chip(Icons.lock_outline, 'токен в Keystore'),
            _chip(Icons.bolt_outlined, 'ACP / WebSocket'),
          ],
        ),
        if (widget.state.profiles.isNotEmpty) ...[
          const SizedBox(height: 24),
          const Text('Сохранённые подключения',
              style: TextStyle(color: kMuted, fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          ...widget.state.profiles.map((p) => Card(
                color: kSurface,
                margin: const EdgeInsets.only(bottom: 8),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: const BorderSide(color: kBorder)),
                child: ListTile(
                  leading: const Icon(Icons.hub_outlined, color: kAccent),
                  title: Text(p.name),
                  subtitle: Text(p.hubUrl, style: const TextStyle(color: kMuted, fontSize: 12)),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20, color: kMuted),
                    onPressed: () => widget.state.removeProfile(p),
                  ),
                  onTap: () => widget.state.selectProfile(p),
                ),
              )),
        ],
      ],
    );
  }

  Widget _chip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: kSurface2,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: kBorder),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: kAccent),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 12, color: kMuted)),
      ]),
    );
  }

  Widget _form() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Подключение к hub',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
                labelText: 'Название (необязательно)', hintText: 'Мой ПК'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.next,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Адрес hub',
              hintText: 'https://xxxx.trycloudflare.com',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _token,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Токен',
              hintText: 'ZCODE_ACP_REMOTE_TOKEN',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Color(0xFFFF7B72), fontSize: 13)),
          ],
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: _busy ? null : _connect,
            icon: _busy
                ? const SizedBox(
                    width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.login_rounded, size: 18),
            label: Text(_busy ? 'Проверяю…' : 'Подключиться'),
          ),
          const SizedBox(height: 12),
          const Text(
            'Hub поднимается скриптом на ПК: backend\\start.ps1. '
            'Токен и адрес он печатает в консоль.',
            style: TextStyle(color: kMuted, fontSize: 12, height: 1.4),
          ),
        ],
      ),
    );
  }
}
