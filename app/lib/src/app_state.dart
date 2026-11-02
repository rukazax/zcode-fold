import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'cloud_api.dart';
import 'models.dart';
import 'pc_bridge_script.dart';
import 'zcode/conversation.dart';
import 'zcode/connection_params.dart';
import 'zcode/relay_client.dart';
import 'zcode/zcode_client.dart';

/// One project from `project.readTree` and its task list.
class ProjectFeed {
  ProjectFeed(this.project, {this.appWorkspace});
  final Map<String, dynamic> project;

  /// Matching bootstrap workspace, when the project can be opened remotely.
  final Map<String, dynamic>? appWorkspace;

  String get key => AppState.workspaceKeyOf(project) ?? '';
  String get title {
    final name = '${project['name'] ?? ''}'.trim();
    return name.isNotEmpty ? name : AppState.workspaceTitle(project);
  }

  List<SessionSummary> sessions = const [];
  bool loading = true;
  String? error;
}

/// Result of [AppState.send]. `needsQueueChoice` mirrors the desktop's
/// `guard.heldQueueConfirmationStale` handshake: the user must pick between
/// appending to the held queue and clearing it before the text is delivered.
enum SendOutcome { sent, needsQueueChoice, failed }

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
  static const _kBridgeUrl = 'bridge_fs_url';
  static const _kBridgeToken = 'bridge_fs_token';

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

  /// Task lists of the other projects (the active one uses [_sessionsSub]).
  /// Sourced from `project.readTree` over the active bridge.
  final List<ProjectFeed> projectFeeds = [];

  /// Tasks that are not attached to a desktop project (work outside project,
  /// draft workspaces). Shown in the flat «Задачи» section.
  List<SessionSummary> orphanTasks = const [];

  /// taskId → workspacePath, so a task from another workspace can be opened
  /// by switching to that workspace first.
  final Map<String, String> taskWorkspacePaths = {};
  bool projectFeedsLoading = false;
  Future<void>? _feedRefresh;

  /// LLM catalog for the chat picker (desktop provider registry).
  List<ModelOption> modelCatalog = const [];
  bool modelCatalogLoading = false;
  String? modelCatalogError;

  /// Model chosen before the first message of a new chat.
  String? draftModelValue;
  String? draftThought;

  /// Composer config for the NEXT message (desktop semantics): the desktop
  /// picker does not send a "switch model" command — it keeps the choice in
  /// the draft and ships it with the next `sendText` / `createSession`.
  String? pendingModelValue;
  String? pendingThought;
  String? pendingMode;

  /// Pinned session ids (local, per desktop).
  final Set<String> pinnedSessions = {};

  /// Cached title/preview/project of pinned tasks, so the pinned section
  /// survives tasks-index refreshes and project switches.
  final Map<String, Map<String, dynamic>> pinnedMeta = {};

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
    bridgeFsUrl = _prefs.getString(_kBridgeUrl);
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
      _loadPins();
    }
    notifyListeners();
    // Restore the last connection on cold start: the QR link is persistent, so
    // there is no reason to make the user tap "Переподключиться".
    if (activeDevice != null && hasJwt) {
      unawaited(connect());
    }
  }

  // ---------------------------------------------------------------- pins

  String get _pinsKey => 'pinned_${activeDevice?.id ?? 'none'}';
  String get _pinsMetaKey => 'pinned_meta_${activeDevice?.id ?? 'none'}';

  void _loadPins() {
    pinnedSessions.clear();
    pinnedMeta.clear();
    final raw = _prefs.getString(_pinsKey);
    if (raw != null) {
      try {
        final list = jsonDecode(raw);
        if (list is List) {
          for (final id in list.whereType<String>()) {
            pinnedSessions.add(id);
          }
        }
      } catch (_) {}
    }
    final metaRaw = _prefs.getString(_pinsMetaKey);
    if (metaRaw != null) {
      try {
        final map = jsonDecode(metaRaw);
        if (map is Map) {
          for (final entry in map.entries) {
            final value = entry.value;
            if (value is Map) {
              pinnedMeta['${entry.key}'] = value.cast<String, dynamic>();
            }
          }
        }
      } catch (_) {}
    }
    // Keep the id list and the metadata in sync.
    pinnedMeta.removeWhere((id, _) => !pinnedSessions.contains(id));
  }

  bool isPinned(String sessionId) => pinnedSessions.contains(sessionId);

  Future<void> togglePin(String sessionId, {SessionSummary? session}) async {
    if (pinnedSessions.contains(sessionId)) {
      pinnedSessions.remove(sessionId);
      pinnedMeta.remove(sessionId);
    } else {
      pinnedSessions.add(sessionId);
      final found = session ?? _findSession(sessionId);
      pinnedMeta[sessionId] = {
        'title': found?.title ?? '',
        'preview': found?.preview,
        'updatedAt': found?.updatedAt ?? 0,
        'project': _projectLabelOf(sessionId),
      };
    }
    await _prefs.setString(_pinsKey, jsonEncode(pinnedSessions.toList()));
    await _prefs.setString(_pinsMetaKey, jsonEncode(pinnedMeta));
    notifyListeners();
  }

  SessionSummary? _findSession(String id) {
    for (final s in sessions) {
      if (s.sessionId == id) return s;
    }
    for (final feed in projectFeeds) {
      for (final s in feed.sessions) {
        if (s.sessionId == id) return s;
      }
    }
    return null;
  }

  String _projectLabelOf(String id) {
    for (final feed in projectFeeds) {
      if (feed.sessions.any((s) => s.sessionId == id)) return feed.title;
    }
    if (sessions.any((s) => s.sessionId == id)) {
      final w = workspace;
      return w == null ? 'Проект' : AppState.workspaceTitle(w);
    }
    return pinnedMeta[id]?['project']?.toString() ?? '';
  }

  /// Pinned tasks for the sidebar: live tasks first, then cached metadata.
  List<SessionSummary> get pinnedTaskSummaries {
    final byId = <String, SessionSummary>{};
    for (final s in sessions) {
      if (isPinned(s.sessionId)) byId[s.sessionId] = s;
    }
    for (final feed in projectFeeds) {
      for (final s in feed.sessions) {
        if (isPinned(s.sessionId)) byId[s.sessionId] = s;
      }
    }
    for (final id in pinnedSessions) {
      if (byId.containsKey(id)) continue;
      final meta = pinnedMeta[id];
      final title = '${meta?['title'] ?? ''}'.trim();
      byId[id] = SessionSummary(
        sessionId: id,
        title: title.isEmpty ? 'Закреплённая задача' : title,
        phase: '',
        preview: meta?['preview']?.toString(),
        updatedAt: (meta?['updatedAt'] as num?)?.toInt() ?? 0,
      );
    }
    final list = byId.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  String pinnedProjectLabel(String id) {
    for (final feed in projectFeeds) {
      if (feed.sessions.any((s) => s.sessionId == id)) return feed.title;
    }
    if (sessions.any((s) => s.sessionId == id)) {
      final w = workspace;
      return w == null ? '' : AppState.workspaceTitle(w);
    }
    return pinnedMeta[id]?['project']?.toString() ?? '';
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
    _loadPins();
    modelCatalog = const [];
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
      if (data['bridgeUrl'] is String) {
        await setBridgeFiles(
          data['bridgeUrl'] as String,
          (data['fsToken'] as String?) ?? '',
        );
      }
    } catch (e) {
      connecting = false;
      error = _humanError(e);
      notifyListeners();
    }
  }

  // ------------------------------------------------------- PC files (bridge)

  String? bridgeFsUrl;

  Object? _pcTerminalId;
  void Function()? _pcTerminalOff;
  Future<bool>? _pcSetupFuture;
  String? pcSetupError;

  Future<void> setBridgeFiles(String url, String token) async {
    bridgeFsUrl = url.trim().isEmpty
        ? null
        : url.trim().replaceAll(RegExp(r'/+$'), '');
    if (token.trim().isNotEmpty) {
      await _secure.write(key: _kBridgeToken, value: token.trim());
    }
    if (bridgeFsUrl != null) {
      await _prefs.setString(_kBridgeUrl, bridgeFsUrl!);
    }
    notifyListeners();
  }

  Future<String?> get _bridgeToken => _secure.read(key: _kBridgeToken);

  Future<String?> readBridgeToken() => _bridgeToken;

  bool get hasPcFiles => bridgeFsUrl != null && bridgeFsUrl!.isNotEmpty;

  /// Zero-input setup for the common cases: reuse the saved bridge URL, then
  /// try the loopback address (adb reverse) and the emulator host. Returns
  /// true when a working bridge was found and saved.
  Future<bool> autoConfigurePc() async {
    final token = await _bridgeToken;
    if (token == null || token.isEmpty) return false;
    final candidates = <String>{
      if (bridgeFsUrl != null && bridgeFsUrl!.isNotEmpty) bridgeFsUrl!,
      'http://127.0.0.1:8939',
      'http://127.0.0.1:8940',
      'http://10.0.2.2:8939',
      'http://10.0.2.2:8940',
    };
    for (final url in candidates) {
      try {
        final health = await pcHealthFor(url, token);
        if (health['ok'] == true) {
          await setBridgeFiles(url, token);
          return true;
        }
      } catch (_) {}
    }
    // Nothing saved/working: ask the already-connected desktop to start the
    // bridge for us (terminal channel, no agent turn, no token spend).
    return autoSetupPcBridge();
  }

  /// One-tap PC setup: starts `bridge.mjs --serve --root C:/` in the project
  /// folder through the desktop terminal and reads the `BRIDGE_READY` line.
  /// No URL/token typing. Keeps the terminal alive while the bridge runs.
  Future<bool> autoSetupPcBridge() {
    final pending = _pcSetupFuture;
    if (pending != null) return pending;
    final future = _doAutoSetupPcBridge();
    _pcSetupFuture = future;
    return future.whenComplete(() => _pcSetupFuture = null);
  }

  /// PowerShell `-EncodedCommand` payload (UTF-16LE base64) that writes the
  /// embedded bridge script into `%TEMP%` and runs it with Node.
  String _pcBridgeLauncherCommand() {
    final scriptB64 = base64.encode(utf8.encode(pcBridgeServerScript));
    final ps =
        "\$b64='$scriptB64';"
        "\$p=Join-Path \$env:TEMP 'zcode-fold-bridge.cjs';"
        "[IO.File]::WriteAllBytes(\$p,[Convert]::FromBase64String(\$b64));"
        "\$tokenFile=Join-Path \$env:TEMP 'zcode-fold-bridge.token';"
        "\$listen=Get-NetTCPConnection -LocalPort 8940 -State Listen "
        "-ErrorAction SilentlyContinue;"
        "if(-not \$listen){Start-Process -WindowStyle Hidden -FilePath 'node' "
        "-ArgumentList ('\"{0}\"' -f \$p)};"
        "Start-Sleep -Milliseconds 900;"
        "\$token=(Get-Content \$tokenFile -Raw).Trim();"
        "\$ips=Get-NetIPAddress -AddressFamily IPv4 | "
        "Where-Object { \$_.IPAddress -ne '127.0.0.1' } | "
        "ForEach-Object { \$_.IPAddress };"
        "\$urls=@(\$ips | ForEach-Object { 'http://'+\$_+':8940' });"
        "Write-Output ('BRIDGE_READY ' + "
        "(@{url=\$urls[0];urls=\$urls;token=\$token} | ConvertTo-Json -Compress))";
    final bytes = <int>[];
    for (final unit in ps.codeUnits) {
      bytes.add(unit & 0xFF);
      bytes.add((unit >> 8) & 0xFF);
    }
    return base64.encode(bytes);
  }

  Future<bool> _doAutoSetupPcBridge() async {
    final transport = _transport;
    final w = workspace;
    if (transport == null || w == null) return false;
    final cwd = '${w['workspacePath'] ?? ''}'.trim();
    if (cwd.isEmpty) return false;
    Object? terminalId;
    void Function()? off;
    pcSetupError = null;
    try {
      terminalId = await transport.terminalCreate(cwd);
      final ready = Completer<Map<String, dynamic>>();
      final buffer = StringBuffer();
      off = transport.terminalListen(
        terminalId,
        onData: (data) {
          buffer.write(data);
          final match = RegExp(r'BRIDGE_READY\s*(\{[^\r\n]*\})')
              .firstMatch(buffer.toString());
          if (match != null && !ready.isCompleted) {
            try {
              final decoded = jsonDecode(match.group(1)!);
              if (decoded is Map) {
                ready.complete(decoded.cast<String, dynamic>());
              }
            } catch (_) {}
          }
        },
        onExit: (code) {
          if (!ready.isCompleted) {
            ready.completeError(
              StateError('terminal exited before BRIDGE_READY ($code)'),
            );
          }
        },
      );
      _pcTerminalId = terminalId;
      _pcTerminalOff = off;
      await transport.terminalWrite(
        terminalId,
        'powershell -NoProfile -EncodedCommand ${_pcBridgeLauncherCommand()}\r',
      );
      final info = await ready.future.timeout(const Duration(seconds: 25));
      final primary = '${info['url'] ?? ''}'.trim();
      final token = '${info['token'] ?? ''}'.trim();
      final urls =
          (info['urls'] as List?)
              ?.whereType<String>()
              .where((u) => u.trim().isNotEmpty)
              .toList() ??
          [if (primary.isNotEmpty) primary];
      if (urls.isEmpty || token.isEmpty) return false;
      // The PC may have several adapters (LAN, VPN, virtual). Pick the one
      // this phone can actually reach.
      String? reachable;
      for (final candidate in urls) {
        try {
          final health = await pcHealthFor(candidate, token);
          if (health['ok'] == true) {
            reachable = candidate;
            break;
          }
        } catch (_) {}
      }
      if (reachable == null) {
        pcSetupError = 'Мост запущен, но адрес недоступен: ${urls.join(', ')}';
        notifyListeners();
        return false;
      }
      await setBridgeFiles(reachable, token);
      _pcTerminalId = terminalId;
      _pcTerminalOff = off;
      // Keep the terminal alive: it owns the bridge process. Disposing it
      // immediately kills the HTTP server (the `exit` event can also fire
      // spuriously), so the keep-alive reference is intentional.
      return true;
    } catch (e) {
      pcSetupError = _humanError(e);
      notifyListeners();
      off?.call();
      if (terminalId != null) {
        try {
          await transport.terminalDispose(terminalId);
        } catch (_) {}
      }
      return false;
    }
  }

  Future<void> _disposePcTerminal() async {
    final id = _pcTerminalId;
    final off = _pcTerminalOff;
    _pcTerminalId = null;
    _pcTerminalOff = null;
    off?.call();
    final transport = _transport;
    if (id != null && transport != null) {
      try {
        await transport.terminalDispose(id);
      } catch (_) {}
    }
  }

  Future<Map<String, dynamic>> pcHealth() async {
    final url = bridgeFsUrl;
    if (url == null) throw Exception('Мост файлов не настроен');
    return pcHealthFor(url, '');
  }

  /// Checks a candidate bridge URL/token without saving it. Empty token means
  /// "use the one already stored" (the dialog never echoes secrets back).
  Future<Map<String, dynamic>> pcHealthFor(
    String rawUrl,
    String rawToken,
  ) async {
    final base = rawUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final token = rawToken.trim().isNotEmpty
        ? rawToken.trim()
        : await _bridgeToken;
    if (base.isEmpty) throw Exception('Укажи адрес моста');
    if (token == null || token.isEmpty) throw Exception('Укажи токен моста');
    final res = await http
        .get(
          Uri.parse('$base/health'),
          headers: {'Authorization': 'Bearer $token'},
        )
        .timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) {
      throw Exception('мост ответил ${res.statusCode}');
    }
    return (jsonDecode(utf8.decode(res.bodyBytes)) as Map)
        .cast<String, dynamic>();
  }

  Future<List<PcFileEntry>> pcList(String? path) async {
    final url = bridgeFsUrl;
    final token = await _bridgeToken;
    if (url == null || token == null) {
      throw Exception('Мост файлов не настроен');
    }
    final uri = Uri.parse('$url/fs/list')
        .replace(queryParameters: path == null ? null : {'path': path});
    final res = await http
        .get(uri, headers: {'Authorization': 'Bearer $token'})
        .timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) {
      throw Exception(utf8.decode(res.bodyBytes));
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final entries = (data['entries'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (m) => PcFileEntry.fromJson(
            m.cast<String, dynamic>(),
            (data['path'] ?? '') as String,
          ),
        )
        .toList();
    return entries;
  }

  Future<Uint8List> pcRead(String path) async {
    final url = bridgeFsUrl;
    final token = await _bridgeToken;
    if (url == null || token == null) {
      throw Exception('Мост файлов не настроен');
    }
    final uri = Uri.parse('$url/fs/read')
        .replace(queryParameters: {'path': path});
    final res = await http
        .get(uri, headers: {'Authorization': 'Bearer $token'})
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw Exception(utf8.decode(res.bodyBytes));
    return res.bodyBytes;
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
    if (identity is String && identity.trim().isNotEmpty) {
      return identity.trim();
    }
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
    final parts = key
        .split(RegExp(r'[\\/]'))
        .where((p) => p.isNotEmpty)
        .toList();
    return parts.isEmpty ? key : parts.last;
  }

  String get workspaceKey =>
      workspace == null ? '' : (workspaceKeyOf(workspace!) ?? '');

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
      modelCatalog = _readCachedCatalog();
      notifyListeners();
      unawaited(loadModelCatalog());
      unawaited(refreshProjectFeeds());
    } catch (e) {
      error = _humanError(e);
      notifyListeners();
    }
  }

  /// Loads every desktop project with its tasks in one call
  /// (`project.readTree`). The active project stays on the live
  /// sessions-index; the others are a snapshot refreshed on demand.
  Future<void> refreshProjectFeeds() {
    final pending = _feedRefresh;
    if (pending != null) return pending;
    final future = _doRefreshProjectFeeds().whenComplete(() {
      _feedRefresh = null;
    });
    _feedRefresh = future;
    return future;
  }

  Future<void> _doRefreshProjectFeeds() async {
    final transport = _transport;
    if (transport == null) return;
    projectFeedsLoading = true;
    notifyListeners();
    try {
      final tree = await transport.readProjectTree().timeout(
        const Duration(seconds: 20),
      );
      final projects = (tree['projects'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .where((p) => p['deleted'] != true)
          .toList();
      final allTasks = <Map<String, dynamic>>[];
      for (final t in (tree['tasks'] as List? ?? const [])) {
        if (t is Map) allTasks.add(t.cast<String, dynamic>());
      }
      final activePath = workspace == null
          ? null
          : '${workspace!['workspacePath'] ?? ''}';
      final next = <ProjectFeed>[];
      for (final project in projects) {
        final projectId = '${project['id'] ?? ''}';
        final roots = (project['roots'] as List? ?? const [])
            .map((r) => r is Map ? '${r['rootPath'] ?? ''}' : '$r')
            .where((p) => p.isNotEmpty)
            .toList();
        Map<String, dynamic>? appWorkspace;
        for (final w in workspaces) {
          final path = '${w['workspacePath'] ?? ''}';
          if ((path.isNotEmpty && roots.contains(path)) ||
              (projectId.isNotEmpty && workspaceKeyOf(w) == projectId)) {
            appWorkspace = w;
            break;
          }
        }
        final isActive =
            activePath != null &&
            activePath.isNotEmpty &&
            (roots.contains(activePath) ||
                (projectId.isNotEmpty && workspaceKey == projectId));
        if (isActive) continue;
        final tasks = <Map<String, dynamic>>[];
        for (final t in (project['tasks'] as List? ?? const [])) {
          if (t is Map) tasks.add(t.cast<String, dynamic>());
        }
        if (projectId.isNotEmpty) {
          for (final t in allTasks) {
            if ('${t['projectId'] ?? ''}' == projectId) tasks.add(t);
          }
        }
        final feed = ProjectFeed(project, appWorkspace: appWorkspace);
        feed.sessions = tasks
            .where((t) => t['archived'] != true)
            .map(_sessionFromTask)
            .whereType<SessionSummary>()
            .toList();
        feed.loading = false;
        next.add(feed);
      }
      // Tasks outside any project (work outside project / draft workspaces)
      // belong to the flat «Задачи» section.
      final projectIds = projects
          .map((p) => '${p['id'] ?? ''}')
          .where((id) => id.isNotEmpty)
          .toSet();
      final orphanIds = <String>{};
      final orphans = <SessionSummary>[];
      for (final task in allTasks) {
        if (task['archived'] == true) continue;
        final pid = '${task['projectId'] ?? ''}';
        if (pid.isNotEmpty && projectIds.contains(pid)) continue;
        final summary = _sessionFromTask(task);
        if (summary != null && orphanIds.add(summary.sessionId)) {
          orphans.add(summary);
        }
      }
      orphans.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      orphanTasks = orphans;
      projectFeeds
        ..clear()
        ..addAll(next);
    } catch (e) {
      for (final feed in projectFeeds) {
        feed.loading = false;
        feed.error = _humanError(e);
      }
    } finally {
      projectFeedsLoading = false;
      notifyListeners();
    }
  }

  SessionSummary? _sessionFromTask(Map<String, dynamic> task) {
    final id = '${task['taskId'] ?? task['sessionId'] ?? task['id'] ?? ''}';
    if (id.isEmpty) return null;
    final workspacePath = '${task['workspacePath'] ?? task['cwd'] ?? ''}'
        .trim();
    if (workspacePath.isNotEmpty) {
      taskWorkspacePaths[id] = workspacePath;
    }
    final preview =
        task['lastAssistantPreview'] ??
        task['lastMessagePreview'] ??
        task['preview'];
    final updatedRaw =
        task['lastActivityAt'] ?? task['updatedAt'] ?? task['createdAt'];
    final updatedAt = updatedRaw is num ? updatedRaw.toInt() : 0;
    return SessionSummary(
      sessionId: id,
      title: '${task['title'] ?? task['name'] ?? ''}',
      phase: '${task['status'] ?? task['phase'] ?? task['runState'] ?? ''}',
      preview: preview?.toString(),
      updatedAt: updatedAt,
      hasBackgroundWork: task['hasBackgroundWork'] == true,
    );
  }

  /// Opens a task that belongs to another project: switch to the matching
  /// bootstrap workspace first, then subscribe the conversation.
  Future<void> openSessionInProject(
    ProjectFeed feed,
    SessionSummary session,
  ) async {
    final target = feed.appWorkspace;
    if (target == null) {
      error = 'Этот проект не открыт в ZCode на компьютере';
      notifyListeners();
      return;
    }
    if (AppState.workspaceKeyOf(target) != workspaceKey) {
      await openWorkspace(target);
    }
    await openSession(session.sessionId, title: session.displayTitle);
  }

  /// Opens a task even if it lives in another workspace: switch to the
  /// workspace that owns it, then subscribe.
  Future<void> openTaskAnywhere(String id, {String? title}) async {
    final path = taskWorkspacePaths[id];
    if (path != null && path.isNotEmpty) {
      for (final w in workspaces) {
        final wp = '${w['workspacePath'] ?? ''}';
        if (wp == path && AppState.workspaceKeyOf(w) != workspaceKey) {
          await openWorkspace(w);
          break;
        }
      }
    }
    await openSession(id, title: title);
  }

  void _onSessionsChanged() {
    notifyListeners();
  }

  List<SessionSummary> get sessions {
    final sub = _sessionsSub;
    if (sub == null || !sub.state.ready) return const [];
    return sub.state.list.map((e) => SessionSummary.fromMap(e.raw)).toList();
  }

  bool get sessionsLoading =>
      _sessionsSub != null && !_sessionsSub!.state.ready;
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
      // Make sure the desktop's mobile view points at this workspace/task
      // before subscribing.
      await _client?.sendMobileViewState(
        workspaceKey: workspaceKey,
        taskId: id,
      );
      final sub = await transport
          .subscribe(id)
          .timeout(const Duration(seconds: 30));
      _convSub = sub;
      sub.state.addListener(_onConversationChanged);
      _onConversationChanged();
      // prepareWorkspace disappeared in 3.17; model/mode options arrive in
      // the conversation snapshot. Never await it here: an absent/hanging
      // channel method used to keep `openingSession` stuck forever, blocking
      // every other task tap. Fire and forget with a short timeout.
      unawaited(
        transport
            .prepareWorkspace()
            .timeout(const Duration(seconds: 4))
            .then<void>((value) {
              prep = value;
            })
            .catchError((_) {}),
      );
    } catch (e) {
      error = _humanError(e);
    } finally {
      openingSession = false;
      notifyListeners();
    }
  }

  bool _cfgDumped = false;

  void _onConversationChanged() {
    final snap = _convSub?.state.snapshot;
    if (!_cfgDumped && snap != null) {
      _cfgDumped = true;
      try {
        debugPrint('FOLD_KEYS ${snap.keys.join(",")}');
        debugPrint('FOLD_CFG ${jsonEncode(snap['config'])}');
      } catch (_) {}
    }
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
    // Feeds skipped while the chat was open can load now.
    unawaited(refreshProjectFeeds());
  }

  Future<void> _disposeSession() async {
    _cfgDumped = false;
    pendingModelValue = null;
    pendingThought = null;
    pendingMode = null;
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

  Future<SendOutcome> send(
    String text, {
    String? heldQueueDisposition,
    String? requestedDelivery,
    List<PendingAttachment> attachments = const [],
  }) async {
    final transport = _transport;
    final body = text.trim();
    if (transport == null) return SendOutcome.failed;
    if (body.isEmpty && attachments.isEmpty) return SendOutcome.failed;
    if (sending) return SendOutcome.failed;
    sending = true;
    notifyListeners();
    try {
      final selection = _modelSelectionPayload();
      final mode = _modePayload();
      // Desktop CAS handshake: while the held queue is non-empty the server
      // wants the ids it based its decision on (hence "confirmation stale").
      final expectedQueueIds = queueItems
          .map((e) => '${e['queueItemId'] ?? ''}')
          .where((e) => e.isNotEmpty)
          .toList();
      if (sessionId == null) {
        // Attachments need a live subscription before upload, so the first
        // message goes as a follow-up command in that case.
        final created = await transport.createSession(
          workspaceKey,
          firstText: attachments.isEmpty ? body : null,
          firstInputConfig: {'modelSelection': ?selection, ...mode},
        );
        sessionId = created;
        final sub = await transport.subscribe(created);
        _convSub = sub;
        sub.state.addListener(_onConversationChanged);
        if (prep == null) {
          unawaited(
            transport
                .prepareWorkspace()
                .timeout(const Duration(seconds: 4))
                .then<void>((value) {
                  prep = value;
                })
                .catchError((_) {}),
          );
        }
        if (attachments.isNotEmpty) {
          final descriptors = await _uploadAttachments(attachments);
          final res = await transport.sendText(
            created,
            body,
            attachments: descriptors,
            heldQueueDisposition: heldQueueDisposition,
            requestedDelivery: requestedDelivery,
            modelSelection: selection,
            mode: mode['mode'] as String?,
            planEnabled: mode['planEnabled'] as bool?,
            expectedHeldQueueItemIds: expectedQueueIds,
          );
          final outcome = _sendOutcome(res);
          if (outcome != SendOutcome.sent) return outcome;
        }
      } else {
        final descriptors = await _uploadAttachments(attachments);
        final res = await transport.sendText(
          sessionId!,
          body,
          attachments: descriptors.isEmpty ? null : descriptors,
          heldQueueDisposition: heldQueueDisposition,
          requestedDelivery: requestedDelivery,
          modelSelection: selection,
          mode: mode['mode'] as String?,
          planEnabled: mode['planEnabled'] as bool?,
          expectedHeldQueueItemIds: expectedQueueIds,
        );
        final outcome = _sendOutcome(res);
        if (outcome != SendOutcome.sent) return outcome;
      }
      draftModelValue = null;
      draftThought = null;
      // Keep the composer selection: like the desktop draft it stays active
      // for the following messages until the user picks another one.
      error = null;
      return SendOutcome.sent;
    } catch (e) {
      error = _humanError(e);
      return SendOutcome.failed;
    } finally {
      sending = false;
      notifyListeners();
    }
  }

  SendOutcome _sendOutcome(dynamic res) {
    if (res is! Map) return SendOutcome.sent;
    final status = '${res['status'] ?? ''}';
    if (status == 'accepted' ||
        status == 'duplicate' ||
        status == 'noop' ||
        status == 'authoritative') {
      return SendOutcome.sent;
    }
    final reason = '${res['reasonCode'] ?? ''}';
    if (status == 'confirmationRequired' ||
        reason == 'guard.heldQueueConfirmationStale') {
      return SendOutcome.needsQueueChoice;
    }
    error = reason.isEmpty ? 'Сообщение не принято: $status' : reason;
    return SendOutcome.failed;
  }

  Future<List<Map<String, dynamic>>> _uploadAttachments(
    List<PendingAttachment> files,
  ) async {
    final transport = _transport;
    final id = sessionId;
    if (transport == null || id == null || files.isEmpty) return const [];
    final out = <Map<String, dynamic>>[];
    for (final file in files) {
      final descriptor = await transport.attachmentPut(
        id,
        fileName: file.fileName,
        mime: file.mime,
        bytes: file.bytes,
        onProgress: (p) {
          file.upload = p;
          notifyListeners();
        },
      );
      out.add(descriptor);
    }
    return out;
  }

  /// Reads an attachment (image/file) from the desktop session.
  Future<Uint8List?> readAttachment(String ref) async {
    final transport = _transport;
    final id = sessionId;
    if (transport == null || id == null) return null;
    try {
      final result = await transport.attachmentRead(id, ref: ref);
      return result.bytes;
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------- queue / follow-up

  List<Map<String, dynamic>> get queueItems =>
      conversation?.queueItems ?? const [];

  bool get autoDrain => conversation?.autoDrain ?? true;

  String get followupMode =>
      conversation?.config?['followupMode']?.toString() ?? 'queue';

  /// `startNow | enqueue | guide | reject | choice` from the snapshot.
  String get inputRoutingMode => conversation?.inputRoutingMode ?? 'startNow';

  bool get turnRunning => conversation?.isRunning == true;

  Future<void> sendQueuedNow(String queueItemId) async {
    final transport = _transport;
    final id = sessionId;
    if (transport == null || id == null) return;
    conversation?.optimisticRemoveQueueItem(queueItemId);
    notifyListeners();
    try {
      await transport.sendQueuedNow(id, queueItemId);
    } catch (e) {
      error = _humanError(e);
      notifyListeners();
    }
  }

  Future<void> editQueueItem(String queueItemId, String text) async {
    final transport = _transport;
    final id = sessionId;
    if (transport == null || id == null || text.trim().isEmpty) return;
    try {
      await transport.editQueueItem(id, queueItemId, text.trim());
    } catch (e) {
      error = _humanError(e);
      notifyListeners();
    }
  }

  Future<void> deleteQueueItem(String queueItemId) async {
    final transport = _transport;
    final id = sessionId;
    if (transport == null || id == null) return;
    conversation?.optimisticRemoveQueueItem(queueItemId);
    notifyListeners();
    try {
      await transport.deleteQueueItem(id, queueItemId);
    } catch (e) {
      error = _humanError(e);
      notifyListeners();
    }
  }

  Future<void> setAutoDrain(bool value) async {
    final transport = _transport;
    final id = sessionId;
    if (transport == null || id == null) return;
    conversation?.optimisticPatch({
      'queue': {...?conversation?.queue, 'autoDrain': value},
    });
    notifyListeners();
    try {
      await transport.setAutoDrain(id, value);
    } catch (e) {
      error = _humanError(e);
      notifyListeners();
    }
  }

  Future<void> setFollowupMode(String mode) async {
    final transport = _transport;
    final id = sessionId;
    if (transport == null || id == null) return;
    conversation?.optimisticPatch({
      'config': {...?conversation?.config, 'followupMode': mode},
    });
    notifyListeners();
    try {
      await transport.setFollowupMode(id, mode);
    } catch (e) {
      error = _humanError(e);
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

  // ------------------------------------------------- task management

  void _patchTaskEverywhere(String id, {String? title, bool remove = false}) {
    final live = _sessionsSub?.state;
    if (live != null) {
      if (remove) {
        live.optimisticRemove(id);
      } else if (title != null) {
        live.optimisticRename(id, title);
      }
    }
    if (remove && pinnedSessions.remove(id)) {
      pinnedMeta.remove(id);
      unawaited(
        _prefs.setString(_pinsKey, jsonEncode(pinnedSessions.toList())),
      );
      unawaited(_prefs.setString(_pinsMetaKey, jsonEncode(pinnedMeta)));
    }
    if (title != null && pinnedMeta.containsKey(id)) {
      pinnedMeta[id] = {...pinnedMeta[id]!, 'title': title};
      unawaited(_prefs.setString(_pinsMetaKey, jsonEncode(pinnedMeta)));
    }
    for (final feed in projectFeeds) {
      if (remove) {
        feed.sessions = feed.sessions.where((s) => s.sessionId != id).toList();
      } else if (title != null) {
        feed.sessions = feed.sessions
            .map(
              (s) => s.sessionId == id
                  ? SessionSummary(
                      sessionId: s.sessionId,
                      title: title,
                      phase: s.phase,
                      preview: s.preview,
                      updatedAt: s.updatedAt,
                      hasBackgroundWork: s.hasBackgroundWork,
                    )
                  : s,
            )
            .toList();
      }
    }
    notifyListeners();
  }

  Future<void> renameCurrentSession(String title) async {
    final transport = _transport;
    final id = sessionId;
    final clean = title.trim();
    if (transport == null || id == null || clean.isEmpty) return;
    try {
      await transport.renameTask(id, clean);
      sessionTitle = clean;
      _patchTaskEverywhere(id, title: clean);
      notifyListeners();
    } catch (e) {
      error = _humanError(e);
      notifyListeners();
      rethrow;
    }
  }

  Future<void> archiveCurrentSession() async {
    final transport = _transport;
    final id = sessionId;
    if (transport == null || id == null) return;
    try {
      await transport.archiveTask(id);
      _patchTaskEverywhere(id, remove: true);
      await closeChat();
    } catch (e) {
      error = _humanError(e);
      notifyListeners();
      rethrow;
    }
  }

  Future<void> deleteCurrentSession() async {
    final transport = _transport;
    final id = sessionId;
    if (transport == null || id == null) return;
    try {
      await transport.deleteSession(id);
      _patchTaskEverywhere(id, remove: true);
      await closeChat();
    } catch (e) {
      error = _humanError(e);
      notifyListeners();
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>> desktopProjects() async {
    final transport = _transport;
    if (transport == null) return const [];
    return transport.readProjects();
  }

  Future<void> moveCurrentSessionToProject(String projectId) async {
    final transport = _transport;
    final id = sessionId;
    if (transport == null || id == null) return;
    try {
      await transport.moveTask(id, projectId);
      _patchTaskEverywhere(id, remove: true);
      await closeChat();
      unawaited(refreshProjectFeeds());
    } catch (e) {
      error = _humanError(e);
      notifyListeners();
      rethrow;
    }
  }

  /// Mode is part of the composer draft on the desktop, not a session
  /// command: it is sent with the next message (`mode` + `planEnabled`).
  Future<void> setMode(String mode) async {
    pendingMode = mode;
    conversation?.optimisticPatch({
      'config': {...?conversation?.config, 'mode': mode},
    });
    notifyListeners();
  }

  /// The catalog: desktop `model-provider.getAll` (providers + their models).
  Future<void> loadModelCatalog({bool refresh = false}) async {
    if (modelCatalogLoading) return;
    if (!refresh && modelCatalog.isNotEmpty) return;
    modelCatalogLoading = true;
    modelCatalogError = null;
    notifyListeners();
    try {
      // Primary path (no PC setup): the desktop composer's own
      // `modelSelectionService.getView()` over the already-paired relay.
      final transport = _transport;
      if (transport != null) {
        try {
          final view = await transport.modelSelectionView().timeout(
            const Duration(seconds: 12),
          );
          final parsed = _parseModelSelectionView(view);
          if (parsed.isNotEmpty) {
            modelCatalog = parsed;
            await _cacheCatalog(parsed);
            return;
          }
        } catch (_) {
          // Older desktop or transient error — try the LAN bridge below.
        }
      }
      // Fallback: 3.17 removed `model-provider`; the LAN bridge serves the
      // desktop registry when configured.
      final viaBridge = await _loadCatalogFromBridge();
      if (viaBridge.isNotEmpty) {
        modelCatalog = viaBridge;
        await _cacheCatalog(viaBridge);
        return;
      }
      final bridge = _bridge;
      if (bridge != null) {
        try {
          final res = await bridge.channels.call(
            'model-provider',
            'getAll',
            const [],
          );
          final parsed = _parseProviders(res);
          if (parsed.isNotEmpty) {
            modelCatalog = parsed;
            await _cacheCatalog(parsed);
            return;
          }
        } catch (_) {
          // Channel is absent in 3.17 — expected, fall through to cache.
        }
      }
      if (modelCatalog.isEmpty) {
        final cached = _readCachedCatalog();
        if (cached.isNotEmpty) {
          modelCatalog = cached;
        } else {
          modelCatalogError =
              'Не удалось получить список моделей с компьютера. Проверь, что '
              'ZCode на связи, и попробуй ещё раз.';
        }
      }
    } finally {
      modelCatalogLoading = false;
      notifyListeners();
    }
  }

  /// Model registry served by the desktop bridge (`GET /models`).
  Future<List<ModelOption>> _loadCatalogFromBridge() async {
    final url = bridgeFsUrl;
    final token = await _bridgeToken;
    if (url == null || token == null) return const [];
    try {
      final res = await http
          .get(
            Uri.parse('$url/models'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return const [];
      final data = jsonDecode(utf8.decode(res.bodyBytes));
      final models = data is Map ? data['models'] : null;
      if (models is! List) return const [];
      final out = <ModelOption>[];
      for (final m in models.whereType<Map>()) {
        final option = ModelOption.fromJson(m.cast<String, dynamic>());
        if (option != null) out.add(option);
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Parses `modelSelectionService.getView()`. The view is a list of provider
  /// groups (`{key: 'registry-provider:<id>', label, items:[{value,name}]}`).
  List<ModelOption> _parseModelSelectionView(dynamic res) {
    final map = res is Map ? res : null;
    final providers = map?['providers'];
    if (providers is! List) return const [];
    final out = <ModelOption>[];
    final seen = <String>{};
    for (final group in providers.whereType<Map>()) {
      final groupMap = group.cast<String, dynamic>();
      final key = '${groupMap['key'] ?? ''}';
      var providerId = '${groupMap['providerId'] ?? ''}'.trim();
      if (providerId.isEmpty && key.isNotEmpty) {
        providerId = key
            .replaceFirst(RegExp(r'^registry-provider:'), '')
            .trim();
      }
      if (providerId.isEmpty) continue;
      final providerName =
          '${groupMap['label'] ?? groupMap['providerName'] ?? providerId}'
              .trim();
      final items = groupMap['items'] ?? groupMap['models'];
      if (items is! List) continue;
      for (final item in items.whereType<Map>()) {
        final itemMap = item.cast<String, dynamic>();
        var value =
            '${itemMap['value'] ?? itemMap['modelId'] ?? itemMap['id'] ?? itemMap['name'] ?? ''}'
                .trim();
        if (value.isEmpty) continue;
        var pid = providerId;
        var modelId = value;
        final slash = value.indexOf('/');
        if (slash > 0 && slash < value.length - 1) {
          pid = value.substring(0, slash);
          modelId = value.substring(slash + 1);
        }
        final dedupe = '$pid/$modelId';
        if (!seen.add(dedupe)) continue;
        out.add(
          ModelOption(
            providerId: pid,
            providerName: providerName.isEmpty ? pid : providerName,
            modelId: modelId,
            modelName: itemMap['name']?.toString(),
            description: itemMap['description']?.toString(),
            enabled: itemMap['enabled'] != false,
          ),
        );
      }
    }
    return out;
  }

  List<ModelOption> _parseProviders(dynamic res) {
    final list = res is List
        ? res
        : (res is Map && res['providers'] is List
              ? res['providers'] as List
              : const []);
    final out = <ModelOption>[];
    for (final p in list.whereType<Map>()) {
      final providerId = '${p['id'] ?? p['providerId'] ?? ''}'.trim();
      if (providerId.isEmpty || p['enabled'] == false) continue;
      final providerName = '${p['name'] ?? providerId}'.trim();
      final models = p['models'];
      if (models is! List) continue;
      for (final m in models) {
        if (m is String && m.trim().isNotEmpty) {
          out.add(
            ModelOption(
              providerId: providerId,
              providerName: providerName,
              modelId: m.trim(),
            ),
          );
        } else if (m is Map) {
          final modelId =
              '${m['id'] ?? m['modelId'] ?? m['model_id'] ?? m['name'] ?? ''}'
                  .trim();
          if (modelId.isEmpty) continue;
          out.add(
            ModelOption(
              providerId: providerId,
              providerName: providerName,
              modelId: modelId,
              modelName: (m['displayName'] ?? m['name'])?.toString(),
              description: m['description'] as String?,
            ),
          );
        }
      }
    }
    return out;
  }

  String get _catalogKey =>
      'model_catalog_${Uri.encodeComponent(workspaceKey)}';

  Future<void> _cacheCatalog(List<ModelOption> catalog) async {
    await _prefs.setString(
      _catalogKey,
      jsonEncode(catalog.map((m) => m.toJson()).toList()),
    );
  }

  List<ModelOption> _readCachedCatalog() {
    final raw = _prefs.getString(_catalogKey);
    if (raw == null) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return list
          .whereType<Map>()
          .map((m) => ModelOption.fromJson(m.cast<String, dynamic>()))
          .whereType<ModelOption>()
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> setModel(String value, {String? thought}) async {
    final idx = value.lastIndexOf('/');
    final provider = idx > 0 ? value.substring(0, idx) : value;
    final model = idx > 0 ? value.substring(idx + 1) : value;
    await setModelParts(provider, model, thought: thought);
  }

  /// Desktop semantics: the picker only stores the choice in the composer
  /// draft. It travels with the next `sendText`; there is no switch command.
  Future<void> setModelParts(
    String provider,
    String model, {
    String? thought,
  }) async {
    final state = conversation;
    if (state != null) {
      final chosenThought = thought ?? state.currentThought;
      pendingModelValue = '$provider/$model';
      pendingThought = chosenThought.isEmpty ? null : chosenThought;
      state.optimisticPatch({
        'config': {
          ...?state.config,
          'provider': provider,
          'model': model,
          if (pendingThought != null) 'thought': pendingThought,
        },
      });
    } else {
      draftModelValue = '$provider/$model';
      if (thought != null) draftThought = thought;
    }
    notifyListeners();
  }

  String? get currentModelValue {
    if (pendingModelValue != null) return pendingModelValue;
    final cfg = conversation?.config;
    final provider = cfg?['provider']?.toString();
    final model = cfg?['model']?.toString();
    if (model != null && model.isNotEmpty) {
      return provider != null && provider.isNotEmpty
          ? '$provider/$model'
          : model;
    }
    return draftModelValue;
  }

  String get currentModeValue =>
      pendingMode ?? conversation?.currentMode ?? 'build';

  String get currentThoughtValue {
    if (pendingThought != null) return pendingThought!;
    final thought = conversation?.currentThought ?? '';
    if (thought.isNotEmpty) return thought;
    return draftThought ?? '';
  }

  /// `modelSelection` payload at desktop wire format. Reasoning level is only
  /// attached when it is known to be valid for this model (the bridge registry
  /// has no option specs, so an explicit user pick wins; otherwise omit it).
  Map<String, dynamic>? _modelSelectionPayload() {
    final value = currentModelValue;
    if (value == null || !value.contains('/')) return null;
    final idx = value.lastIndexOf('/');
    final provider = value.substring(0, idx);
    final model = value.substring(idx + 1);
    if (provider.isEmpty || model.isEmpty) return null;
    final cfg = conversation?.config;
    final sameModel =
        cfg?['provider']?.toString() == provider &&
        cfg?['model']?.toString() == model;
    String? cfgThought;
    if (sameModel && cfg != null) {
      cfgThought = cfg['thought']?.toString();
    }
    final thought =
        pendingThought ??
        cfgThought ??
        (draftThought?.isNotEmpty == true ? draftThought : null);
    return {
      'providerId': provider,
      'modelId': model,
      if (thought != null && thought.isNotEmpty)
        'options': {'reasoningLevel': thought},
    };
  }

  Map<String, dynamic> _modePayload() {
    final mode = currentModeValue;
    if (mode == 'plan') return {'mode': 'build', 'planEnabled': true};
    return {'mode': mode, 'planEnabled': false};
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
            rows
                .whereType<Map>()
                .map((e) => e.cast<String, dynamic>())
                .toList(),
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
    await _disposePcTerminal();
    await _disposeSession();
    final sessionsSub = _sessionsSub;
    _sessionsSub = null;
    if (sessionsSub != null) {
      sessionsSub.state.removeListener(_onSessionsChanged);
      await sessionsSub.dispose();
    }
    projectFeeds.clear();
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
