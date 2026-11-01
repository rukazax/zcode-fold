import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'cloud_api.dart';
import 'models.dart';
import 'zcode/conversation.dart';
import 'zcode/connection_params.dart';
import 'zcode/relay_client.dart';
import 'zcode/zcode_client.dart';

/// Direct client for the stock ZCode "Mobile remote control".
///
/// Flow: QR/link (`https://zcode.z.ai/remote/v4?sid=…&hash=…`) → relay WS →
/// HMAC pairing → bootstrap workspaces → workspace bridge → Conversation V4
/// subscription. No hub, no extra server: the desktop app is the backend.
///
/// Token policy: everything the app does on its own — pairing, bootstrap,
/// workspace bridge, sessions-index and conversation subscriptions (all with
/// `runtimePolicy: existing-only`), row reads, model/mode switches, approvals —
/// is relay RPC, not agent turns. The GLM model is billed ONLY when a prompt
/// is explicitly sent via [send] / `createSession`; nothing in this class
/// ever triggers a turn on its own.
class AppState extends ChangeNotifier {
  AppState(this._prefs, this._secure);

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;

  static const _kDevices = 'devices';
  static const _kLastDevice = 'last_device';
  static const _urlPrefix = 'device_url_';
  static const _kJwt = 'zai_jwt';
  static const _kAccess = 'zai_access';

  final List<SavedDevice> devices = [];
  SavedDevice? activeDevice;

  String? _jwt;
  bool loginRequired = false;

  bool get hasJwt => _jwt != null && _jwt!.isNotEmpty;

  /// Called by the login WebView page once AWS JWT is captured.
  Future<void> setJwt(String value) async {
    _jwt = value.trim();
    loginRequired = false;
    await _secure.write(key: _kJwt, value: _jwt!);
    error = null;
    notifyListeners();
    if (activeDevice != null) await connect();
  }

  Future<void> clearJwt() async {
    _jwt = null;
    loginRequired = true;
    await _secure.delete(key: _kJwt);
    notifyListeners();
  }

  ZcodeRemoteClient? _client;
  BridgeSession? _bridge;
  ConversationTransport? _transport;
  SessionsIndexSubscription? _sessionsSub;
  ConversationSubscription? _convSub;

  final List<Map<String, dynamic>> workspaces = [];
  Map<String, dynamic>? workspace;
  WorkspacePrep? prep;

  RelayState relayState = RelayState.idle;
  String? relayError;
  bool connecting = false;
  bool openingSession = false;
  bool sending = false;
  String? error;

  String? sessionId;
  String? sessionTitle;
  bool draft = false;

  bool get hasOpenChat => sessionId != null || draft;

  Future<void> init() async {
    _jwt = await _secure.read(key: _kJwt);
    final raw = _prefs.getString(_kDevices);
    if (raw != null) {
      try {
        final list = jsonDecode(raw);
        if (list is List) {
          for (final item in list.whereType<Map<String, dynamic>>()) {
            final id = item['id'] as String? ?? '';
            final url = await _secure.read(key: '$_urlPrefix$id') ?? '';
            if (url.isNotEmpty) {
              devices.add(SavedDevice.fromJson(item, url: url));
            }
          }
        }
      } catch (_) {}
    }
    if (devices.isNotEmpty) {
      final last = _prefs.getString(_kLastDevice);
      activeDevice = devices.firstWhere(
        (d) => d.id == last,
        orElse: () => devices.first,
      );
    }
    notifyListeners();
    // Restore the last connection on cold start: the QR link is persistent, so
    // there is no reason to make the user tap "Переподключиться".
    if (activeDevice != null && hasJwt) {
      unawaited(connect());
    }
  }

  Future<void> _saveDevices() async {
    await _prefs.setString(
      _kDevices,
      jsonEncode(devices.map((d) => d.toJson()).toList()),
    );
    for (final device in devices) {
      await _secure.write(key: '$_urlPrefix${device.id}', value: device.url);
    }
  }

  /// Returns null when the link parses, otherwise a human error.
  static String? validateLink(String raw) {
    final parsed = RemoteConnectionParams.parse(raw);
    if (parsed == null) {
      return 'Это не похоже на ссылку ZCode Remote (нужен sid из свежего QR)';
    }
    return null;
  }

