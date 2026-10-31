import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

enum AcpState { connecting, open, closed }

class AcpServerRequest {
  AcpServerRequest({required this.id, required this.method, required this.params});
  final int id;
  final String method;
  final Map<String, dynamic> params;
}

/// One ACP-over-WebSocket connection, bound to one bridge instance for its
/// whole lifetime (hub contract). Reconnection means building a new client.
class AcpClient {
  AcpClient({
    required this.hubUrl,
    required this.token,
    required this.instanceId,
    required this.onState,
    required this.onSessionUpdate,
    required this.onServerRequest,
    required this.onCancelRequest,
    this.onTurnState,
  });

  final String hubUrl;
  final String token;
  final String instanceId;

  final void Function(AcpState state) onState;
  final void Function(String sessionId, Map<String, dynamic> update, Map<String, dynamic>? meta)
      onSessionUpdate;
  final void Function(AcpServerRequest request, void Function(Object? result) respond) onServerRequest;
  final void Function(int requestId) onCancelRequest;
  final void Function(String sessionId, bool running, Map<String, dynamic>? extra)? onTurnState;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  int _nextId = 1;
  final Map<int, Completer<dynamic>> _pending = {};
  bool _closedByUs = false;
  bool _open = false;

  bool get isOpen => _open;

  Uri buildUri() {
    final base = Uri.parse(hubUrl.trim());
    final secure = base.scheme == 'https' || base.scheme == 'wss';
    var path = base.path.replaceAll(RegExp(r'/+$'), '');
    path = '$path/acp';
    final query = Map<String, String>.from(base.queryParameters);
    query['instance'] = instanceId;
    // Browsers cannot set WS headers; the hub accepts ?token= for every client.
    query['token'] = token;
    return base.replace(
      scheme: secure ? 'wss' : 'ws',
      path: path.isEmpty ? '/acp' : path,
      queryParameters: query,
    );
  }

  Future<Map<String, dynamic>> connect() async {
    onState(AcpState.connecting);
    final channel = WebSocketChannel.connect(buildUri());
    _channel = channel;
    try {
      await channel.ready.timeout(const Duration(seconds: 15));
    } catch (e) {
      _open = false;
      await _shutdown();
      onState(AcpState.closed);
      throw Exception('Не удалось подключиться к hub: $e');
    }
    _sub = channel.stream.listen(
      _handleData,
      onError: (Object e) {
        _open = false;
        onState(AcpState.closed);
      },
      onDone: () {
        _open = false;
        if (!_closedByUs) onState(AcpState.closed);
      },
      cancelOnError: false,
    );
    final result = await request('initialize', {
      'protocolVersion': 1,
      'clientCapabilities': <String, dynamic>{},
      'clientInfo': {'name': 'zcode-fold', 'title': 'ZCode Fold', 'version': '0.1.0'},
    });
    _open = true;
    onState(AcpState.open);
    return result is Map<String, dynamic> ? result : <String, dynamic>{};
  }

  Future<dynamic> request(String method, [Map<String, dynamic> params = const {}]) {
    final ch = _channel;
    if (ch == null) return Future.error(Exception('Нет соединения'));
    final id = _nextId++;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    ch.sink.add(jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    }));
    return completer.future;
  }

  void notify(String method, [Map<String, dynamic> params = const {}]) {
    _channel?.sink.add(jsonEncode({'jsonrpc': '2.0', 'method': method, 'params': params}));
  }

  void respond(int id, Object? result) {
    _channel?.sink.add(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}));
  }

  Future<void> close() async {
    _closedByUs = true;
    await _shutdown();
    onState(AcpState.closed);
  }

  Future<void> _shutdown() async {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(Exception('Соединение закрыто'));
    }
    _pending.clear();
    await _sub?.cancel();
    _sub = null;
    await _channel?.sink.close();
    _channel = null;
  }

  void _handleData(dynamic data) {
    if (data is! String) return;
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(data) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final method = msg['method'];
    if (method is String) {
      final id = msg['id'];
      if (id is num) {
        onServerRequest(
          AcpServerRequest(
            id: id.toInt(),
            method: method,
            params: (msg['params'] as Map?)?.cast<String, dynamic>() ?? const {},
          ),
          (result) => respond(id.toInt(), result),
        );
        return;
      }
      final params = (msg['params'] as Map?)?.cast<String, dynamic>();
      if (method == 'session/update') {
        final sessionId = params?['sessionId'];
        final update = params?['update'];
        if (sessionId is String && update is Map) {
          final meta = (msg['_meta'] as Map?)?.cast<String, dynamic>() ??
              (params?['_meta'] as Map?)?.cast<String, dynamic>();
          onSessionUpdate(sessionId, update.cast<String, dynamic>(), meta);
        }
      } else if (method == r'$/zcode/turnState' || method == '_zcode/turnState') {
        final sessionId = params?['sessionId'];
        final running = params?['running'];
        if (sessionId is String && running is bool) {
          onTurnState?.call(sessionId, running, params);
        }
      } else if (method == r'$/cancel_request') {
        final id = (params?['id'] as num?)?.toInt();
        if (id != null) onCancelRequest(id);
      }
      return;
    }
    final id = msg['id'];
    if (id is num) {
      final completer = _pending.remove(id.toInt());
      if (completer == null || completer.isCompleted) return;
      final error = msg['error'];
      if (error is Map) {
        completer.completeError(Exception(error['message']?.toString() ?? 'Ошибка ACP'));
      } else {
        completer.complete(msg['result']);
      }
    }
  }
}
