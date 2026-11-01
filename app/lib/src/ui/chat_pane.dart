import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../app_state.dart';
import '../models.dart';
import '../zcode/conversation.dart' show ConversationState;
import 'file_browser_page.dart';
import 'theme.dart';

class ChatPane extends StatefulWidget {
  const ChatPane({
    super.key,
    required this.state,
    required this.onBack,
  });

  final AppState state;
  final VoidCallback onBack;

  @override
  State<ChatPane> createState() => _ChatPaneState();
}

class _ChatPaneState extends State<ChatPane> {
  final _scroll = ScrollController();
  final _input = TextEditingController();
  final _focus = FocusNode();
  final List<PendingAttachment> _pending = [];
  bool _atBottom = true;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onState);
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      _atBottom = _scroll.position.maxScrollExtent - _scroll.offset < 140;
    });
  }

  @override
  void dispose() {
    widget.state.removeListener(_onState);
    _scroll.dispose();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onState() {
    if (!mounted) return;
    final error = widget.state.takeError();
    if (error != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error), duration: Duration(seconds: 4)),
        );
      });
    }
    if (_atBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
    setState(() {});
  }

  Future<void> _send() async {
    final text = _input.text;
    if ((text.trim().isEmpty && _pending.isEmpty) || widget.state.sending) return;
    final state = widget.state;
    // Desktop semantics: while a turn runs, a new message goes to the held
    // queue (or guide). With a non-empty queue the server may ask to choose
    // between queuing and sending right now.
    String? disposition;
    if (state.sessionId != null &&
        state.turnRunning &&
        state.inputRoutingMode == 'choice' &&
        state.queueItems.isNotEmpty) {
      disposition = await _askHeldQueueDisposition();
      if (disposition == null) return; // cancelled
    }
    final files = List<PendingAttachment>.from(_pending);
    _input.clear();
    if (files.isNotEmpty) setState(() => _pending.clear());
    await state.send(text, heldQueueDisposition: disposition, attachments: files);
    _atBottom = true;
    _focus.requestFocus();
  }

  Future<String?> _askHeldQueueDisposition() {
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Pal.surface,
        title: const Text('В очереди есть сообщения',
            style: TextStyle(fontSize: 16)),
        content: const Text(
          'Можно добавить это сообщение в конец очереди или очистить очередь '
          'и выполнить сразу.',
          style: TextStyle(fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'keepQueueAndSend'),
            child: const Text('В очередь'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'clearQueueAndSend'),
            child: const Text('Отправить сразу'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final rows = state.conversation?.rows ?? const <Map<String, dynamic>>[];
    final interactions = state.conversation?.pendingInteractions ??
        const <Map<String, dynamic>>[];
    return Column(
      children: [
        _header(context),
        if (!state.connected && !state.connecting)
          Container(
            width: double.infinity,
            color: Color(0xFF231D10),
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 7),
            child: Text(
              'Связь с компьютером потеряна — жду переподключения. '
              'Проверь, что ZCode открыт и мобильный доступ включён.',
              style: TextStyle(color: Color(0xFFE3B341), fontSize: 11.5),
            ),
          ),
        Expanded(
          child: state.openingSession && rows.isEmpty
              ? Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Pal.accent),
                  ),
                )
              : rows.isEmpty
                  ? _empty(context)
                  : ListView(
                      controller: _scroll,
                      padding: EdgeInsets.fromLTRB(14, 14, 14, 18),
                      children: [
                        if (state.conversation?.canLoadOlder == true)
                          Center(
                            child: TextButton.icon(
                              onPressed: state.loadOlder,
                              icon: Icon(Icons.history_rounded, size: 16),
                              label: Text('Загрузить раньше'),
                            ),
                          ),
                        ..._buildRows(context, rows),
                      ],
                    ),
        ),
        if (interactions.isNotEmpty) _interactions(context, interactions),
        if (state.queueItems.isNotEmpty) _queueBar(context),
        _composer(context),
      ],
    );
  }

  Widget _header(BuildContext context) {
    final state = widget.state;
    final conn = state.conversation;
    final usage = _usage(state);
    return Container(
      padding: EdgeInsets.fromLTRB(4, 6, 8, 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Pal.border)),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: widget.onBack,
            icon: Icon(Icons.arrow_back_rounded, size: 20),
            tooltip: 'К списку',
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _title(state),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5),
                ),
                Row(children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: state.connected ? Pal.accent : Color(0xFFE3B341),
                      shape: BoxShape.circle,
                    ),
                  ),
                  SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      conn?.isRunning == true
                          ? 'модель работает…'
                          : (state.connected ? 'на связи' : 'нет связи'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Pal.muted, fontSize: 11),
                    ),
                  ),
                ]),
              ],
            ),
          ),
          if (conn != null)
            _configChip(
              context,
              label: _currentModelLabel(state, conn),
              onTap: () => _showTaskSettings(context),
            ),
          if (usage != null) _usageChip(usage),
          IconButton(
            tooltip: 'Файлы компьютера',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => FileBrowserPage(state: state),
            )),
            icon: Icon(Icons.folder_open_rounded, size: 19, color: Pal.muted),
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            onPressed: () => _showTaskSettings(context),
            icon: Icon(Icons.tune_rounded, size: 20, color: Pal.muted),
            tooltip: 'Настройки задачи',
          ),
        ],
      ),
    );
  }

  String _title(AppState state) {
    final t = state.sessionTitle?.trim();
    if (t != null && t.isNotEmpty) return t;
    if (state.sessionId == null) return 'Новая сессия';
    return 'Сессия';
  }

  ({double fraction, int used, int size})? _usage(AppState state) {
    final usage = state.conversation?.usage;
    final window = usage?['contextWindow'];
    if (window is! Map) return null;
    final used = (window['usedTokens'] as num?)?.toInt() ?? 0;
    final size = (window['maxTokens'] as num?)?.toInt() ?? 0;
    if (size <= 0) return null;
    return (fraction: (used / size).clamp(0.0, 1.0), used: used, size: size);
  }

  String _currentModelLabel(AppState state, ConversationState conn) {
    final config = conn.config;
    final model = '${config?['model'] ?? ''}';
    if (model.isNotEmpty) return model.split('/').last;
    final option = state.prep?.option('model');
    final value = '${option?.currentValue ?? ''}';
    if (value.isEmpty) return 'модель';
    return value.split('/').last;
  }

  Widget _configChip(BuildContext context,
      {required String label, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: EdgeInsets.only(right: 4),
        padding: EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(
          color: Pal.surface2,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Pal.border),
        ),
        child: Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11)),
      ),
    );
  }

  Widget _usageChip(({double fraction, int used, int size}) usage) {
    return Padding(
      padding: EdgeInsets.only(right: 4),
      child: Tooltip(
        message: 'Контекст: ${humanTokens(usage.used)} из ${humanTokens(usage.size)}',
        child: SizedBox(
          width: 30,
          height: 30,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: usage.fraction,
                strokeWidth: 2.6,
                backgroundColor: Pal.surface2,
                color: usage.fraction > 0.8 ? Color(0xFFFF7B72) : Pal.accent,
              ),
              Text('${(usage.fraction * 100).round()}',
                  style: TextStyle(fontSize: 8.5, color: Pal.muted)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final draft = widget.state.sessionId == null;
    return ListView(
      padding: EdgeInsets.all(24),
      children: [
        SizedBox(height: 34),
        Icon(Icons.auto_awesome_rounded, size: 34, color: Pal.accent),
        SizedBox(height: 12),
        Center(
          child: Text(
            draft ? 'Новая сессия' : 'Пустая сессия',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
          ),
        ),
        SizedBox(height: 6),
        Center(
          child: Text(
            'Напиши задачу — агент работает на компьютере, '
            'а ответы и подтверждения приходят сюда.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Pal.muted, fontSize: 12.5, height: 1.5),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildRows(BuildContext context, List<Map<String, dynamic>> rows) {
    final widgets = <Widget>[];
    final buffer = StringBuffer();
    void flushText() {
      final text = buffer.toString().trim();
      buffer.clear();
      if (text.isNotEmpty) {
        widgets.add(Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: MarkdownLite(text: text),
        ));
      }
    }

    for (final row in rows) {
      switch (row['kind']) {
        case 'userInput':
          flushText();
          widgets.add(_UserBubble(row: row, state: widget.state));
          break;
        case 'assistantText':
          final text = row['text'] as String? ?? '';
          if (text.isEmpty) break;
          if (buffer.isNotEmpty) buffer.write('\n\n');
          buffer.write(text);
          break;
        case 'reasoning':
          flushText();
          widgets.add(_ReasoningTile(
            text: row['text'] as String? ?? '',
            streaming: row['state'] == 'streaming',
          ));
          break;
        case 'toolCall':
          flushText();
          widgets.add(_ToolTile(row: row));
          break;
        case 'subagent':
          flushText();
          widgets.add(_SubagentTile(row: row));
          break;
        case 'timelineMarker':
          flushText();
          final label = row['label'] ?? row['text'];
          if (label is String && label.isNotEmpty) {
            widgets.add(Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Center(
                child: Text(label,
                    style: TextStyle(color: Pal.muted, fontSize: 10.5)),
              ),
            ));
          }
          break;
        case 'turnHeader':
          break;
      }
    }
    flushText();
    return widgets;
  }

  Widget _interactions(BuildContext context, List<Map<String, dynamic>> items) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(10, 4, 10, 0),
      color: Pal.bg,
      child: Column(
        children: [
          for (final interaction in items)
            _InteractionCard(
              interaction: interaction,
              onResolve: ({optionId, freeText, action, content}) =>
                  widget.state.resolveInteraction(
                interaction['interactionId'] as String? ?? '',
                optionId: optionId,
                freeText: freeText,
                action: action,
                content: content,
              ),
            ),
        ],
      ),
    );
  }

  /// Compact held-queue bar, desktop-style: count, auto-drain toggle, and one
  /// row per queued message with send-now / edit / delete.
  Widget _queueBar(BuildContext context) {
    final state = widget.state;
    final items = state.queueItems;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
      decoration: BoxDecoration(
        color: Pal.accent.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Pal.accent.withValues(alpha: 0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.queue_rounded, size: 13, color: Pal.accent),
              const SizedBox(width: 6),
              Text('Очередь ${items.length}',
                  style: TextStyle(fontSize: 11.5, color: Pal.accent)),
              const Spacer(),
              InkWell(
                onTap: () => state.setAutoDrain(!state.autoDrain),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Text(
                    state.autoDrain ? 'авто: вкл' : 'авто: выкл',
                    style: TextStyle(fontSize: 10.5, color: Pal.muted),
                  ),
                ),
              ),
            ],
          ),
          for (final item in items.take(3))
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${item['text'] ?? ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: Pal.text),
                  ),
                ),
                _queueAction(Icons.arrow_upward_rounded, 'Отправить сейчас',
                    () => state.sendQueuedNow('${item['queueItemId']}')),
                _queueAction(Icons.edit_outlined, 'Изменить',
                    () => _editQueueItem(context, item)),
                _queueAction(Icons.close_rounded, 'Удалить',
                    () => state.deleteQueueItem('${item['queueItemId']}')),
              ],
            ),
          if (items.length > 3)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 2),
              child: Text('ещё ${items.length - 3}…',
                  style: TextStyle(fontSize: 10, color: Pal.muted)),
            ),
        ],
      ),
    );
  }

  Widget _queueAction(IconData icon, String tooltip, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Tooltip(
        message: tooltip,
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Icon(icon, size: 15, color: Pal.muted),
        ),
      ),
    );
  }

  Future<void> _editQueueItem(
      BuildContext context, Map<String, dynamic> item) async {
    final controller = TextEditingController(text: '${item['text'] ?? ''}');
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Pal.surface,
        title: const Text('Изменить сообщение в очереди',
            style: TextStyle(fontSize: 15)),
        content: TextField(
          controller: controller,
          maxLines: 4,
          style: const TextStyle(fontSize: 13),
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.isEmpty) return;
    await widget.state.editQueueItem('${item['queueItemId']}', text);
  }

  Widget _composer(BuildContext context) {
    final state = widget.state;
    final running = state.conversation?.canStop == true ||
        state.conversation?.isRunning == true;
    return Container(
      padding: EdgeInsets.fromLTRB(
          8, 6, 8, 8 + MediaQuery.of(context).viewPadding.bottom * 0.2),
      decoration: BoxDecoration(
        color: Pal.bg,
        border: Border(top: BorderSide(color: Pal.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_pending.isNotEmpty) _pendingStrip(),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                tooltip: 'Прикрепить',
                onPressed: state.sending ? null : _pickAttachment,
                icon: Icon(Icons.attach_file_rounded, size: 20, color: Pal.muted),
                visualDensity: VisualDensity.compact,
              ),
              Expanded(
                child: TextField(
                  controller: _input,
                  focusNode: _focus,
                  minLines: 1,
                  maxLines: 6,
                  textInputAction: TextInputAction.newline,
                  style: TextStyle(fontSize: 13.5, height: 1.35),
                  decoration: InputDecoration(
                    hintText: 'Задача для агента…',
                    isDense: true,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              SizedBox(width: 6),
              if (running) ...[
                _CircleAction(
                  icon: Icons.add_rounded,
                  color: Pal.surface2,
                  tooltip: 'Поставить в очередь',
                  onTap: _send,
                ),
                SizedBox(width: 6),
                _CircleAction(
                  icon: Icons.stop_rounded,
                  color: Color(0xFFFF7B72),
                  tooltip: 'Остановить',
                  onTap: state.stop,
                ),
              ] else
                _CircleAction(
                  icon: Icons.arrow_upward_rounded,
                  color: Pal.accent,
                  tooltip: 'Отправить',
                  onTap: (_input.text.trim().isEmpty && _pending.isEmpty) ||
                          state.sending
                      ? null
                      : _send,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _pendingStrip() {
    return Padding(
      padding: EdgeInsets.only(bottom: 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (var i = 0; i < _pending.length; i++)
            Chip(
              backgroundColor: Pal.surface2,
              side: BorderSide(color: Pal.border),
              avatar: Icon(
                _pending[i].isImage
                    ? Icons.image_outlined
                    : Icons.insert_drive_file_outlined,
                size: 14,
                color: Pal.accent,
              ),
              label: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: 150),
                child: Text(_pending[i].fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11)),
              ),
              onDeleted: () => setState(() => _pending.removeAt(i)),
              deleteIcon: Icon(Icons.close_rounded, size: 14, color: Pal.muted),
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }

  Future<void> _pickAttachment() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Pal.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.photo_library_outlined, size: 20),
              title: Text('Фото из галереи'),
              onTap: () => Navigator.pop(context, 'photo'),
            ),
            ListTile(
              leading: Icon(Icons.folder_open_outlined, size: 20),
              title: Text('Файл с телефона'),
              onTap: () => Navigator.pop(context, 'file'),
            ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    try {
      final picker = ImagePicker();
      if (choice == 'photo') {
        final picked = await picker.pickImage(source: ImageSource.gallery);
        if (picked == null) return;
        final bytes = await picked.readAsBytes();
        final mime = picked.mimeType ??
            (picked.name.toLowerCase().endsWith('.png')
                ? 'image/png'
                : 'image/jpeg');
        setState(() => _pending.add(PendingAttachment(
              fileName: picked.name,
              mime: mime,
              bytes: bytes,
            )));
      } else {
        final pickedFiles = await FilePicker.pickFiles();
        final file = pickedFiles.firstOrNull;
        if (file == null) return;
        final bytes = await file.readAsBytes();
        setState(() => _pending.add(PendingAttachment(
              fileName: file.name,
              mime: _mimeFor(file.name),
              bytes: bytes,
            )));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось выбрать файл: $e')),
      );
    }
  }

  String _mimeFor(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.json')) return 'application/json';
    if (lower.endsWith('.md')) return 'text/markdown';
    if (lower.endsWith('.txt')) return 'text/plain';
    if (lower.endsWith('.zip')) return 'application/zip';
    return 'application/octet-stream';
  }

  /// Task/chat settings: LLM picker, mode, reasoning level. Mirrors the
  /// desktop composer toolbar — these are per-task, not app-wide.
  void _showTaskSettings(BuildContext context) {
    final state = widget.state;
    final conn = state.conversation;
    if (conn == null && !state.draft) return;
    state.loadModelCatalog();
    showModalBottomSheet(
      context: context,
      backgroundColor: Pal.surface,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => AnimatedBuilder(
        animation: state,
        builder: (context, _) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.fromLTRB(20, 14, 20, 20),
            children: [
              Row(children: [
                Text('Настройки задачи',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                Spacer(),
                IconButton(
                  tooltip: 'Обновить список моделей',
                  onPressed: () => state.loadModelCatalog(refresh: true),
                  icon: Icon(Icons.refresh_rounded, size: 18, color: Pal.muted),
                ),
              ]),
              SizedBox(height: 4),
              _modelSection(context),
              SizedBox(height: 6),
              if (conn != null)
                _choiceSection(
                  title: 'Режим',
                  current: conn.currentMode,
                  options: const [
                    ('build', 'Build'),
                    ('edit', 'Edit'),
                    ('plan', 'Plan'),
                    ('yolo', 'Yolo'),
                  ],
                  onPick: state.setMode,
                ),
              if (conn != null && conn.thoughtLevels.isNotEmpty)
                _choiceSection(
                  title: 'Уровень размышлений',
                  current: conn.currentThought,
                  options: conn.thoughtLevels.map((t) => (t, t)).toList(),
                  onPick: (value) async {
                    final provider = '${conn.config?['provider'] ?? ''}';
                    final model = '${conn.config?['model'] ?? ''}';
                    if (model.isEmpty) return;
                    await state.setModelParts(provider, model, thought: value);
                  },
                ),
              if (conn != null && conn.canStop) ...[
                SizedBox(height: 4),
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.of(context).pop();
                    state.stop();
                  },
                  icon: Icon(Icons.stop_rounded, size: 18),
                  label: Text('Остановить текущий ход'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _modelSection(BuildContext context) {
    final state = widget.state;
    final current = state.currentModelValue;
    final catalog = state.modelCatalog;

    if (state.modelCatalogLoading && catalog.isEmpty) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: Pal.accent),
          ),
        ),
      );
    }

    if (catalog.isEmpty) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Модель',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            SizedBox(height: 6),
            Text(
              current == null ? 'не выбрана' : current.replaceFirst(RegExp(r'^/'), ''),
              style: TextStyle(fontSize: 12, color: Pal.muted),
            ),
            if (state.modelCatalogError != null) ...[
              SizedBox(height: 6),
              Text(state.modelCatalogError!,
                  style: TextStyle(fontSize: 11.5, color: Color(0xFFFF9A93))),
              SizedBox(height: 4),
              TextButton(
                onPressed: () => state.loadModelCatalog(refresh: true),
                child: Text('Повторить'),
              ),
            ],
          ],
        ),
      );
    }

    // Group by provider, desktop-style.
    final groups = <String, List<ModelOption>>{};
    for (final m in catalog) {
      groups.putIfAbsent(m.providerName, () => []).add(m);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Модель',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        SizedBox(height: 4),
        for (final entry in groups.entries) ...[
          Padding(
            padding: EdgeInsets.only(top: 8, bottom: 2),
            child: Text(entry.key,
                style: TextStyle(
                    fontSize: 11, color: Pal.muted, fontWeight: FontWeight.w600)),
          ),
          for (final m in entry.value)
            _ModelTile(
              model: m,
              selected: m.value == current,
              onTap: () {
                Navigator.of(context).pop();
                state.setModelParts(m.providerId, m.modelId);
              },
            ),
        ],
      ],
    );
  }

  Widget _choiceSection({
    required String title,
    required String current,
    required List<(String, String)> options,
    required Future<void> Function(String) onPick,
  }) {
    return Padding(
      padding: EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final (value, label) in options)
                ChoiceChip(
                  label: Text(label, style: TextStyle(fontSize: 12)),
                  selected: value == current,
                  selectedColor: Pal.accent.withValues(alpha: 0.2),
                  backgroundColor: Pal.surface2,
                  side: BorderSide(color: Pal.border),
                  onSelected: (_) {
                    Navigator.of(context).pop();
                    onPick(value);
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ModelTile extends StatelessWidget {
  const _ModelTile({
    required this.model,
    required this.selected,
    required this.onTap,
  });

  final ModelOption model;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 4, vertical: 7),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              size: 16,
              color: selected ? Pal.accent : Pal.muted,
            ),
            SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(model.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13)),
                  if (model.description != null &&
                      model.description!.trim().isNotEmpty)
                    Text(model.description!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Pal.muted, fontSize: 10.5)),
                ],
              ),
            ),
            if (!model.enabled)
              Text('off', style: TextStyle(color: Pal.muted, fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

class _CircleAction extends StatelessWidget {
  const _CircleAction({
    required this.icon,
    required this.color,
    required this.onTap,
    this.tooltip,
  });

  final IconData icon;
  final Color color;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Tooltip(
      message: tooltip ?? '',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: enabled ? color : Pal.surface2,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 21, color: enabled ? Color(0xFF06231A) : Pal.muted),
        ),
      ),
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.row, required this.state});

  final Map<String, dynamic> row;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final text = row['text'] as String? ?? '';
    final attachments = row['attachments'];
    final files = attachments is List ? attachments.whereType<Map>().toList() : const [];
    return Padding(
      padding: EdgeInsets.only(bottom: 8, left: 40),
      child: Align(
        alignment: Alignment.centerRight,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Pal.accent.withValues(alpha: 0.13),
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
              bottomLeft: Radius.circular(16),
              bottomRight: Radius.circular(5),
            ),
            border: Border.all(color: Pal.accent.withValues(alpha: 0.25)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (files.isNotEmpty)
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final file in files)
                      _AttachmentView(
                        state: state,
                        data: file.cast<String, dynamic>(),
                      ),
                  ],
                ),
              if (text.isNotEmpty)
                SelectableText(text,
                    style: TextStyle(fontSize: 13.5, height: 1.4)),
            ],
          ),
        ),
      ),
    );
  }
}