  Future<void> addDevice(String name, String url) async {
    final parsed = RemoteConnectionParams.parse(url)!;
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final label = name.trim().isNotEmpty
        ? name.trim()
        : (parsed.deviceName?.trim().isNotEmpty == true
            ? parsed.deviceName!.trim()
            : 'ZCode');
    final device = SavedDevice(id: id, name: label, url: url.trim());
    devices.add(device);
    await _saveDevices();
    await _prefs.setString(_kLastDevice, id);
    activeDevice = device;
    notifyListeners();
    await connect();
  }

  Future<void> removeDevice(SavedDevice device) async {
    devices.removeWhere((d) => d.id == device.id);
    await _secure.delete(key: '$_urlPrefix${device.id}');
    await _saveDevices();
    if (activeDevice?.id == device.id) {
      await _teardown();
      activeDevice = devices.isEmpty ? null : devices.first;
      if (activeDevice != null) {
        await _prefs.setString(_kLastDevice, activeDevice!.id);
        await connect();
      }
    }
    notifyListeners();
  }

  Future<void> selectDevice(SavedDevice device) async {
    if (activeDevice?.id == device.id && _client != null) return;
    await _teardown();
    activeDevice = device;
    await _prefs.setString(_kLastDevice, device.id);
    notifyListeners();
    await connect();
  }

