import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../models.dart';
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
  bool _userAtBottom = true;
  String? _lastSessionId;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onState);
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      _userAtBottom = _scroll.position.maxScrollExtent - _scroll.offset < 120;
    });
    _loadDraft();
  }

  @override
  void dispose() {
    widget.state.removeListener(_onState);
    _scroll.dispose();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _loadDraft() {
    final draft = widget.state.draftFor(widget.state.sessionId);
    if (draft != null) _input.text = draft;
  }

  void _onState() {
    if (!mounted) return;
    if (_lastSessionId != widget.state.sessionId) {
      _lastSessionId = widget.state.sessionId;
      _input.clear();
      _loadDraft();
    }
    final error = widget.state.takeLastError();
    if (error != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error), duration: const Duration(seconds: 3)),
        );
      });
    }
    if (_userAtBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        _scroll.animateTo(
          _scroll.position.maxScrollExtent + 400,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      });
    }
    setState(() {});
  }

  Future<void> _send() async {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    await widget.state.saveDraft(widget.state.sessionId, '');
    await widget.state.send(text);
    _userAtBottom = true;
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return Column(
      children: [
        _header(context),
        if (!state.connected && state.hasSession) _reconnectBanner(),
        Expanded(
          child: state.messages.isEmpty ? _empty(context) : _messageList(context),
        ),
        if (state.plan.isNotEmpty) _planBar(context),
        if (state.permission != null) _permissionCard(context),
        _composer(context),
      ],
    );
  }

  Widget _header(BuildContext context) {
    final state = widget.state;
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 8, 8, 8),
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
                  state.sessionTitle?.trim().isNotEmpty == true
                      ? state.sessionTitle!
                      : 'Сессия',
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
                      state.connected
                          ? (state.running ? 'модель пишет…' : 'на связи')
                          : 'переподключение…',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: kMuted, fontSize: 11),
                    ),
                  ),
                  if (state.workspaceLabel.isNotEmpty) ...[
                    const Text(' · ', style: TextStyle(color: kMuted, fontSize: 11)),
                    Flexible(
                      child: Text(state.workspaceLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: kMuted, fontSize: 11)),
                    ),
                  ],
                ]),
              ],
            ),
          ),
          ..._configChips(context),
          if (state.usage != null) _usageChip(state.usage!),
          IconButton(
            onPressed: widget.onSettings,
            icon: const Icon(Icons.tune_rounded, size: 20, color: kMuted),
            tooltip: 'Настройки',
          ),
        ],
      ),
    );
  }

  List<Widget> _configChips(BuildContext context) {
    final state = widget.state;
    final visible = state.configs
        .where((c) => (c.id == 'model' || c.id == 'mode') && c.options.isNotEmpty)
        .toList();
    if (visible.isEmpty) return const [];
    return [
      for (final config in visible)
        PopupMenuButton<String>(
          tooltip: config.name ?? config.id,
          color: kSurface2,
          onSelected: (v) => state.setConfig(config.id, v),
          itemBuilder: (context) => [
            for (final option in config.options)
              PopupMenuItem(
                value: option.value,
                child: Row(children: [
                  Icon(
                    option.value == config.currentValue
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 16,
                    color: option.value == config.currentValue ? kAccent : kMuted,
                  ),
                  const SizedBox(width: 8),
                  Text(option.name, style: const TextStyle(fontSize: 13)),
                ]),
              ),
          ],
          child: Container(
            margin: const EdgeInsets.only(right: 4),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
            decoration: BoxDecoration(
              color: kSurface2,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: kBorder),
            ),
            child: Text(
              config.displayValue(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: kText),
            ),
          ),
        ),
    ];
  }

  Widget _usageChip(UsageInfo usage) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Tooltip(
        message: 'Контекст: ${humanBytes(usage.used)} из ${humanBytes(usage.size)}',
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

  Widget _reconnectBanner() {
    return Container(
      width: double.infinity,
      color: const Color(0xFF231D10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: const Row(children: [
        SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFE3B341))),
        SizedBox(width: 8),
        Text('Связь пропала — переподключаюсь и восстанавливаю историю',
            style: TextStyle(color: Color(0xFFE3B341), fontSize: 11.5)),
      ]),
    );
  }

  Widget _empty(BuildContext context) {
    final commands = widget.state.commands;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 30),
        const Icon(Icons.auto_awesome_rounded, size: 34, color: kAccent),
        const SizedBox(height: 12),
        const Center(
          child: Text('Напиши задачу — агент работает на ПК',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
        ),
        const SizedBox(height: 6),
        const Center(
          child: Text(
            'Ответы, вызовы инструментов и запросы\nподтверждений придут сюда в реальном времени.',
            textAlign: TextAlign.center,
            style: TextStyle(color: kMuted, fontSize: 12.5, height: 1.5),
          ),
        ),
        if (commands.isNotEmpty) ...[
          const SizedBox(height: 24),
          const Text('Команды сессии',
              style: TextStyle(color: kMuted, fontSize: 11, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final c in commands.take(12))
                ActionChip(
                  backgroundColor: kSurface,
                  side: const BorderSide(color: kBorder),
                  label: Text('/${c.name}', style: const TextStyle(fontSize: 11.5)),
                  onPressed: () {
                    _input.text = '/${c.name} ';
                    _focus.requestFocus();
                  },
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _messageList(BuildContext context) {
    final messages = widget.state.messages;
    return SelectionArea(
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(14, 16, 14, 20),
        itemCount: messages.length,
        itemBuilder: (context, index) => _MessageView(
          message: messages[index],
          showRole: index == 0 || messages[index - 1].role != messages[index].role,
        ),
      ),
    );
  }

  Widget _planBar(BuildContext context) {
    final entries = widget.state.plan;
    final done = entries.where((e) => e.status == 'completed').length;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: kBorder)),
        color: kSurface,
      ),
      child: Row(children: [
        const Icon(Icons.checklist_rounded, size: 15, color: kAccent),
        const SizedBox(width: 8),
        Expanded(
          child: Text('План: $done из ${entries.length}',
              style: const TextStyle(fontSize: 11.5, color: kMuted)),
        ),
        InkWell(
          onTap: () => _showPlan(context),
          child: const Text('открыть', style: TextStyle(fontSize: 11.5, color: kAccent)),
        ),
      ]),
    );
  }

  void _showPlan(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: kSurface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(20),
          children: [
            for (final e in widget.state.plan)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(
                    e.status == 'completed'
                        ? Icons.check_circle_rounded
                        : e.status == 'in_progress'
                            ? Icons.timelapse_rounded
                            : Icons.radio_button_unchecked,
                    size: 16,
                    color: e.status == 'completed'
                        ? kAccent
                        : e.status == 'in_progress'
                            ? const Color(0xFF7AA7FF)
                            : kMuted,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Text(e.content,
                          style: const TextStyle(fontSize: 13, height: 1.4))),
                ]),
              ),
          ],
        ),
      ),
    );
  }

  Widget _permissionCard(BuildContext context) {
    final p = widget.state.permission!;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
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
              child: Text(p.title,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 13.5)),
            ),
            InkWell(
              onTap: () => widget.state.respondPermission(null),
              child: const Icon(Icons.close_rounded, size: 18, color: kMuted),
            ),
          ]),
          if (p.detail != null && p.detail!.isNotEmpty) ...[
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 120),
              child: SingleChildScrollView(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: kBg,
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: kBorder),
                  ),
                  child: Text(p.detail!, style: kMono),
                ),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in p.options)
                _PermissionButton(
                  label: option.name,
                  kind: option.kind,
                  onPressed: () => widget.state.respondPermission(option.id),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _composer(BuildContext context) {
    final state = widget.state;
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
              onChanged: (value) {
                state.saveDraft(state.sessionId, value);
                setState(() {});
              },
            ),
          ),
          const SizedBox(width: 8),
          if (state.running)
            _CircleAction(
              icon: Icons.stop_rounded,
              color: const Color(0xFFFF7B72),
              onTap: state.cancelTurn,
              tooltip: 'Остановить',
            )
          else
            _CircleAction(
              icon: Icons.arrow_upward_rounded,
              color: kAccent,
              onTap: _input.text.trim().isEmpty ? null : _send,
              tooltip: 'Отправить',
            ),
        ],
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
            color: enabled ? color : kSurface2,
            shape: BoxShape.circle,
          ),
          child: Icon(icon,
              size: 21, color: enabled ? const Color(0xFF06231A) : kMuted),
        ),
      ),
    );
  }
}