class _AttachmentView extends StatefulWidget {
  const _AttachmentView({required this.state, required this.data});

  final AppState state;
  final Map<String, dynamic> data;

  @override
  State<_AttachmentView> createState() => _AttachmentViewState();
}

class _AttachmentViewState extends State<_AttachmentView> {
  Uint8List? _bytes;
  bool _failed = false;

  String get _mime => '${widget.data['mime'] ?? widget.data['mediaType'] ?? ''}';
  String get _name =>
      '${widget.data['fileName'] ?? widget.data['name'] ?? 'файл'}';
  bool get _isImage => _mime.startsWith('image/');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ref = widget.data['ref']?.toString();
    if (ref == null || ref.isEmpty) {
      if (mounted) setState(() => _failed = true);
      return;
    }
    final bytes = await widget.state.readAttachment(ref);
    if (!mounted) return;
    setState(() {
      _bytes = bytes;
      _failed = bytes == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isImage) {
      if (_bytes != null) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            _bytes!,
            width: 180,
            fit: BoxFit.cover,
          ),
        );
      }
      return Container(
        width: 120,
        height: 64,
        decoration: BoxDecoration(
          color: Pal.surface2,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Pal.border),
        ),
        alignment: Alignment.center,
        child: _failed
            ? Icon(Icons.broken_image_outlined, size: 18, color: Pal.muted)
            : SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 1.6, color: Pal.muted),
              ),
      );
    }
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: Pal.surface2,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Pal.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.insert_drive_file_outlined, size: 13, color: Pal.accent),
          SizedBox(width: 5),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 150),
            child: Text(_name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11)),
          ),
        ],
      ),
    );
  }
}

