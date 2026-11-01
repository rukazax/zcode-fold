import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models.dart';
import '../zcode/conversation.dart' show ConfigOption, ConversationState;
import 'theme.dart';

class ChatPane extends StatefulWidget {
  const ChatPane({
    super.key,
    required this.state,
    required this.onBack,
    required this.onSettings,
  });

  final AppState state;
  final VoidCallback onBack;
  final VoidCallback onSettings;

  @override
  State<ChatPane> createState() => _ChatPaneState();
}

class _ChatPaneState extends State<ChatPane> {
  final _scroll = ScrollController();
  final _input = TextEditingController();
  final _focus = FocusNode();
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
          SnackBar(content: Text(error), duration: const Duration(seconds: 4)),
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
    if (text.trim().isEmpty || widget.state.sending) return;
    _input.clear();
    await widget.state.send(text);
    _atBottom = true;
    _focus.requestFocus();
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
            color: const Color(0xFF231D10),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
            child: const Text(
              'Связь с компьютером потеряна — жду переподключения. '
              'Проверь, что ZCode открыт и мобильный доступ включён.',
              style: TextStyle(color: Color(0xFFE3B341), fontSize: 11.5),
            ),
          ),
        Expanded(
          child: state.openingSession && rows.isEmpty
              ? const Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2, color: kAccent),
                  ),
                )
              : rows.isEmpty
                  ? _empty(context)
                  : ListView(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(14, 14, 14, 18),
                      children: [
                        if (state.conversation?.canLoadOlder == true)
                          Center(
                            child: TextButton.icon(
                              onPressed: state.loadOlder,
                              icon: const Icon(Icons.history_rounded, size: 16),
                              label: const Text('Загрузить раньше'),
                            ),
                          ),
                        ..._buildRows(context, rows),
                      ],
                    ),
        ),
        if (interactions.isNotEmpty) _interactions(context, interactions),
        _composer(context),
      ],
    );
  }

  Widget _header(BuildContext context) {
    final state = widget.state;
    final conn = state.conversation;
    final usage = _usage(state);
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: kBorder)),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: widget.onBack,
            icon: const Icon(Icons.arrow_back_rounded, size: 20),
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
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5),
                ),
                Row(children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: state.connected ? kAccent : const Color(0xFFE3B341),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      conn?.isRunning == true
                          ? 'модель работает…'
                          : (state.connected ? 'на связи' : 'нет связи'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: kMuted, fontSize: 11),
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
              onTap: () => _showConfig(context),
            ),
          if (usage != null) _usageChip(usage),
          IconButton(
            onPressed: widget.onSettings,
            icon: const Icon(Icons.tune_rounded, size: 20, color: kMuted),
            tooltip: 'Настройки',
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
        margin: const EdgeInsets.only(right: 4),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(
          color: kSurface2,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kBorder),
        ),
        child: Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11)),
      ),
    );
  }

  Widget _usageChip(({double fraction, int used, int size}) usage) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
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
                backgroundColor: kSurface2,
                color: usage.fraction > 0.8 ? const Color(0xFFFF7B72) : kAccent,
              ),
              Text('${(usage.fraction * 100).round()}',
                  style: const TextStyle(fontSize: 8.5, color: kMuted)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final draft = widget.state.sessionId == null;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 34),
        const Icon(Icons.auto_awesome_rounded, size: 34, color: kAccent),
        const SizedBox(height: 12),
        Center(
          child: Text(
            draft ? 'Новая сессия' : 'Пустая сессия',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
          ),
        ),
        const SizedBox(height: 6),
        const Center(
          child: Text(
            'Напиши задачу — агент работает на компьютере, '
            'а ответы и подтверждения приходят сюда.',
            textAlign: TextAlign.center,
            style: TextStyle(color: kMuted, fontSize: 12.5, height: 1.5),
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
          padding: const EdgeInsets.only(bottom: 8),
          child: MarkdownLite(text: text),
        ));
      }
    }

    for (final row in rows) {
      switch (row['kind']) {
        case 'userInput':
          flushText();
          widgets.add(_UserBubble(row: row));
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
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Center(
                child: Text(label,
                    style: const TextStyle(color: kMuted, fontSize: 10.5)),
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
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 0),
      color: kBg,
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

  Widget _composer(BuildContext context) {
    final state = widget.state;
    final running = state.conversation?.canStop == true ||
        state.conversation?.isRunning == true;
    return Container(
      padding: EdgeInsets.fromLTRB(
          12, 8, 12, 8 + MediaQuery.of(context).viewPadding.bottom * 0.2),
      decoration: const BoxDecoration(
        color: kBg,
        border: Border(top: BorderSide(color: kBorder)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _input,
              focusNode: _focus,
              minLines: 1,
              maxLines: 6,
              textInputAction: TextInputAction.newline,
              style: const TextStyle(fontSize: 14, height: 1.35),
              decoration: const InputDecoration(
                hintText: 'Задача для агента…',
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(width: 8),
          if (running)
            _CircleAction(
              icon: Icons.stop_rounded,
              color: const Color(0xFFFF7B72),
              tooltip: 'Остановить',
              onTap: state.stop,
            )
          else
            _CircleAction(
              icon: Icons.arrow_upward_rounded,
              color: kAccent,
              tooltip: 'Отправить',
              onTap: _input.text.trim().isEmpty || state.sending ? null : _send,
            ),
        ],
      ),
    );
  }

  void _showConfig(BuildContext context) {
    final state = widget.state;
    final conn = state.conversation;
    if (conn == null) return;
    final prep = state.prep;
    final modes = [
      ('build', 'Build'),
      ('edit', 'Edit'),
      ('plan', 'Plan'),
      ('yolo', 'Yolo'),
    ];
    final thoughts = conn.thoughtLevels;
    showModalBottomSheet(
      context: context,
      backgroundColor: kSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(20),
          children: [
            const Text('Модель и режим',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 14),
            // Model: the catalog lives on the desktop and is not exposed to
            // remote terminals in 3.17 — show the current one and point at the
            // slash command for switching.
            if (prep != null)
              for (final option in prep.configOptions)
                if (option.id == 'model')
                  _configSection(context, option, conn),
            if (prep == null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Модель',
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Text(
                      '${conn.config?['provider'] ?? ''}/${conn.config?['model'] ?? ''}'
                          .replaceFirst(RegExp(r'^/'), ''),
                      style: const TextStyle(fontSize: 12, color: kMuted),
                    ),
                    const SizedBox(height: 4),
                    const Text('Сменить модель — командой /model в чате',
                        style: TextStyle(fontSize: 11.5, color: kMuted)),
                  ],
                ),
              ),
            _choiceSection(
              title: 'Режим',
              current: conn.currentMode,
              options: modes,
              onPick: state.setMode,
            ),
            if (thoughts.isNotEmpty)
              _choiceSection(
                title: 'Уровень размышлений',
                current: conn.currentThought,
                options: thoughts.map((t) => (t, t)).toList(),
                onPick: (value) async {
                  final provider = '${conn.config?['provider'] ?? ''}';
                  final model = '${conn.config?['model'] ?? ''}';
                  if (model.isEmpty) return;
                  await state.setModel(
                    provider.isNotEmpty ? '$provider/$model' : model,
                    thought: value,
                  );
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _choiceSection({
    required String title,
    required String current,
    required List<(String, String)> options,
    required Future<void> Function(String) onPick,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final (value, label) in options)
                ChoiceChip(
                  label: Text(label, style: const TextStyle(fontSize: 12)),
                  selected: value == current,
                  selectedColor: kAccent.withValues(alpha: 0.2),
                  backgroundColor: kSurface2,
                  side: const BorderSide(color: kBorder),
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

  Widget _configSection(
      BuildContext context, ConfigOption option, ConversationState conn) {
    final state = widget.state;
    final isMode = option.id == 'mode';
    final isModel = option.id == 'model';
    final String current = isModel
        ? '${conn.config?['provider'] ?? ''}/${conn.config?['model'] ?? ''}'
        : isMode
            ? conn.currentMode
            : conn.currentThought;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(option.name,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final value in option.options)
                ChoiceChip(
                  label: Text(value.name, style: const TextStyle(fontSize: 12)),
                  selected: value.value == current ||
                      (isModel && current == '/'),
                  selectedColor: kAccent.withValues(alpha: 0.2),
                  backgroundColor: kSurface2,
                  side: const BorderSide(color: kBorder),
                  onSelected: (_) async {
                    Navigator.of(context).pop();
                    if (isMode) {
                      await state.setMode(value.value);
                    } else if (isModel) {
                      await state.setModel(value.value);
                    } else {
                      final provider = '${conn.config?['provider'] ?? ''}';
                      final model = '${conn.config?['model'] ?? ''}';
                      final base = provider.isNotEmpty && model.isNotEmpty
                          ? '$provider/$model'
                          : prepModelValue(state);
                      await state.setModel(base, thought: value.value);
                    }
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  String prepModelValue(AppState state) {
    final option = state.prep?.option('model');
    return '${option?.currentValue ?? ''}';
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
            color: enabled ? color : kSurface2,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 21, color: enabled ? const Color(0xFF06231A) : kMuted),
        ),
      ),
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final text = row['text'] as String? ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12, left: 40),
      child: Align(
        alignment: Alignment.centerRight,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: kAccent.withValues(alpha: 0.13),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
              bottomLeft: Radius.circular(16),
              bottomRight: Radius.circular(5),
            ),
            border: Border.all(color: kAccent.withValues(alpha: 0.25)),
          ),
          child: SelectableText(text,
              style: const TextStyle(fontSize: 14, height: 1.45)),
        ),
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
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => setState(() => _open = !_open),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: kSurface.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: kBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.psychology_outlined, size: 14, color: kMuted),
                const SizedBox(width: 7),
                Text(widget.streaming ? 'Думает…' : 'Размышления',
                    style: const TextStyle(color: kMuted, fontSize: 11.5)),
                const Spacer(),
                Icon(_open ? Icons.expand_less : Icons.expand_more,
                    size: 16, color: kMuted),
              ]),
              if (_open) ...[
                const SizedBox(height: 6),
                Text(widget.text,
                    style: const TextStyle(color: kMuted, fontSize: 12, height: 1.5)),
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
    final running = status == 'running' ||
        status == 'inputStreaming' ||
        status == 'pendingApproval';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
              child: Row(
                children: [
                  Icon(iconForTool(name), size: 16, color: color),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12.5, fontFamily: 'monospace')),
                  ),
                  if (status.isNotEmpty)
                    Text(_statusLabel(status),
                        style: TextStyle(fontSize: 10, color: color)),
                  const SizedBox(width: 6),
                  Icon(_open ? Icons.expand_less : Icons.expand_more,
                      size: 17, color: kMuted),
                ],
              ),
            ),
          ),
          if (_open || running)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
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
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: kMuted, fontSize: 10.5)),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: kBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: kBorder),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: SingleChildScrollView(
                child: SelectableText(value, style: kMono),
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
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.hub_outlined, size: 15, color: Color(0xFF7AA7FF)),
            const SizedBox(width: 8),
            Expanded(
              child: Text('$title',
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
            ),
            Text('${row['status'] ?? ''}',
                style: const TextStyle(fontSize: 10, color: kMuted)),
          ]),
          if (summary.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(summary,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: kMuted, fontSize: 11.5, height: 1.4)),
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
    if (payload is! Map) return const SizedBox.shrink();
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
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1D1A12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF5A4A22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            const Icon(Icons.shield_outlined, size: 17, color: Color(0xFFE3B341)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(title,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
            ),
          ]),
          if (detail is String && detail.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(detail,
                  style: const TextStyle(color: kMuted, fontSize: 12, height: 1.4)),
            ),
          if (options is List && options.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
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
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _freeText,
                      style: const TextStyle(fontSize: 13),
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: 'Ответ…',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _busy
                        ? null
                        : () => _resolve(freeText: _freeText.text.trim()),
                    icon: const Icon(Icons.send_rounded, size: 18),
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
        backgroundColor: allow ? kAccent : kSurface2,
        foregroundColor: allow ? const Color(0xFF06231A) : kText,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
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
              padding: const EdgeInsets.only(bottom: 6),
              child: SelectableText.rich(
                TextSpan(children: _inline(block.text!)),
                style: const TextStyle(fontSize: 14, height: 1.5),
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
          style: const TextStyle(fontWeight: FontWeight.w700),
        ));
      } else {
        spans.add(TextSpan(
          text: token.substring(1, token.length - 1),
          style: kMono.copyWith(fontSize: 12.8, color: const Color(0xFF9FE8C3)),
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
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0F1418),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: kBorder)),
            ),
            child: Row(children: [
              Text((lang?.isEmpty ?? true) ? 'code' : lang!,
                  style: const TextStyle(color: kMuted, fontSize: 10.5)),
              const Spacer(),
              InkWell(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: code));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Скопировано'),
                        duration: Duration(seconds: 1)),
                  );
                },
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.copy_rounded, size: 14, color: kMuted),
                ),
              ),
            ]),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(12),
            child: SelectableText(code, style: kMono),
          ),
        ],
      ),
    );
  }
}
