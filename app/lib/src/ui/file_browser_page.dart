import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import 'theme.dart';

/// Read-only browser for the project folder on the computer. Served by
/// `tools/bridge.mjs --serve` over the LAN (token-protected, root-restricted).
class FileBrowserPage extends StatefulWidget {
  const FileBrowserPage({super.key, required this.state, this.initialPath});

  final AppState state;
  final String? initialPath;

  @override
  State<FileBrowserPage> createState() => _FileBrowserPageState();
}

class _FileBrowserPageState extends State<FileBrowserPage> {
  String? _path;
  String? _root;
  List<PcFileEntry> _entries = const [];
  bool _loading = true;
  String? _error;
  final List<String> _history = [];

  @override
  void initState() {
    super.initState();
    _path = widget.initialPath;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await widget.state.pcList(_path);
      setState(() {
        _entries = entries;
        _loading = false;
        if (entries.isNotEmpty) _root ??= entries.first.path;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  void _enter(PcFileEntry entry) {
    setState(() {
      _history.add(_path ?? '');
      _path = entry.path;
    });
    _load();
  }

  void _up() {
    if (_path == null) return;
    final parent = _path!.replaceAll(RegExp(r'[\\/][^\\/]+$'), '');
    setState(() => _path = parent.isEmpty ? null : parent);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Pal.bg,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Файлы ПК',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            Text(
              _path ?? 'корень проекта',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: Pal.muted),
            ),
          ],
        ),
        actions: [
          if (_path != null)
            IconButton(
              tooltip: 'Вверх',
              onPressed: _up,
              icon: Icon(Icons.arrow_upward_rounded, size: 20, color: Pal.muted),
            ),
          IconButton(
            tooltip: 'Обновить',
            onPressed: _load,
            icon: Icon(Icons.refresh_rounded, size: 20, color: Pal.muted),
          ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) {
      return Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2, color: Pal.accent),
        ),
      );
    }
    if (_error != null) {
      return Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.folder_off_outlined, size: 34, color: Pal.muted),
            SizedBox(height: 10),
            Text(_error!, textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: Pal.muted, height: 1.4)),
            SizedBox(height: 14),
            Text(
              'Запусти на компьютере:\nnode tools/bridge.mjs --serve\n'
              'и укажи в настройках адрес с токеном.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11.5, color: Pal.muted, height: 1.5),
            ),
            SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: Text('Повторить')),
          ],
        ),
      );
    }
    if (_entries.isEmpty) {
      return Center(
        child: Text('Пусто', style: TextStyle(color: Pal.muted, fontSize: 13)),
      );
    }
    return ListView.separated(
      itemCount: _entries.length,
      separatorBuilder: (_, _) => Divider(height: 1, color: Pal.border),
      itemBuilder: (context, index) {
        final entry = _entries[index];
        return ListTile(
          dense: true,
          leading: Icon(
            entry.isDir ? Icons.folder_outlined : Icons.insert_drive_file_outlined,
            size: 19,
            color: entry.isDir ? Pal.accent : Pal.muted,
          ),
          title: Text(entry.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13)),
          subtitle: entry.isDir
              ? null
              : Text(_size(entry.size),
                  style: TextStyle(fontSize: 10.5, color: Pal.muted)),
          onTap: () => entry.isDir ? _enter(entry) : _openFile(entry),
          trailing: Icon(Icons.chevron_right_rounded, size: 18, color: Pal.muted),
        );
      },
    );
  }

  String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _openFile(PcFileEntry entry) async {
    try {
      final bytes = await widget.state.pcRead(entry.path);
      if (!mounted) return;
      final mime = _mime(entry.name);
      if (mime.startsWith('image/')) {
        await showDialog(
          context: context,
          builder: (_) => Dialog(
            backgroundColor: Pal.surface,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: InteractiveViewer(
                    child: Image.memory(Uint8List.fromList(bytes)),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text('Закрыть'),
                ),
              ],
            ),
          ),
        );
        return;
      }
      final text = _decodeText(bytes);
      if (text == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Бинарный файл — не показать')),
          );
        }
        return;
      }
      if (!mounted) return;
      await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Pal.surface,
        builder: (_) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.85,
          builder: (context, controller) => SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 8, 8),
                  child: Row(children: [
                    Expanded(
                      child: Text(entry.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontWeight: FontWeight.w600)),
                    ),
                    IconButton(
                      tooltip: 'Скопировать путь',
                      onPressed: () async {
                        await _copyPath(entry.path);
                        if (context.mounted) Navigator.pop(context);
                      },
                      icon: Icon(Icons.content_copy_rounded,
                          size: 18, color: Pal.muted),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: Icon(Icons.close_rounded, size: 18),
                    ),
                  ]),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    controller: controller,
                    padding: EdgeInsets.all(16),
                    child: SelectableText(text, style: monoStyle),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось открыть: $e')),
      );
    }
  }

  Future<void> _copyPath(String path) async {
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Pal.surface,
        title: Text('Путь к файлу', style: TextStyle(fontSize: 15)),
        content: SelectableText(path, style: monoStyle),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Готово'),
          ),
        ],
      ),
    );
  }

  String? _decodeText(List<int> bytes) {
    try {
      final text = utf8.decode(bytes);
      if (text.contains('\u0000')) return null;
      return text;
    } catch (_) {
      return null;
    }
  }

  String _mime(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'text/plain';
  }
}
