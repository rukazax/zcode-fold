import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'acp_client.dart';
import 'hub_api.dart';
import 'models.dart';

class AppState extends ChangeNotifier {
  AppState(this._prefs, this._secure);

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;

  static const _kProfiles = 'profiles';
  static const _kLastProfile = 'last_profile';
  static const _kDrafts = 'drafts';
  static const _tokenPrefix = 'hub_token_';

  final List<ServerProfile> profiles = [];
  ServerProfile? activeProfile;

  HubApi? _hub;
  AcpClient? _client;

  List<HubInstance> instances = const [];
  bool loadingInstances = false;
  String? instancesError;

  bool connecting = false;
  String? connectError;

  String? instanceId;
  String? sessionId;
  String? sessionCwd;
  String? sessionTitle;
  String? attachedWorkspace;

  bool connected = false;
  bool running = false;
  Timer? _pollTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _closingSession = false;
  bool _connectingInFlight = false;

  final List<ChatMessage> messages = [];
  UsageInfo? usage;
  List<ConfigOption> configs = const [];
  List<SlashCommand> commands = const [];
  List<PlanEntry> plan = const [];
  PendingPermission? permission;
  String? lastError;

  bool get hasSession => sessionId != null;

  bool get connectionsHealthy =>
      _hub != null && connectError == null && instancesError == null;