class _PermissionButton extends StatelessWidget {
  const _PermissionButton({required this.label, this.kind, required this.onPressed});

  final String label;
  final String? kind;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final allow = kind == null || kind!.startsWith('allow');
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: allow ? kAccent : kSurface2,
        foregroundColor: allow ? const Color(0xFF06231A) : kText,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      child: Text(label),
    );
  }
}

class _MessageView extends StatelessWidget {
  const _MessageView({required this.message, required this.showRole});

  final ChatMessage message;
  final bool showRole;

  @override
  Widget build(BuildContext context) {
    final user = message.isUser;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: user ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (showRole)
            Padding(
              padding: const EdgeInsets.only(bottom: 6, left: 2),
              child: Text(user ? 'ты' : 'ZCode',
                  style: const TextStyle(
                      color: kMuted, fontSize: 10.5, fontWeight: FontWeight.w600)),
            ),
          if (user)
            Container(
              constraints: const BoxConstraints(maxWidth: 560),
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
              child: Text(
                message.plainText,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.45,
                  color: message.collapsed ? kMuted : kText,
                  fontStyle: message.collapsed ? FontStyle.italic : FontStyle.normal,
                ),
              ),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final part in message.parts) _PartView(part: part),
              ],
            ),
        ],
      ),
    );
  }
}

