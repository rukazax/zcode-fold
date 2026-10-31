// ignore_for_file: avoid_print
// Headless smoke test for the app's ACP client (no Flutter UI involved).
// Usage:
//   HUB_URL=... HUB_TOKEN=... INSTANCE_ID=... CWD=... dart run tool/smoke.dart
import 'dart:io';

import 'package:zcode_fold/src/acp_client.dart';

Future<void> main() async {
  final hub = Platform.environment['HUB_URL'] ?? 'http://127.0.0.1:8377';
  final token = Platform.environment['HUB_TOKEN'] ?? '';
  final instance = Platform.environment['INSTANCE_ID'] ?? '';
  final cwd = Platform.environment['CWD'] ?? Directory.current.path;
  if (token.isEmpty || instance.isEmpty) {
    stderr.writeln('HUB_TOKEN and INSTANCE_ID are required');
    exit(2);
  }

  final client = AcpClient(
    hubUrl: hub,
    token: token,
    instanceId: instance,
    onState: (s) => print('[state] $s'),
    onSessionUpdate: (sid, update, meta) {
      final kind = update['sessionUpdate'];
      final content = update['content'];
      String text = '';
      if (content is Map && content['text'] is String) text = content['text'] as String;
      if (content is List) {
        text = content.map((c) => c is Map ? (c['text'] ?? '') : '').join();
      }
      print('[update] $kind ${text.isEmpty ? '' : text}'.trim());
    },
    onServerRequest: (req, respond) {
      print('[request] ${req.method}');
      respond({
        'outcome': {'outcome': 'cancelled'}
      });
    },
    onCancelRequest: (id) => print('[cancel] $id'),
    onTurnState: (sid, running, extra) => print('[turn] running=$running'),
  );

  await client.connect();
  final created = await client.request('session/new', {
    'cwd': cwd,
    'mcpServers': <dynamic>[],
  });
  final sessionId = (created as Map)['sessionId'] as String;
  print('[session] $sessionId');

  final result = await client.request('session/prompt', {
    'sessionId': sessionId,
    'prompt': [
      {'type': 'text', 'text': 'Ответь одним словом: привет'}
    ],
  });
  print('[done] $result');
  await client.close();
}