  String get workspaceLabel {
    final ws = attachedWorkspace;
    if (ws == null) return '';
    final parts = ws.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).toList();
    return parts.isEmpty ? ws : parts.last;
  }

  Future<void> init() async {
    await _loadProfiles();
    if (profiles.isNotEmpty) {
      activeProfile = profiles.first;
      await _attachProfile(activeProfile!, quiet: true);
    }
    notifyListeners();
  }

  Future<void> _loadProfiles() async {
    final raw = _prefs.getString(_kProfiles);
    profiles.clear();
    if (raw != null) {
      try {
        final list = jsonDecode(raw);
        if (list is List) {
          for (final item in list.whereType<Map<String, dynamic>>()) {
            final id = item['id'] as String? ?? '';
            final token = await _secure.read(key: '$_tokenPrefix$id') ?? '';
            profiles.add(ServerProfile.fromJson(item, token: token));
          }
        }
      } catch (_) {}
    }
    if (profiles.isEmpty) return;
    final last = _prefs.getString(_kLastProfile);
    final match = profiles.where((p) => p.id == last).toList();
    if (match.isNotEmpty) activeProfile = match.first;
  }

  Future<void> _saveProfiles() async {
    final list = profiles.map((p) => p.toJson(withToken: false)).toList();
    await _prefs.setString(_kProfiles, jsonEncode(list));
    for (final p in profiles) {
      await _secure.write(key: '$_tokenPrefix${p.id}', value: p.token);
    }
  }

  Future<String?> validateConnection(String hubUrl, String token) async {
    try {
      final api = HubApi(baseUrl: hubUrl, token: token);
      await api.health();
      await api.instances();
      return null;
    } catch (e) {
      return e.toString().replaceFirst('Exception: ', '');
    }
  }

  Future<void> addProfile(String name, String hubUrl, String token) async {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final normalized = _normalizeUrl(hubUrl);
    final profile = ServerProfile(id: id, name: name.trim().isEmpty ? _hostOf(normalized) : name.trim(), hubUrl: normalized, token: token.trim());
    profiles.add(profile);
    await _saveProfiles();
    await _prefs.setString(_kLastProfile, profile.id);
    activeProfile = profile;
    notifyListeners();
    await _attachProfile(profile);
  }

  Future<void> removeProfile(ServerProfile profile) async {
    profiles.removeWhere((p) => p.id == profile.id);
    await _secure.delete(key: '$_tokenPrefix${profile.id}');
    await _saveProfiles();
    if (activeProfile?.id == profile.id) {
      await _detach();
      activeProfile = profiles.isEmpty ? null : profiles.first;
      if (activeProfile != null) {
        await _prefs.setString(_kLastProfile, activeProfile!.id);
        await _attachProfile(activeProfile!, quiet: true);
      }
    }
    notifyListeners();
  }

  Future<void> selectProfile(ServerProfile profile) async {
    if (activeProfile?.id == profile.id) return;
    await _detach();
    activeProfile = profile;
    await _prefs.setString(_kLastProfile, profile.id);
    notifyListeners();
    await _attachProfile(profile);
  }

  String _normalizeUrl(String input) {
    var s = input.trim();
    if (s.isEmpty) return s;
    if (!s.startsWith('http://') && !s.startsWith('https://') && !s.startsWith('ws://') && !s.startsWith('wss://')) {
      s = 'http://$s';
    }
    return s.replaceAll(RegExp(r'/+$'), '');
  }

  String _hostOf(String url) {
    try {
      return Uri.parse(url).host;
    } catch (_) {
      return url;
    }
  }

  Future<void> _attachProfile(ServerProfile profile, {bool quiet = false}) async {
    _hub = HubApi(baseUrl: profile.hubUrl, token: profile.token);
    connecting = !quiet;
    connectError = null;
    notifyListeners();
    try {
      await _hub!.health();
      await refreshInstances();
      _startPolling();
    } catch (e) {
      connectError = e.toString().replaceFirst('Exception: ', '');
      instances = const [];
    } finally {
      connecting = false;
      notifyListeners();
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (_hub != null && sessionId == null) refreshInstances(quiet: true);
    });
  }

  Future<void> refreshInstances({bool quiet = false}) async {
    if (_hub == null) return;
    if (!quiet) {
      loadingInstances = true;
      instancesError = null;
      notifyListeners();
    }
    try {
      final list = await _hub!.instances();
      instances = list;
      instancesError = null;
    } catch (e) {
      instancesError = e.toString().replaceFirst('Exception: ', '');
    } finally {
      loadingInstances = false;
      notifyListeners();
    }
  }

  Future<void> openSession(HubInstance instance, HubSessionInfo info) async {
    await _closeClient();
    messages.clear();
    permission = null;
    usage = null;
    plan = const [];
    configs = const [];
    commands = const [];
    sessionId = null;
    instanceId = instance.id;
    sessionCwd = instance.workspace;
    attachedWorkspace = instance.workspace;
    sessionTitle = info.title;
    sessionId = info.sessionId;
    connectError = null;
    notifyListeners();
    await _connectAndLoad(load: true);
  }

  Future<void> newSession(HubInstance instance) async {
    await _closeClient();
    messages.clear();
    permission = null;
    usage = null;
    plan = const [];
    configs = const [];
    commands = const [];
    instanceId = instance.id;
    sessionCwd = instance.workspace;
    attachedWorkspace = instance.workspace;
    sessionTitle = 'Новый чат';
    sessionId = null;
    notifyListeners();
    await _connectAndLoad(load: false);
  }

  Future<void> _connectAndLoad({required bool load}) async {
    final profile = activeProfile;
    final inst = instanceId;
    if (profile == null || inst == null) return;
    if (_connectingInFlight) return;
    _connectingInFlight = true;
    _reconnectTimer?.cancel();
    final client = AcpClient(
      hubUrl: profile.hubUrl,
      token: profile.token,
      instanceId: inst,
      onState: (state) {
        connected = state == AcpState.open;
        notifyListeners();
        if (state == AcpState.closed && hasSession && !_closingSession) {
          _scheduleReconnect();
        }
      },
      onSessionUpdate: _handleUpdate,
      onServerRequest: _handleServerRequest,
      onCancelRequest: (id) {
        if (permission?.requestId == id) {
          permission = null;
          notifyListeners();
        }
      },
      onTurnState: (sid, isRunning, extra) {
        if (sid != sessionId) return;
        running = isRunning;
        if (!isRunning && extra?['usage'] is Map) {
          final u = (extra!['usage'] as Map);
          final used = (u['totalTokens'] as num?)?.toInt();
          if (used != null && usage != null) usage = UsageInfo(used, usage!.size);
        }
        notifyListeners();
      },
    );
    _client = client;
    try {
      await client.connect();
      if (load) {
        final result = await client.request('session/load', {
          'sessionId': sessionId,
          'cwd': sessionCwd ?? '',
          'mcpServers': <dynamic>[],
        });
        _applySessionMeta(result);
      } else {
        final result = await client.request('session/new', {
          'cwd': sessionCwd,
          'mcpServers': <dynamic>[],
        });
        if (result is Map && result['sessionId'] is String) {
          sessionId = result['sessionId'] as String;
        }
        _applySessionMeta(result);
      }
      _reconnectAttempt = 0;
      connectError = null;
    } catch (e) {
      connectError = e.toString().replaceFirst('Exception: ', '');
    }
    _connectingInFlight = false;
    notifyListeners();
  }

  /// Called when the app returns to the foreground or the network changes.
  /// Android can freeze the socket without closing it, so a zombie connection
  /// has to be replaced rather than waited on.
  Future<void> onAppResumed() async {
    if (!hasSession) {
      if (_hub != null) await refreshInstances(quiet: true);
      return;
    }
    if (connected || _connectingInFlight) return;
    _reconnectTimer?.cancel();
    await _closeClient();
    messages.clear();
    usage = null;
    notifyListeners();
    await _connectAndLoad(load: true);
  }

  void _applySessionMeta(dynamic result) {
    if (result is! Map) return;
    final opts = result['configOptions'];
    if (opts is List) {
      configs = opts
          .whereType<Map>()
          .map((m) => ConfigOption.fromJson(m.cast<String, dynamic>()))
          .toList();
    }
    final modes = result['modes'];
    if (modes is Map && modes['availableModes'] is List) {
      final list = (modes['availableModes'] as List).whereType<Map>();
      final existing = configs.where((c) => c.id == 'mode').toList();
    if (existing.isEmpty) {
      configs = [
        ...configs,
        ConfigOption(
          id: 'mode',
          name: 'Режим',
          currentValue: modes['currentModeId']?.toString(),
          options: list
              .map((m) => ConfigOptionValue(
                    value: m['id']?.toString() ?? '',
                    name: m['name']?.toString() ?? m['id']?.toString() ?? '',
                  ))
              .toList(),
        ),
      ];
    }
    }
  }

  void _scheduleReconnect() {
    if (_reconnectTimer?.isActive ?? false) return;
    final delay = Duration(seconds: [1, 2, 4, 8, 15, 30][_reconnectAttempt.clamp(0, 5)]);
    _reconnectAttempt++;
    _reconnectTimer = Timer(delay, () async {
      if (!hasSession || _closingSession) return;
      await _closeClient();
      if (hasSession) {
        // Replay rebuilds the thread, so drop the local copy first.
        messages.clear();
        usage = null;
        notifyListeners();
        await _connectAndLoad(load: true);
      }
    });
  }

  Future<void> _closeClient() async {
    final c = _client;
    _client = null;
    connected = false;
    if (c != null) await c.close();
  }

  Future<void> closeSession() async {
    _closingSession = true;
    _reconnectTimer?.cancel();
    _pollTimer?.cancel();
    await _closeClient();
    sessionId = null;
    instanceId = null;
    sessionCwd = null;
    sessionTitle = null;
    attachedWorkspace = null;
    messages.clear();
    permission = null;
    usage = null;
    plan = const [];
    configs = const [];
    commands = const [];
    running = false;
    _closingSession = false;
    _startPolling();
    notifyListeners();
  }

  Future<void> _detach() async {
    await closeSession();
    _pollTimer?.cancel();
    _hub = null;
  }

  Future<void> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || sessionId == null || _client == null) return;
    final msg = ChatMessage(id: 'u_${DateTime.now().microsecondsSinceEpoch}', role: 'user')
      ..parts.add(ChatPart.text(trimmed));
    messages.add(msg);
    running = true;
    notifyListeners();
    try {
      await _client!.request('session/prompt', {
        'sessionId': sessionId,
        'prompt': [
          {'type': 'text', 'text': trimmed}
        ],
      });
      running = false;
      notifyListeners();
    } catch (e) {
      lastError = e.toString().replaceFirst('Exception: ', '');
      running = false;
      notifyListeners();
    }
  }

  Future<void> cancelTurn() async {
    if (sessionId == null || _client == null) return;
    _client!.notify('session/cancel', {'sessionId': sessionId});
  }

  Future<void> setConfig(String configId, String value) async {
    if (sessionId == null || _client == null) return;
    final index = configs.indexWhere((c) => c.id == configId);
    if (index >= 0) {
      configs[index].currentValue = value;
      notifyListeners();
    }
    try {
      await _client!.request('session/set_config_option', {
        'sessionId': sessionId,
        'configId': configId,
        'value': value,
      });
    } catch (e) {
      lastError = e.toString().replaceFirst('Exception: ', '');
      notifyListeners();
    }
  }

  void respondPermission(String? optionId) {
    final p = permission;
    if (p == null) return;
    if (optionId == null) {
      _client?.respond(p.requestId, {
        'outcome': {'outcome': 'cancelled'}
      });
    } else {
      _client?.respond(p.requestId, {
        'outcome': {'outcome': 'selected', 'optionId': optionId}
      });
    }
    permission = null;
    notifyListeners();
  }

  void _handleServerRequest(AcpServerRequest req, void Function(Object?) respond) {
    if (req.method == 'session/request_permission') {
      final toolCall = (req.params['toolCall'] as Map?)?.cast<String, dynamic>();
      final options = (req.params['options'] as List? ?? [])
          .whereType<Map>()
          .map((m) => PermissionOption(
                id: m['optionId']?.toString() ?? m['id']?.toString() ?? '',
                name: m['name']?.toString() ?? m['optionId']?.toString() ?? '',
                kind: m['kind']?.toString(),
              ))
          .where((o) => o.id.isNotEmpty)
          .toList();
      permission = PendingPermission(
        requestId: req.id,
        title: toolCall?['title']?.toString() ?? 'Нужно подтверждение',
        detail: _toolDetail(toolCall),
        options: options,
      );
      notifyListeners();
      return;
    }
    // We do not declare elicitation support; decline anything else cleanly.
    respond({
      'outcome': {'outcome': 'cancelled'}
    });
  }

  String? _toolDetail(Map<String, dynamic>? toolCall) {
    if (toolCall == null) return null;
    final content = toolCall['content'];
    final blocks = content is List ? content : [content];
    final buffer = StringBuffer();
    for (final b in blocks) {
      if (b is Map) {
        if (b['type'] == 'text' && b['text'] is String) buffer.writeln(b['text']);
        if (b['type'] == 'diff' && b['path'] != null) buffer.writeln('diff: ${b['path']}');
      } else if (b is String) {
        buffer.writeln(b);
      }
    }
    final raw = toolCall['rawInput'];
    if (buffer.isEmpty && raw is Map) {
      final cmd = raw['command'] ?? raw['cmd'] ?? raw['path'];
      if (cmd != null) buffer.writeln(cmd);
    }
    final text = buffer.toString().trim();
    return text.isEmpty ? null : text;
  }

  void _handleUpdate(String sid, Map<String, dynamic> update, Map<String, dynamic>? meta) {
    if (sessionId != null && sid != sessionId) return;
    sessionId ??= sid;
    final kind = update['sessionUpdate']?.toString() ?? '';
    final collapsed = _isCollapsed(meta);
    switch (kind) {
      case 'user_message_chunk':
        _appendUser(_contentText(update['content']), collapsed: collapsed);
        break;
      case 'agent_message_chunk':
        _appendAssistant(_contentText(update['content']));
        break;
      case 'agent_thought_chunk':
        _appendThought(_contentText(update['content']));
        break;
      case 'tool_call':
        _upsertTool(update);
        break;
      case 'tool_call_update':
        _upsertTool(update, isUpdate: true);
        break;
      case 'plan':
        final entries = update['entries'];
        if (entries is List) {
          plan = entries
              .whereType<Map>()
              .map((m) => PlanEntry(
                    content: m['content']?.toString() ?? '',
                    status: m['status']?.toString() ?? 'pending',
                    priority: m['priority']?.toString(),
                  ))
              .toList();
        }
        break;
      case 'usage_update':
        final used = (update['used'] as num?)?.toInt() ?? 0;
        final size = (update['size'] as num?)?.toInt() ?? 0;
        if (size > 0) usage = UsageInfo(used, size);
        break;
      case 'config_option_update':
        final opts = update['configOptions'];
        if (opts is List) {
          configs = opts
              .whereType<Map>()
              .map((m) => ConfigOption.fromJson(m.cast<String, dynamic>()))
              .toList();
        }
        break;
      case 'available_commands_update':
        final list = update['availableCommands'];
        if (list is List) {
          commands = list
              .whereType<Map>()
              .map((m) => SlashCommand.fromJson(m.cast<String, dynamic>()))
              .toList();
        }
        break;
      case 'session_info_update':
        final title = update['title'];
        if (title is String && title.trim().isNotEmpty) sessionTitle = title.trim();
        break;
    }
    notifyListeners();
  }

  bool _isCollapsed(Map<String, dynamic>? meta) {
    if (meta == null) return false;
    if (meta['collapsed'] == true) return true;
    final z = meta['zcode'];
    return z is Map && z['collapsed'] == true;
  }

  String _contentText(dynamic content) {
    if (content == null) return '';
    final blocks = content is List ? content : [content];
    final buffer = StringBuffer();
    for (final b in blocks) {
      if (b is Map) {
        if (b['type'] == 'text' && b['text'] is String) {
          buffer.write(b['text']);
        } else if (b['type'] == 'content' && b['content'] is Map && b['content']['text'] is String) {
          buffer.write(b['content']['text']);
        }
      } else if (b is String) {
        buffer.write(b);
      }
    }
    return buffer.toString();
  }

  ChatMessage _ensureAssistant() {
    if (messages.isNotEmpty && messages.last.role == 'assistant') {
      return messages.last;
    }
    final m = ChatMessage(id: 'a_${DateTime.now().microsecondsSinceEpoch}', role: 'assistant');
    messages.add(m);
    return m;
  }

  void _appendUser(String text, {bool collapsed = false}) {
    if (text.isEmpty) return;
    ChatMessage target;
    if (messages.isNotEmpty && messages.last.isUser) {
      target = messages.last;
    } else {
      target = ChatMessage(id: 'u_${DateTime.now().microsecondsSinceEpoch}', role: 'user');
      messages.add(target);
    }
    if (collapsed) target.collapsed = true;
    final parts = target.parts;
    if (parts.isNotEmpty && parts.last.type == 'text') {
      parts.last.text += text;
    } else {
      parts.add(ChatPart.text(text));
    }
  }

  void _appendAssistant(String text) {
    if (text.isEmpty) return;
    final m = _ensureAssistant();
    if (m.parts.isNotEmpty && m.parts.last.type == 'text') {
      m.parts.last.text += text;
    } else {
      m.parts.add(ChatPart.text(text));
    }
  }

  void _appendThought(String text) {
    if (text.isEmpty) return;
    final m = _ensureAssistant();
    if (m.parts.isNotEmpty && m.parts.last.type == 'thought') {
      m.parts.last.text += text;
    } else {
      m.parts.add(ChatPart.thought(text));
    }
  }

  ToolCallData? _findTool(String id) {
    for (final m in messages) {
      for (final p in m.parts) {
        if (p.type == 'tool' && p.tool?.id == id) return p.tool;
      }
    }
    return null;
  }

  void _upsertTool(Map<String, dynamic> update, {bool isUpdate = false}) {
    final id = update['toolCallId']?.toString() ?? '';
    if (id.isEmpty) return;
    final existing = _findTool(id);
    final content = update['content'];
    final text = _toolContentText(content);
    if (existing != null) {
      if (update['title'] is String && (update['title'] as String).trim().isNotEmpty) {
        existing.title = update['title'] as String;
      }
      if (update['kind'] is String) existing.kind = update['kind'] as String;
      if (update['status'] is String) existing.status = update['status'] as String;
      if (text.isNotEmpty) {
        existing.text = existing.text.isEmpty ? text : '${existing.text}\n$text';
      }
      if (update['rawInput'] != null) existing.rawInput = update['rawInput'];
      return;
    }
    final m = _ensureAssistant();
    m.parts.add(ChatPart.tool(ToolCallData(
      id: id,
      title: update['title']?.toString() ?? 'Инструмент',
      kind: update['kind']?.toString(),
      status: update['status']?.toString() ?? 'in_progress',
      text: text,
      rawInput: update['rawInput'],
    )));
  }

  String _toolContentText(dynamic content) {
    if (content == null) return '';
    final blocks = content is List ? content : [content];
    final buffer = StringBuffer();
    for (final b in blocks) {
      if (b is Map) {
        if (b['type'] == 'text' && b['text'] is String) {
          buffer.writeln(b['text']);
        } else if (b['type'] == 'content' && b['content'] is Map && b['content']['text'] is String) {
          buffer.writeln(b['content']['text']);
        } else if (b['type'] == 'diff' && b['path'] != null) {
          buffer.writeln('Изменён файл: ${b['path']}');
        }
      } else if (b is String) {
        buffer.writeln(b);
      }
    }
    return buffer.toString().trim();
  }

  String? draftFor(String? sid) {
    if (sid == null) return null;
    final raw = _prefs.getString(_kDrafts);
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw);
      if (map is Map) return map[sid]?.toString();
    } catch (_) {}
    return null;
  }

  Future<void> saveDraft(String? sid, String text) async {
    if (sid == null) return;
    Map<String, dynamic> map = {};
    final raw = _prefs.getString(_kDrafts);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) map = Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    if (text.trim().isEmpty) {
      map.remove(sid);
    } else {
      map[sid] = text;
    }
    await _prefs.setString(_kDrafts, jsonEncode(map));
  }

  void clearError() {
    lastError = null;
    connectError = null;
    notifyListeners();
  }

  String? takeLastError() {
    final e = lastError;
    lastError = null;
    return e;
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _reconnectTimer?.cancel();
    _client?.close();
    super.dispose();
  }
}