class _ReasoningTile extends StatefulWidget {
  const _ReasoningTile({required this.text, required this.streaming});
  final String text;
  final bool streaming;

  @override
  State<_ReasoningTile> createState() => _ReasoningTileState();
}

class _ReasoningTileState extends State<_ReasoningTile> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => setState(() => _open = !_open),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: Pal.surface.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Pal.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(Icons.psychology_outlined, size: 14, color: Pal.muted),
                SizedBox(width: 7),
                Text(widget.streaming ? 'Думает…' : 'Размышления',
                    style: TextStyle(color: Pal.muted, fontSize: 11.5)),
                Spacer(),
                Icon(_open ? Icons.expand_less : Icons.expand_more,
                    size: 16, color: Pal.muted),
              ]),
              if (_open) ...[
                SizedBox(height: 6),
                Text(widget.text,
                    style: TextStyle(color: Pal.muted, fontSize: 12, height: 1.5)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolTile extends StatefulWidget {
  const _ToolTile({required this.row});
  final Map<String, dynamic> row;

  @override
  State<_ToolTile> createState() => _ToolTileState();
}

class _ToolTileState extends State<_ToolTile> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final name = '${row['toolName'] ?? row['name'] ?? 'tool'}';
    final status = '${row['status'] ?? ''}';
    final input = row['inputText'] as String? ?? '';
    final output = row['output'];
    final outputText = output is Map ? '${output['text'] ?? ''}' : '';
    final error = row['error'];
    final color = toolStatusColor(status);
    return Container(
      margin: EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Pal.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Pal.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: EdgeInsets.fromLTRB(10, 8, 8, 8),
              child: Row(
                children: [
                  Icon(iconForTool(name), size: 16, color: color),
                  SizedBox(width: 9),
                  Expanded(
                    child: Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12.5, fontFamily: 'monospace')),
                  ),
                  if (status.isNotEmpty)
                    Text(_statusLabel(status),
                        style: TextStyle(fontSize: 10, color: color)),
                  SizedBox(width: 6),
                  Icon(_open ? Icons.expand_less : Icons.expand_more,
                      size: 17, color: Pal.muted),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (input.isNotEmpty) _kv('Вход', input),
                  if (outputText.isNotEmpty) _kv('Выход', outputText),
                  if (error is Map)
                    _kv('Ошибка', '${error['code'] ?? ''} ${error['message'] ?? ''}'),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _statusLabel(String status) => switch (status) {
        'running' || 'inputStreaming' => 'выполняется',
        'pendingApproval' => 'ждёт подтверждения',
        'success' => 'готово',
        'error' => 'ошибка',
        'cancelled' => 'отменено',
        _ => status,
      };

  Widget _kv(String label, String value) {
    return Padding(
      padding: EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: Pal.muted, fontSize: 10.5)),
          SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Pal.bg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Pal.border),
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: 260),
              child: SingleChildScrollView(
                child: SelectableText(value, style: monoStyle),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SubagentTile extends StatelessWidget {
  const _SubagentTile({required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final title = row['title'] ?? row['agentName'] ?? 'Подагент';
    final summary = row['summaryText'] as String? ?? '';
    return Container(
      margin: EdgeInsets.only(bottom: 8),
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Pal.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Pal.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.hub_outlined, size: 15, color: Color(0xFF7AA7FF)),
            SizedBox(width: 8),
            Expanded(
              child: Text('$title',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
            ),
            Text('${row['status'] ?? ''}',
                style: TextStyle(fontSize: 10, color: Pal.muted)),
          ]),
          if (summary.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(summary,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Pal.muted, fontSize: 11.5, height: 1.4)),
            ),
        ],
      ),
    );
  }
}