  /// Called by the QR scanner when it lands on a desktop bridge URL:
  /// `http://<lan-ip>:8939/<pin>`. One-shot fetch of the same account's
  /// credentials; the bridge closes itself after a single serve.
  Future<void> consumeBridge(String rawUrl) async {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || uri.host.isEmpty) {
      error = 'Ссылка моста повреждена';
      notifyListeners();
      return;
    }
    connecting = true;
    error = null;
    notifyListeners();
    try {
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) {
        throw Exception('мост ответил ${res.statusCode}');
      }
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      final jwt = data['jwt'];
      if (jwt is! String || jwt.length < 40) {
        throw Exception('в ответе моста нет jwt');
      }
      await setJwt(jwt);
      if (data['access'] is String && (data['access'] as String).length > 40) {
        await _secure.write(key: _kAccess, value: data['access'] as String);
      }
    } catch (e) {
      connecting = false;
      error = _humanError(e);
      notifyListeners();
    }
  }

  Future<void> connect() async {
    final device = activeDevice;
    if (device == null) return;
    final params = RemoteConnectionParams.parse(device.url);
    if (params == null) {
      error = 'Ссылка повреждена — отсканируй QR на компьютере заново';
      notifyListeners();
      return;
    }
    await _teardown();
    connecting = true;
    relayError = null;
    error = null;
    notifyListeners();

    // New pairing (3.17+): every relay (re)connect mints a fresh ~60 s
    // terminal token with the account JWT. Legacy links (hash+t) keep the
    // self-contained HMAC path and never need the account.
    final legacy = params.passHash != null && params.passHash!.isNotEmpty;
    if (!legacy && !hasJwt) {
      connecting = false;
      loginRequired = true;
      error = 'Нужен вход в аккаунт Z.ai — он чеканит терминальный токен';
      notifyListeners();
      return;
    }
    Future<String> Function()? tokenProvider;
    if (!legacy) {
      tokenProvider = () async {
        try {
          return await ZcodeCloudApi(jwt: _jwt!).mintToken();
        } on TokenExpired {
          loginRequired = true;
          error = 'Сессия Z.ai устарела — войди заново';
          notifyListeners();
          rethrow;
        }
      };
    }

    final client = ZcodeRemoteClient(params, tokenProvider: tokenProvider);
    _client = client;
    client.relay.stateListenable.addListener(_onRelayState);
    client.relay.failures.listen((failure) {
      relayError = failure.toString();
      notifyListeners();
    });

    try {
      await client.connect();
      await client.waitPaired();
      final bootstrap = await client.bootstrap();
      final list = bootstrap['workspaces'];
      workspaces.clear();
      if (list is List) {
        for (final item in list.whereType<Map>()) {
          workspaces.add(item.cast<String, dynamic>());
        }
      }
      if (workspaces.isNotEmpty) {
        await openWorkspace(workspaces.first);
      } else {
        error = 'На компьютере не открыто ни одного рабочего пространства';
      }
    } catch (e) {
      error = _humanError(e);
    } finally {
      connecting = false;
      notifyListeners();
    }
  }

  void _onRelayState() {
    final client = _client;
    if (client == null) return;
    relayState = client.relay.state;
    if (relayState == RelayState.paired) relayError = null;
    notifyListeners();
  }

  String _humanError(Object e) {
    final text = e.toString().replaceFirst('Exception: ', '');
    if (text.contains('pairing timeout')) {
      return 'Компьютер не подтвердил подключение: включи мобильный доступ '
          'в ZCode и используй свежий QR-код';
    }
    return text;
  }

  static String? workspaceKeyOf(Map<String, dynamic> w) {
    final identity = w['workspaceIdentity'];
    if (identity is String && identity.trim().isNotEmpty) return identity.trim();
    final path = w['workspacePath'];
    if (path is String && path.isNotEmpty) return path;
    for (final key in const ['workspaceKey', 'key', 'id']) {
      final v = w[key];
      if (v is String && v.isNotEmpty) return v;
    }
    return null;
  }

  static String workspaceTitle(Map<String, dynamic> w) {
    final label = w['label'];
    if (label is String && label.trim().isNotEmpty) return label.trim();
    final key = workspaceKeyOf(w);
    if (key == null) return 'Проект';
    final parts = key.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).toList();
    return parts.isEmpty ? key : parts.last;
  }

  String get workspaceKey => workspace == null ? '' : (workspaceKeyOf(workspace!) ?? '');

  Map<String, dynamic> get _scope => {
        'workspacePath': workspace?['workspacePath'],
        if (workspace?['workspaceIdentity'] != null)
          'workspaceIdentity': workspace!['workspaceIdentity'],
      };

  Future<void> openWorkspace(Map<String, dynamic> w) async {
    if (workspaceKeyOf(w) == null || _client == null) return;
    await _disposeSession();
    workspace = w;
    _bridge?.dispose();
    _bridge = null;
    _transport = null;
    prep = null;
    notifyListeners();
    try {
      final bridge = await _client!.openBridge(
        workspaceKeyOf(w)!,
        timeout: const Duration(seconds: 45),
      );
      _bridge = bridge;
      _transport = bridge.conversation(_scope);
      final sub = await _transport!.subscribeSessionsIndex();
      _sessionsSub = sub;
      sub.state.addListener(_onSessionsChanged);
      _onSessionsChanged();
    } catch (e) {
      error = _humanError(e);
      notifyListeners();
    }
  }

  void _onSessionsChanged() {
    notifyListeners();
  }

  List<SessionSummary> get sessions {
    final sub = _sessionsSub;
    if (sub == null || !sub.state.ready) return const [];
    return sub.state.list.map((e) => SessionSummary.fromMap(e.raw)).toList();
  }

  bool get sessionsLoading => _sessionsSub != null && !_sessionsSub!.state.ready;
  bool get connected => relayState == RelayState.paired && _bridge != null;

  ConversationState? get conversation => _convSub?.state;

  Future<void> openSession(String id, {String? title}) async {
    final transport = _transport;
    if (transport == null || openingSession) return;
    await _disposeSession();
    openingSession = true;
    draft = false;
    sessionId = id;
    sessionTitle = title;
    notifyListeners();
    try {
      final sub = await transport.subscribe(id);
      _convSub = sub;
      sub.state.addListener(_onConversationChanged);
      _onConversationChanged();
      // prepareWorkspace disappeared in 3.17; model/mode options also arrive
      // in the conversation snapshot, so a failure here is not fatal.
      try {
        prep = await transport.prepareWorkspace();
      } catch (_) {}
    } catch (e) {
      error = _humanError(e);
    } finally {
      openingSession = false;
      notifyListeners();
    }
  }

  void _onConversationChanged() {
    notifyListeners();
  }

  void startDraft() {
    _disposeSession();
    draft = true;
    sessionId = null;
    sessionTitle = null;
    notifyListeners();
  }

  Future<void> closeChat() async {
    await _disposeSession();
    draft = false;
    notifyListeners();
  }

  Future<void> _disposeSession() async {
    final sub = _convSub;
    _convSub = null;
    if (sub != null) {
      sub.state.removeListener(_onConversationChanged);
      await sub.dispose();
    }
    sessionId = null;
    sessionTitle = null;
    prep = null;
  }

  Future<void> send(String text) async {
    final transport = _transport;
    final body = text.trim();
    if (transport == null || body.isEmpty || sending) return;
    sending = true;
    notifyListeners();
    try {
      if (sessionId == null) {
        final created = await transport.createSession(
          workspaceKey,
          firstText: body,
        );
        sessionId = created;
        final sub = await transport.subscribe(created);
        _convSub = sub;
        sub.state.addListener(_onConversationChanged);
        try {
          prep ??= await transport.prepareWorkspace();
        } catch (_) {}
      } else {
        await transport.sendText(sessionId!, body);
      }
      error = null;
    } catch (e) {
      error = _humanError(e);
    } finally {
      sending = false;
      notifyListeners();
    }
  }

  Future<void> stop() async {
    final transport = _transport;
    final id = sessionId;
    if (transport == null || id == null) return;
    try {
      await transport.stop(id);
    } catch (e) {
      error = _humanError(e);
      notifyListeners();
    }
  }

  Future<void> setMode(String mode) async {
    final transport = _transport;
    final id = sessionId;
    if (transport == null || id == null) return;
    try {
      await transport.switchCollaborationMode(id, mode);
      conversation?.optimisticPatch({
        'config': {...?conversation!.config, 'mode': mode},
      });
    } catch (e) {
      error = _humanError(e);
      notifyListeners();
    }
  }

  Future<void> setModel(String value, {String? thought}) async {
    final transport = _transport;
    final id = sessionId;
    final state = conversation;
    if (transport == null || id == null || state == null) return;
    final idx = value.lastIndexOf('/');
    final provider = idx > 0 ? value.substring(0, idx) : value;
    final model = idx > 0 ? value.substring(idx + 1) : value;
    final chosenThought = thought ??
        (state.currentThought.isNotEmpty
            ? state.currentThought
            : '${prep?.option('thought_level')?.currentValue ?? 'enabled'}');
    try {
      await transport.switchModelConfig(
        id,
        provider: provider,
        model: model,
        thought: chosenThought,
      );
      state.optimisticPatch({
        'config': {
          ...?state.config,
          'provider': provider,
          'model': model,
          'thought': chosenThought,
        },
      });
    } catch (e) {
      error = _humanError(e);
      notifyListeners();
    }
  }

  Future<void> resolveInteraction(
    String interactionId, {
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  }) async {
    final transport = _transport;
    final id = sessionId;
    if (transport == null || id == null) return;
    try {
      await transport.resolveInteraction(
        id,
        interactionId,
        optionId: optionId,
        freeText: freeText,
        action: action,
        content: content,
      );
    } catch (e) {
      error = _humanError(e);
      notifyListeners();
    }
  }

  Future<void> loadOlder() async {
    final transport = _transport;
    final state = conversation;
    final id = sessionId;
    if (transport == null || state == null || id == null) return;
    if (!state.canLoadOlder) return;
    try {
      final res = await transport.rowsRange(
        id,
        beforeRowId: state.oldestRowId,
        limit: 60,
      );
      if (res is Map) {
        final rowsObj = res['rows'];
        List? rows;
        int? firstRowId;
        if (rowsObj is Map) {
          rows = rowsObj['window'] as List? ?? rowsObj['rows'] as List?;
          firstRowId = (rowsObj['firstRowId'] as num?)?.toInt();
        } else if (rowsObj is List) {
          rows = rowsObj;
        }
        rows ??= res['items'] as List? ?? res['window'] as List?;
        firstRowId ??= (res['firstRowId'] as num?)?.toInt();
        if (rows != null) {
          state.prependOlderRows(
            rows.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList(),
            firstRowId,
          );
        }
      } else if (res is List) {
        state.prependOlderRows(
          res.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList(),
          null,
        );
      }
    } catch (e) {
      error = _humanError(e);
      notifyListeners();
    }
  }

  void pokeRelay() {
    _client?.pokeRelay();
  }

  Future<void> onAppResumed() async {
    if (_client == null) return;
    _client!.pokeRelay();
    if (relayState != RelayState.paired && !connecting) {
      await connect();
    }
  }

  void clearError() {
    error = null;
    notifyListeners();
  }

  String? takeError() {
    final e = error;
    error = null;
    return e;
  }

  Future<void> disconnect() async {
    await _teardown();
    relayState = RelayState.idle;
    notifyListeners();
  }

  Future<void> _teardown() async {
    await _disposeSession();
    final sessionsSub = _sessionsSub;
    _sessionsSub = null;
    if (sessionsSub != null) {
      sessionsSub.state.removeListener(_onSessionsChanged);
      await sessionsSub.dispose();
    }
    _bridge?.dispose();
    _bridge = null;
    _transport = null;
    workspaces.clear();
    workspace = null;
    final client = _client;
    _client = null;
    if (client != null) {
      client.relay.stateListenable.removeListener(_onRelayState);
      await client.dispose();
    }
  }

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }
}
