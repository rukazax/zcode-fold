import 'dart:typed_data';

import 'package:flutter/material.dart';

/// One selectable LLM from the desktop's provider registry.
class ModelOption {
  const ModelOption({
    required this.providerId,
    required this.providerName,
    required this.modelId,
    this.modelName,
    this.description,
    this.enabled = true,
  });

  final String providerId;
  final String providerName;
  final String modelId;
  final String? modelName;
  final String? description;
  final bool enabled;

  String get value => '$providerId/$modelId';
  String get label => (modelName?.trim().isNotEmpty ?? false) ? modelName! : modelId;

  Map<String, dynamic> toJson() => {
        'providerId': providerId,
        'providerName': providerName,
        'modelId': modelId,
        'modelName': modelName,
        'description': description,
        'enabled': enabled,
      };

  static ModelOption? fromJson(Map<String, dynamic> json) {
    final providerId = (json['providerId'] ?? json['provider_id'] ?? '').toString();
    final modelId = (json['modelId'] ?? json['model_id'] ?? json['id'] ?? '').toString();
    if (providerId.isEmpty || modelId.isEmpty) return null;
    return ModelOption(
      providerId: providerId,
      providerName: (json['providerName'] ?? json['provider_name'] ?? providerId).toString(),
      modelId: modelId,
      modelName: json['modelName'] as String? ?? json['name'] as String?,
      description: json['description'] as String?,
      enabled: json['enabled'] != false,
    );
  }
}

/// A file picked on the phone, waiting to be uploaded to the desktop session.
class PendingAttachment {
  PendingAttachment({
    required this.fileName,
    required this.mime,
    required this.bytes,
  });

  final String fileName;
  final String mime;
  final Uint8List bytes;
  double upload = 0;

  bool get isImage => mime.startsWith('image/');
}

/// One entry of the desktop filesystem browser (served by the LAN bridge).
class PcFileEntry {
  const PcFileEntry({
    required this.name,
    required this.path,
    required this.isDir,
    this.size = 0,
  });

  final String name;
  final String path;
  final bool isDir;
  final int size;

  static PcFileEntry fromJson(Map<String, dynamic> json, String parent) {
    final name = '${json['name'] ?? ''}';
    final isDir = json['dir'] == true || json['kind'] == 'dir';
    final path = '${json['path'] ?? _join(parent, name)}';
    return PcFileEntry(
      name: name,
      path: path,
      isDir: isDir,
      size: (json['size'] as num?)?.toInt() ?? 0,
    );
  }

  static String _join(String parent, String name) {
    if (parent.endsWith('/') || parent.endsWith('\\')) return '$parent$name';
    final sep = parent.contains('\\') ? '\\' : '/';
    return '$parent$sep$name';
  }
}

/// A saved ZCode desktop pairing (the QR/link from the desktop app).
class SavedDevice {
  SavedDevice({required this.id, required this.name, required this.url});

  final String id;
  String name;
  String url;

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  static SavedDevice fromJson(Map<String, dynamic> json, {String url = ''}) =>
      SavedDevice(
        id: json['id'] as String? ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        name: json['name'] as String? ?? 'ZCode',
        url: url,
      );
}

/// One live session row from the desktop's sessions index.
class SessionSummary {
  SessionSummary({
    required this.sessionId,
    required this.title,
    required this.phase,
    this.preview,
    this.updatedAt = 0,
    this.hasBackgroundWork = false,
  });

  final String sessionId;
  final String title;
  final String phase;
  final String? preview;
  final int updatedAt;
  final bool hasBackgroundWork;

  bool get running => phase == 'running' || phase == 'prewarming';
  bool get failed => phase == 'error';

  String get displayTitle {
    final t = title.trim();
    if (t.isNotEmpty) return t;
    final p = preview?.trim();
    if (p != null && p.isNotEmpty) return p;
    return 'Без названия';
  }

  static SessionSummary fromMap(Map<String, dynamic> raw) => SessionSummary(
        sessionId: '${raw['sessionId'] ?? ''}',
        title: '${raw['title'] ?? ''}',
        phase: '${raw['phase'] ?? ''}',
        preview: raw['lastAssistantPreview'] as String?,
        updatedAt: (raw['lastActivityAt'] as num?)?.toInt() ?? 0,
        hasBackgroundWork: raw['hasBackgroundWork'] == true,
      );
}

String humanTokens(int n) {
  if (n < 1000) return '$n';
  if (n < 1000000) return '${(n / 1000).toStringAsFixed(1)}k';
  return '${(n / 1000000).toStringAsFixed(1)}M';
}

String formatTime(int epochMs) {
  if (epochMs <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(epochMs);
  final now = DateTime.now();
  final sameDay = now.year == d.year && now.month == d.month && now.day == d.day;
  if (sameDay) {
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
  return '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}';
}

IconData iconForTool(String name) {
  final n = name.toLowerCase();
  if (n.contains('bash') || n.contains('shell') || n.contains('exec')) {
    return Icons.terminal_rounded;
  }
  if (n.contains('edit') || n.contains('write') || n.contains('patch')) {
    return Icons.edit_note_rounded;
  }
  if (n.contains('read') || n.contains('view')) {
    return Icons.description_outlined;
  }
  if (n.contains('grep') || n.contains('search') || n.contains('glob')) {
    return Icons.search_rounded;
  }
  if (n.contains('fetch') || n.contains('web')) {
    return Icons.cloud_download_outlined;
  }
  if (n.contains('agent') || n.contains('task')) {
    return Icons.hub_outlined;
  }
  return Icons.build_circle_outlined;
}

Color toolStatusColor(String status) {
  switch (status) {
    case 'success':
      return const Color(0xFF5DD9A0);
    case 'error':
      return const Color(0xFFFF7B72);
    case 'cancelled':
      return const Color(0xFFE3B341);
    case 'running':
    case 'inputStreaming':
    case 'pendingApproval':
      return const Color(0xFF7AA7FF);
    default:
      return const Color(0xFF8B95A3);
  }
}