class _PartView extends StatelessWidget {
  const _PartView({required this.part});

  final ChatPart part;

  @override
  Widget build(BuildContext context) {
    switch (part.type) {
      case 'thought':
        return _ThoughtView(text: part.text);
      case 'tool':
        return _ToolCard(tool: part.tool!);
      default:
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: MarkdownLite(text: part.text),
        );
    }
  }
}

class _ThoughtView extends StatefulWidget {
  const _ThoughtView({required this.text});
  final String text;

  @override
  State<_ThoughtView> createState() => _ThoughtViewState();
}

class _ThoughtViewState extends State<_ThoughtView> {
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
                const Text('Размышления',
                    style: TextStyle(color: kMuted, fontSize: 11.5)),
                const Spacer(),
                Icon(_open ? Icons.expand_less : Icons.expand_more,
                    size: 16, color: kMuted),
              ]),
              if (_open) ...[
                const SizedBox(height: 6),
                Text(widget.text,
                    style: const TextStyle(
                        color: kMuted, fontSize: 12, height: 1.5)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolCard extends StatefulWidget {
  const _ToolCard({required this.tool});
  final ToolCallData tool;

  @override
  State<_ToolCard> createState() => _ToolCardState();
}

class _ToolCardState extends State<_ToolCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final tool = widget.tool;
    final color = colorForStatus(tool.status, Theme.of(context).colorScheme);
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
                  Icon(iconForKind(tool.kind), size: 16, color: color),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      tool.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, height: 1.3),
                    ),
                  ),
                  Container(
                    width: 7,
                    height: 7,
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
                  Icon(_open ? Icons.expand_less : Icons.expand_more,
                      size: 17, color: kMuted),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (tool.text.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: kBg,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: kBorder),
                      ),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 260),
                        child: SingleChildScrollView(
                          child: Text(tool.text, style: kMono),
                        ),
                      ),
                    ),
                  if (tool.rawInput != null) ...[
                    const SizedBox(height: 6),
                    SelectableText(
                      const JsonEncoder.withIndent('  ').convert(tool.rawInput),
                      style: kMono.copyWith(color: kMuted, fontSize: 11),
                    ),
                  ],
                  if (tool.text.isEmpty && tool.rawInput == null)
                    const Text('Нет вывода', style: TextStyle(color: kMuted, fontSize: 11.5)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Tiny markdown renderer: fenced code blocks, inline code and bold.
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
          style: const TextStyle(fontWeight: FontWeight.w700, color: kText),
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
                    const SnackBar(content: Text('Скопировано'), duration: Duration(seconds: 1)),
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
