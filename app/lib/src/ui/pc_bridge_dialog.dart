import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import 'theme.dart';

/// Remote setup of the PC file bridge from the phone.
///
/// The phone only stores the URL/token and verifies them with `GET /health`;
/// the bridge itself runs on the computer (`node tools/bridge.mjs --serve`).
/// Returns true when the values were saved.
Future<bool> showPcBridgeDialog(
  BuildContext context,
  AppState state, {
  String? intro,
}) async {
  final urlCtrl = TextEditingController(text: state.bridgeFsUrl ?? '');
  final tokenCtrl = TextEditingController();
  final status = ValueNotifier<String?>(null);
  var busy = false;

  final saved = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) {
        Future<void> check() async {
          setState(() {
            busy = true;
            status.value = null;
          });
          try {
            final health = await state.pcHealthFor(
              urlCtrl.text,
              tokenCtrl.text,
            );
            status.value =
                '✅ ${health['name'] ?? 'ПК'} · ${health['root'] ?? ''}';
          } catch (e) {
            status.value = '⚠️ ${e.toString().replaceFirst('Exception: ', '')}';
          } finally {
            if (context.mounted) setState(() => busy = false);
          }
        }

        Future<void> save() async {
          setState(() => busy = true);
          await state.setBridgeFiles(urlCtrl.text, tokenCtrl.text);
          if (dialogContext.mounted) Navigator.pop(dialogContext, true);
        }

        return AlertDialog(
          backgroundColor: Pal.surface,
          title: const Text('ПК удалённо', style: TextStyle(fontSize: 16)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  intro ??
                      'На компьютере запусти в папке проекта:\n'
                          'node tools/bridge.mjs --serve\n\n'
                          'Скрипт напечатает URL и токен. Телефону нужен доступ '
                          'к этому адресу по сети (или adb reverse).',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: Pal.muted,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: urlCtrl,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  style: const TextStyle(fontSize: 12.5),
                  decoration: InputDecoration(
                    labelText: 'URL моста',
                    hintText: 'http://192.168.x.x:8939',
                    isDense: true,
                    suffixIcon: IconButton(
                      tooltip: 'Вставить',
                      icon: const Icon(Icons.content_paste_rounded, size: 17),
                      onPressed: () async {
                        final data = await Clipboard.getData('text/plain');
                        final text = data?.text?.trim() ?? '';
                        if (text.isEmpty) return;
                        urlCtrl.text = text;
                        setState(() {});
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: tokenCtrl,
                  obscureText: true,
                  autocorrect: false,
                  style: const TextStyle(fontSize: 12.5),
                  decoration: InputDecoration(
                    labelText: 'Токен',
                    hintText: 'bridge-fs.token',
                    helperText: state.hasPcFiles
                        ? 'Оставь пустым, чтобы сохранить текущий токен'
                        : null,
                    helperMaxLines: 2,
                    isDense: true,
                    suffixIcon: IconButton(
                      tooltip: 'Вставить',
                      icon: const Icon(Icons.content_paste_rounded, size: 17),
                      onPressed: () async {
                        final data = await Clipboard.getData('text/plain');
                        final text = data?.text?.trim() ?? '';
                        if (text.isEmpty) return;
                        tokenCtrl.text = text;
                        setState(() {});
                      },
                    ),
                  ),
                ),
                if (status.value != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      status.value!,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.4,
                        color: status.value!.startsWith('✅')
                            ? Pal.accent
                            : const Color(0xFFE3B341),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy
                  ? null
                  : () => Navigator.pop(dialogContext, false),
              child: const Text('Отмена'),
            ),
            TextButton(
              onPressed: busy ? null : check,
              child: const Text('Проверить'),
            ),
            FilledButton(
              onPressed: busy ? null : save,
              child: const Text('Сохранить'),
            ),
          ],
        );
      },
    ),
  );
  urlCtrl.dispose();
  tokenCtrl.dispose();
  status.dispose();
  return saved ?? false;
}