class _InteractionCard extends StatefulWidget {
  const _InteractionCard({required this.interaction, required this.onResolve});
  final Map<String, dynamic> interaction;
  final Future<void> Function({
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  }) onResolve;

  @override
  State<_InteractionCard> createState() => _InteractionCardState();
}

class _InteractionCardState extends State<_InteractionCard> {
  final _freeText = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _freeText.dispose();
    super.dispose();
  }

  Future<void> _resolve({
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onResolve(
        optionId: optionId,
        freeText: freeText,
        action: action,
        content: content,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final payload = widget.interaction['payload'];
    if (payload is! Map) return SizedBox.shrink();
    final kind = payload['kind'];
    final options = payload['options'];
    final freeText = payload['freeText'] == true;
    final title = kind == 'permission'
        ? 'Нужно подтверждение · ${payload['toolName'] ?? ''}'
        : 'Ждёт твоего ответа';
    final detail = kind == 'permission'
        ? payload['summary']
        : payload['prompt'];
    return Container(
      margin: EdgeInsets.only(bottom: 8),
      padding: EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Color(0xFF1D1A12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Color(0xFF5A4A22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Icon(Icons.shield_outlined, size: 17, color: Color(0xFFE3B341)),
            SizedBox(width: 8),
            Expanded(
              child: Text(title,
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
            ),
          ]),
          if (detail is String && detail.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(detail,
                  style: TextStyle(color: Pal.muted, fontSize: 12, height: 1.4)),
            ),
          if (options is List && options.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: 10),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final option in options.whereType<Map>())
                    _OptionButton(
                      option: option,
                      busy: _busy,
                      onTap: () {
                        final content = <String, dynamic>{
                          for (final key in const ['value', 'label', 'kind'])
                            if (option[key] != null) key: option[key],
                        };
                        _resolve(
                          optionId: option['optionId']?.toString(),
                          action: 'accept',
                          content: content,
                        );
                      },
                    ),
                ],
              ),
            ),
          if (freeText)
            Padding(
              padding: EdgeInsets.only(top: 10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _freeText,
                      style: TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: 'Ответ…',
                      ),
                    ),
                  ),
                  SizedBox(width: 8),
                  IconButton(
                    onPressed: _busy
                        ? null
                        : () => _resolve(freeText: _freeText.text.trim()),
                    icon: Icon(Icons.send_rounded, size: 18),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _OptionButton extends StatelessWidget {
  const _OptionButton({
    required this.option,
    required this.busy,
    required this.onTap,
  });

  final Map option;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final kind = '${option['kind'] ?? ''}';
    final label = '${option['label'] ?? _defaultLabel(kind)}';
    final allow = kind.startsWith('allow');
    return FilledButton(
      onPressed: busy ? null : onTap,
      style: FilledButton.styleFrom(
        backgroundColor: allow ? Pal.accent : Pal.surface2,
        foregroundColor: allow ? Color(0xFF06231A) : Pal.text,
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        textStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      child: Text(label),
    );
  }

  String _defaultLabel(String kind) => switch (kind) {
        'allowOnce' => 'Разрешить',
        'allowAlways' => 'Разрешать всегда',
        'deny' => 'Отклонить',
        'custom' => 'Свой ответ',
        _ => 'Выбрать',
      };
}

/// Markdown-lite: fenced code, inline code, bold.
class MarkdownLite extends StatelessWidget {
  const MarkdownLite({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final blocks = _parse(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final block in blocks)
          if (block.code != null)
            _CodeBlock(code: block.code!, lang: block.lang)
          else
            Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: SelectableText.rich(
                TextSpan(children: _inline(block.text!)),
                style: TextStyle(fontSize: 13.5, height: 1.45),
              ),
            ),
      ],
    );
  }

  List<_Block> _parse(String input) {
    final blocks = <_Block>[];
    final lines = input.split('\n');
    final buffer = StringBuffer();
    String? code;
    String? lang;
    for (final line in lines) {
      final fence = RegExp(r'^```(\w*)').firstMatch(line.trim());
      if (code == null && fence != null) {
        if (buffer.toString().trim().isNotEmpty) {
          blocks.add(_Block.text(buffer.toString().trimRight()));
          buffer.clear();
        }
        code = '';
        lang = fence.group(1);
      } else if (code != null && line.trim().startsWith('```')) {
        blocks.add(_Block.code(code.trimRight(), lang));
        code = null;
        lang = null;
      } else if (code != null) {
        code = '$code$line\n';
      } else {
        buffer.writeln(line);
      }
    }
    if (code != null) blocks.add(_Block.code(code.trimRight(), lang));
    if (buffer.toString().trim().isNotEmpty) {
      blocks.add(_Block.text(buffer.toString().trimRight()));
    }
    return blocks;
  }

  List<InlineSpan> _inline(String text) {
    final spans = <InlineSpan>[];
    final pattern = RegExp(r'(\*\*[^*]+\*\*|`[^`]+`)');
    var index = 0;
    for (final match in pattern.allMatches(text)) {
      if (match.start > index) {
        spans.add(TextSpan(text: text.substring(index, match.start)));
      }
      final token = match.group(0)!;
      if (token.startsWith('**')) {
        spans.add(TextSpan(
          text: token.substring(2, token.length - 2),
          style: TextStyle(fontWeight: FontWeight.w700),
        ));
      } else {
        spans.add(TextSpan(
          text: token.substring(1, token.length - 1),
          style: monoStyle.copyWith(fontSize: 12.8, color: Color(0xFF9FE8C3)),
        ));
      }
      index = match.end;
    }
    if (index < text.length) spans.add(TextSpan(text: text.substring(index)));
    return spans;
  }
}

class _Block {
  _Block.text(String this.text) : code = null, lang = null;
  _Block.code(String this.code, this.lang) : text = null;
  final String? text;
  final String? code;
  final String? lang;
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.code, this.lang});
  final String code;
  final String? lang;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Color(0xFF0F1418),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Pal.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: EdgeInsets.fromLTRB(12, 6, 6, 6),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: Pal.border)),
            ),
            child: Row(children: [
              Text((lang?.isEmpty ?? true) ? 'code' : lang!,
                  style: TextStyle(color: Pal.muted, fontSize: 10.5)),
              Spacer(),
              InkWell(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: code));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                        content: Text('Скопировано'),
                        duration: Duration(seconds: 1)),
                  );
                },
                child: Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.copy_rounded, size: 14, color: Pal.muted),
                ),
              ),
            ]),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.all(12),
            child: SelectableText(code, style: monoStyle),
          ),
        ],
      ),
    );
  }
}
