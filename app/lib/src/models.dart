import 'package:flutter/material.dart';

/// A saved hub connection.
class ServerProfile {
  ServerProfile({
    required this.id,
    required this.name,
    required this.hubUrl,
    required this.token,
  });

  final String id;
  String name;
  String hubUrl;
  String token;

  Map<String, dynamic> toJson({bool withToken = true}) => {
        'id': id,
        'name': name,
        'hubUrl': hubUrl,
        if (withToken) 'token': token,
      };

  static ServerProfile fromJson(Map<String, dynamic> json, {String token = ''}) {
    return ServerProfile(
      id: json['id'] as String? ?? DateTime.now().microsecondsSinceEpoch.toString(),
      name: json['name'] as String? ?? 'hub',
      hubUrl: json['hubUrl'] as String? ?? '',
      token: token.isNotEmpty ? token : (json['token'] as String? ?? ''),
    );
  }
}

class HubSessionInfo {
  HubSessionInfo({required this.sessionId, this.title, this.status, this.updatedAt});

  final String sessionId;
  final String? title;
  final String? status;
  final int? updatedAt;

  bool get running => status == 'running';

  static HubSessionInfo fromJson(Map<String, dynamic> json) => HubSessionInfo(
        sessionId: json['sessionId'] as String? ?? '',
        title: json['title'] as String?,
        status: json['status'] as String?,
        updatedAt: (json['updatedAt'] as num?)?.toInt(),
      );
}

class HubInstance {
  HubInstance({
    required this.id,
    this.workspace,
    this.origin,
    this.sessions = const [],
  });

  final String id;
  final String? workspace;
  final String? origin;
  final List<HubSessionInfo> sessions;

  String get workspaceName {
    final w = workspace ?? '';
    final parts = w.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).toList();
    return parts.isEmpty ? (w.isEmpty ? 'workspace' : w) : parts.last;
  }

  static HubInstance fromJson(Map<String, dynamic> json) => HubInstance(
        id: json['id'] as String? ?? '',
        workspace: json['workspace'] as String?,
        origin: json['origin'] as String?,
        sessions: (json['sessions'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(HubSessionInfo.fromJson)
            .toList(),
      );
}

class ConfigOptionValue {
  ConfigOptionValue({required this.value, required this.name});
  final String value;
  final String name;
}

class ConfigOption {
  ConfigOption({
    required this.id,
    this.name,
    this.currentValue,
    this.options = const [],
  });
  final String id;
  final String? name;
  String? currentValue;
  final List<ConfigOptionValue> options;

  String displayValue() {
    final v = currentValue;
    if (v == null) return '';
    for (final o in options) {
      if (o.value == v) return o.name;
    }
    final tail = v.split(RegExp(r'[\\/]')).last;
    return tail;
  }

  static ConfigOption fromJson(Map<String, dynamic> json) => ConfigOption(
        id: json['id'] as String? ?? '',
        name: json['name'] as String?,
        currentValue: json['currentValue'] as String?,
        options: (json['options'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>()
            .map((o) => ConfigOptionValue(
                  value: o['value'] as String? ?? '',
                  name: o['name'] as String? ?? (o['value'] as String? ?? ''),
                ))
            .toList(),
      );
}

class UsageInfo {
  UsageInfo(this.used, this.size);
  final int used;
  final int size;
  double get fraction => size <= 0 ? 0 : (used / size).clamp(0.0, 1.0);
}

class PermissionOption {
  PermissionOption({required this.id, required this.name, this.kind});
  final String id;
  final String name;
  final String? kind;
}

class PendingPermission {
  PendingPermission({
    required this.requestId,
    required this.title,
    this.detail,
    required this.options,
  });
  final int requestId;
  final String title;
  final String? detail;
  final List<PermissionOption> options;
}

class ToolCallData {
  ToolCallData({
    required this.id,
    required this.title,
    this.kind,
    this.status = 'in_progress',
    this.text = '',
    this.rawInput,
  });

  final String id;
  String title;
  String? kind;
  String status;
  String text;
  dynamic rawInput;

  bool get failed => status == 'failed';
  bool get done => status == 'completed';
}

class ChatPart {
  ChatPart.text(this.text) : type = 'text', tool = null;
  ChatPart.thought(this.text) : type = 'thought', tool = null;
  ChatPart.tool(this.tool)
      : type = 'tool',
        text = '';

  final String type;
  String text;
  ToolCallData? tool;
}

class ChatMessage {
  ChatMessage({required this.id, required this.role, List<ChatPart>? parts})
      : parts = parts ?? [];

  final String id;
  final String role; // user | assistant
  final List<ChatPart> parts;
  bool collapsed = false;
  DateTime createdAt = DateTime.now();

  bool get isUser => role == 'user';

  String get plainText => parts
      .where((p) => p.type == 'text')
      .map((p) => p.text)
      .join()
      .trim();
}

class SlashCommand {
  SlashCommand({required this.name, this.description});
  final String name;
  final String? description;

  static SlashCommand fromJson(Map<String, dynamic> json) => SlashCommand(
        name: json['name'] as String? ?? '',
        description: json['description'] as String?,
      );
}

class PlanEntry {
  PlanEntry({required this.content, required this.status, this.priority});
  final String content;
  final String status;
  final String? priority;
}

/// Helpers shared by the UI.
String humanBytes(int n) {
  if (n < 1000) return '$n';
  if (n < 1000 * 1000) return '${(n / 1000).toStringAsFixed(1)}k';
  return '${(n / 1000000).toStringAsFixed(1)}M';
}

String formatTime(int? epochMs) {
  if (epochMs == null) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(epochMs);
  final now = DateTime.now();
  if (now.difference(d).inDays == 0) {
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
  return '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}';
}

IconData iconForKind(String? kind) {
  switch (kind) {
    case 'execute':
      return Icons.terminal_rounded;
    case 'edit':
      return Icons.edit_note_rounded;
    case 'read':
      return Icons.description_outlined;
    case 'search':
      return Icons.search_rounded;
    case 'fetch':
      return Icons.cloud_download_outlined;
    case 'switch_mode':
      return Icons.swap_horiz_rounded;
    default:
      return Icons.build_circle_outlined;
  }
}

Color colorForStatus(String status, ColorScheme scheme) {
  switch (status) {
    case 'completed':
      return const Color(0xFF5DD9A0);
    case 'failed':
      return scheme.error;
    case 'pending':
      return const Color(0xFFE3B341);
    default:
      return const Color(0xFF7AA7FF);
  }
}
