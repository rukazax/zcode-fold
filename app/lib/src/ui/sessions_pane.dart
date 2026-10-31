import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import 'theme.dart';

class SessionsPane extends StatefulWidget {
  const SessionsPane({
    super.key,
    required this.state,
    required this.onOpen,
    required this.onNew,
    required this.onSettings,
    this.showHeader = true,
  });

  final AppState state;
  final void Function(HubInstance instance, HubSessionInfo session) onOpen;
  final void Function(HubInstance instance) onNew;
  final VoidCallback onSettings;
  final bool showHeader;

  @override
  State<SessionsPane> createState() => _SessionsPaneState();
}

class _SessionsPaneState extends State<SessionsPane> {
  bool _expandedAll = true;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showHeader) _header(context),
        if (state.instancesError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: _banner(state.instancesError!, Icons.cloud_off_outlined),
          ),
        if (state.connectError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: _banner(state.connectError!, Icons.link_off_rounded),
          ),
        Expanded(
          child: state.instances.isEmpty
              ? _empty(context)
              : RefreshIndicator(
                  color: kAccent,
                  backgroundColor: kSurface,
                  onRefresh: () => state.refreshInstances(),
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                    children: [
                      for (final instance in state.instances) _instanceCard(context, instance),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _header(BuildContext context) {
    final state = widget.state;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: kAccent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(11),
            ),
            alignment: Alignment.center,
            child: const Text('Z',
                style: TextStyle(color: kAccent, fontWeight: FontWeight.w900, fontSize: 18)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(state.activeProfile?.name ?? 'ZCode',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                Row(children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: state.connectionsHealthy ? kAccent : const Color(0xFFFF7B72),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    state.connectionsHealthy
                        ? 'hub на связи · ${state.instances.length} инст.'
                        : 'hub недоступен',
                    style: const TextStyle(color: kMuted, fontSize: 11),
                  ),
                ]),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Обновить',
            onPressed: state.loadingInstances ? null : () => state.refreshInstances(),
            icon: state.loadingInstances
                ? const SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh_rounded, size: 20, color: kMuted),
          ),
          IconButton(
            tooltip: 'Настройки',
            onPressed: widget.onSettings,
            icon: const Icon(Icons.tune_rounded, size: 20, color: kMuted),
          ),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 40),
        const Icon(Icons.terminal_rounded, size: 40, color: kMuted),
        const SizedBox(height: 12),
        const Center(
          child: Text('Нет живых инстансов ZCode',
              style: TextStyle(fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: 6),
        const Center(
          child: Text(
            'Открой проект в ZCode на ПК или запусти\nbackend\\start.ps1 — и обнови список.',
            textAlign: TextAlign.center,
            style: TextStyle(color: kMuted, fontSize: 12.5, height: 1.5),
          ),
        ),
        const SizedBox(height: 20),
        Center(
          child: OutlinedButton.icon(
            onPressed: () => widget.state.refreshInstances(),
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Обновить'),
          ),
        ),
      ],
    );
  }

  Widget _instanceCard(BuildContext context, HubInstance instance) {
    final expanded = _expandedAll;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            onTap: () => setState(() => _expandedAll = !_expandedAll),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 8, 10),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: kSurface2,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: const Icon(Icons.folder_open_rounded, size: 17, color: kAccent),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(instance.workspaceName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 14)),
                        Text(
                          '${instance.sessions.length} сессий'
                          '${instance.origin == 'serve' ? ' · headless' : ''}',
                          style: const TextStyle(color: kMuted, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Новый чат',
                    onPressed: () => widget.onNew(instance),
                    icon: const Icon(Icons.add_comment_outlined, size: 19, color: kAccent),
                  ),
                  Icon(expanded ? Icons.expand_less : Icons.expand_more,
                      size: 20, color: kMuted),
                ],
              ),
            ),
          ),
          if (expanded) ...[
            const Divider(height: 1),
            if (instance.sessions.isEmpty)
              const Padding(
                padding: EdgeInsets.all(14),
                child: Text('Пока нет сессий — начни новый чат',
                    style: TextStyle(color: kMuted, fontSize: 12.5)),
              )
            else
              ...instance.sessions.map((s) => _sessionRow(context, instance, s)),
          ],
        ],
      ),
    );
  }

  Widget _sessionRow(BuildContext context, HubInstance instance, HubSessionInfo session) {
    final title = (session.title?.trim().isNotEmpty ?? false) ? session.title!.trim() : 'Без названия';
    return InkWell(
      onTap: () => widget.onOpen(instance, session),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
        child: Row(
          children: [
            session.running
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: kAccent),
                  )
                : Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      color: kMuted.withValues(alpha: 0.5),
                      shape: BoxShape.circle,
                    ),
                  ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5)),
            ),
            if (session.running)
              const Padding(
                padding: EdgeInsets.only(right: 6),
                child: Text('работает', style: TextStyle(color: kAccent, fontSize: 10.5)),
              ),
            Text(formatTime(session.updatedAt),
                style: const TextStyle(color: kMuted, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Widget _banner(String text, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF2A1A1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF5A2A2A)),
      ),
      child: Row(children: [
        Icon(icon, size: 16, color: const Color(0xFFFF9A93)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text,
              style: const TextStyle(color: Color(0xFFFFB4AD), fontSize: 12)),
        ),
      ]),
    );
  }
}
