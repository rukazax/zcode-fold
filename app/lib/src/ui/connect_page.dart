import 'package:flutter/material.dart';

import '../app_state.dart';
import 'fold_layout.dart';
import 'qr_scan_page.dart';
import 'theme.dart';

class ConnectPage extends StatefulWidget {
  const ConnectPage({super.key, required this.state});

  final AppState state;

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  final _url = TextEditingController();
  final _name = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScanPage()),
    );
    if (code != null && code.trim().isNotEmpty) {
      _url.text = code.trim();
      setState(() => _error = null);
      await _connect();
    }
  }

  Future<void> _connect() async {
    final url = _url.text.trim();
    final problem = AppState.validateLink(url);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    await widget.state.addDevice(_name.text, url);
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
              constraints: BoxConstraints(maxWidth: wide ? 880 : 460),
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: _brand()),
                        const SizedBox(width: 32),
                        Expanded(child: _form()),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [_brand(), const SizedBox(height: 28), _form()],
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _brand() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 56,
          height: 56,
          decoration:
              BoxDecoration(color: kAccent, borderRadius: BorderRadius.circular(16)),
          alignment: Alignment.center,
          child: const Text('Z',
              style: TextStyle(
                  color: Color(0xFF06231A), fontSize: 30, fontWeight: FontWeight.w900)),
        ),
        const SizedBox(height: 20),
        const Text('ZCode Fold',
            style: TextStyle(
                fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: -0.8)),
        const SizedBox(height: 8),
        const Text(
          'Прямое подключение к штатному «Мобильному доступу» ZCode. '
          'Никаких серверов и надстроек: телефон говорит с твоим компьютером '
          'через официальный relay, как это делает мобильная веб-панель.',
          style: TextStyle(color: kMuted, height: 1.5, fontSize: 14),
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _chip(Icons.qr_code_2_rounded, 'QR с компьютера'),
            _chip(Icons.lock_outline, 'ссылка в Keystore'),
            _chip(Icons.devices_fold_outlined,
                'две колонки на раскладке'),
          ],
        ),
        if (widget.state.devices.isNotEmpty) ...[
          const SizedBox(height: 24),
          const Text('Сохранённые компьютеры',
              style: TextStyle(color: kMuted, fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          ...widget.state.devices.map((device) => Card(
                color: kSurface,
                margin: const EdgeInsets.only(bottom: 8),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: const BorderSide(color: kBorder)),
                child: ListTile(
                  leading: const Icon(Icons.computer_rounded, color: kAccent),
                  title: Text(device.name),
                  subtitle: Text(
                    _linkHint(device.url),
                    style: const TextStyle(color: kMuted, fontSize: 12),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20, color: kMuted),
                    onPressed: () => widget.state.removeDevice(device),
                  ),
                  onTap: _busy ? null : () => widget.state.selectDevice(device),
                ),
              )),
        ],
      ],
    );
  }

  String _linkHint(String url) {
    final parsed = Uri.tryParse(url);
    if (parsed == null) return 'ссылка';
    final mid = parsed.queryParameters['name'] ??
        parsed.queryParameters['mid'] ??
        parsed.host;
    return '$mid · ${parsed.path}';
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
          const Text('Подключить компьютер',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          const Text(
            'В ZCode на компьютере открой мобильный доступ и покажи QR-код (или '
            'скопируй ссылку). Ссылка действует, пока включён мобильный доступ.',
            style: TextStyle(color: kMuted, fontSize: 12, height: 1.45),
          ),
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
            autocorrect: false,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Ссылка или QR',
              hintText: 'https://zcode.z.ai/remote/v4?sid=…&hash=…&t=…',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Color(0xFFFF7B72), fontSize: 13)),
          ],
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _connect,
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.login_rounded, size: 18),
                  label: Text(_busy ? 'Подключаюсь…' : 'Подключиться'),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: _busy ? null : _scan,
                icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                label: const Text('QR'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            '⚠️ Ссылка содержит ключ доступа к твоим сессиям. Не пересылай её '
            'и не публикуй скриншоты QR.',
            style: TextStyle(color: kMuted, fontSize: 11.5, height: 1.4),
          ),
        ],
      ),
    );
  }
}
