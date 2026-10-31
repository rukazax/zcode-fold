// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final token = Platform.environment['HUB_TOKEN']!;
  final instance = Platform.environment['INSTANCE_ID']!;
  final uri = Uri.parse('ws://127.0.0.1:8377/acp?instance=$instance&token=$token');
  print('connecting $uri');
  final ws = await WebSocket.connect(uri.toString());
  print('open');
  final done = Completer<void>();
  ws.listen((data) {
    final msg = jsonDecode(data as String) as Map<String, dynamic>;
    if (msg['id'] == 1) {
      print('init: ${jsonEncode(msg['result']).substring(0, 120)}');
      ws.add(jsonEncode({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'session/list',
        'params': <String, dynamic>{}
      }));
    } else if (msg['id'] == 2) {
      print('sessions: ${jsonEncode(msg['result']).substring(0, 200)}');
      done.complete();
    } else if (msg['method'] != null) {
      print('notify ${msg['method']}');
    }
  });
  ws.add(jsonEncode({
    'jsonrpc': '2.0',
    'id': 1,
    'method': 'initialize',
    'params': {
      'protocolVersion': 1,
      'clientCapabilities': <String, dynamic>{},
    }
  }));
  await done.future.timeout(const Duration(seconds: 20));
  await ws.close();
  print('done');
}
