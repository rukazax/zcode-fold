import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import 'theme.dart';

class SessionsPane extends StatelessWidget {
  const SessionsPane({
    super.key,
    required this.state,
    required this.onOpen,
    required this.onNew,
    required this.onSettings,
    this.showHeader = true,
  });

  final AppState state;
  final void Function(SessionSummary session) onOpen;
  final VoidCallback onNew;
  final VoidCallback onSettings;
  final bool showHeader;

  @override
  Widget build(BuildContext context) {
    final sessions = state.sessions;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showHeader) _header(context),
        if (state.relayError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: _banner(state.relayError!),
          ),
        Expanded(
          child: state.sessionsLoading
              ? const Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2, color: kAccent),
                  ),
                )
              : sessions.isEmpty
                  ? _empty(context)
                  : RefreshIndicator(
                      color: kAccent,
                      backgroundColor: kSurface,
                      onRefresh: () async {
                        final w = state.workspace;
                        if (w != null) await state.openWorkspace(w);
                      },
                      child: ListView.builder(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 90),
                        itemCount: sessions.length + (state.workspaces.length > 1 ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (state.workspaces.length > 1 && index == 0) {
                            return _workspaceSwitcher(context);
                          }
                          final session = sessions[
                              index - (state.workspaces.length > 1 ? 1 : 0)];
                          return _sessionTile(context, session);
                        },
                      ),
                    ),
        ),
      ],
    );
  }

  Widget _header(BuildContext context) {
    final relay = state.relayState;
    final status = switch (relay.name) {
      'paired' => state.connected ? 'на связи' : 'подключаюсь…',
      'waiting' => 'ждёт подтверждения',
      'authenticating' => 'авторизация',
      'connecting' => 'подключение',
      'reconnecting' => 'переподключение',
      'error' => 'ошибка',
      'kicked' => 'сессия занята',
      _ => 'офлайн',
    };
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
                Text(state.activeDevice?.name ?? 'ZCode',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
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
                      '${state.workspace == null ? '' : '${AppState.workspaceTitle(state.workspace!)} · '}$status',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: kMuted, fontSize: 11),
                    ),
                  ),
                ]),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Переподключиться',
            onPressed: state.connecting ? null : state.connect,
            icon: state.connecting
                ? const SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh_rounded, size: 20, color: kMuted),
          ),
          IconButton(
            tooltip: 'Настройки',
            onPressed: onSettings,
            icon: const Icon(Icons.tune_rounded, size: 20, color: kMuted),
          ),
        ],
      ),
    );
  }

  Widget _workspaceSwitcher(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final w in state.workspaces)
            ChoiceChip(
              label: Text(AppState.workspaceTitle(w),
                  style: const TextStyle(fontSize: 11.5)),
              selected: identical(state.workspace, w) ||
                  AppState.workspaceKeyOf(w) == state.workspaceKey,
              selectedColor: kAccent.withValues(alpha: 0.2),
              backgroundColor: kSurface,
              side: const BorderSide(color: kBorder),
              onSelected: (_) => state.openWorkspace(w),
            ),
        ],
      ),
    );
  }

  Widget _sessionTile(BuildContext context, SessionSummary session) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => onOpen(session),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        decoration: BoxDecoration(
          color: kSurface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (session.running)
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2, color: kAccent),
                  )
                else
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: session.failed
                          ? const Color(0xFFFF7B72)
                          : kMuted.withValues(alpha: 0.5),
                      shape: BoxShape.circle,
                    ),
                  ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    session.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                  ),
                ),
                Text(formatTime(session.updatedAt),
                    style: const TextStyle(color: kMuted, fontSize: 11)),
              ],
            ),
            if (session.preview != null && session.preview!.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 16),
                child: Text(
                  session.preview!.trim(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: kMuted, fontSize: 11.5, height: 1.35),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _empty(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 42),
        const Icon(Icons.forum_outlined, size: 38, color: kMuted),
        const SizedBox(height: 12),
        const Center(
          child: Text('Пока нет сессий', style: TextStyle(fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: 6),
        const Center(
          child: Text(
            'Создай новую или открой существующую в ZCode на компьютере — '
            'список обновится сам.',
            textAlign: TextAlign.center,
            style: TextStyle(color: kMuted, fontSize: 12.5, height: 1.5),
          ),
        ),
        const SizedBox(height: 18),
        Center(
          child: FilledButton.icon(
            onPressed: onNew,
            icon: const Icon(Icons.add_comment_outlined, size: 18),
            label: const Text('Новая сессия'),
          ),
        ),
      ],
    );
  }

  Widget _banner(String text) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF2A1A1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF5A2A2A)),
      ),
      child: Row(children: [
        const Icon(Icons.link_off_rounded, size: 16, color: Color(0xFFFF9A93)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text,
              style: const TextStyle(color: Color(0xFFFFB4AD), fontSize: 12)),
        ),
      ]),
    );
  }
}
