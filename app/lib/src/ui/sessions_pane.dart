import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import 'theme.dart';

/// Desktop-style task sidebar: brand + device status, «Новая сессия», search,
/// pinned section, task list, and an account/settings footer. Width is driven
/// by the parent (≈30 % of the screen when unfolded).
class SessionsPane extends StatefulWidget {
  const SessionsPane({
    super.key,
    required this.state,
    required this.onOpen,
    required this.onNew,
    required this.onSettings,
    this.onOpenInProject,
    this.onCollapse,
    this.showHeader = true,
  });

  final AppState state;
  final void Function(SessionSummary session) onOpen;
  final void Function(ProjectFeed feed, SessionSummary session)?
  onOpenInProject;
  final VoidCallback onNew;
  final VoidCallback onSettings;
  final VoidCallback? onCollapse;
  final bool showHeader;

  @override
  State<SessionsPane> createState() => _SessionsPaneState();
}

class _SessionsPaneState extends State<SessionsPane> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    List<SessionSummary> filter(List<SessionSummary> list) {
      if (_query.isEmpty) return list;
      return list
          .where(
            (s) =>
                s.displayTitle.toLowerCase().contains(_query) ||
                (s.preview ?? '').toLowerCase().contains(_query),
          )
          .toList();
    }

    // Project → tasks. The active project is backed by the live
    // sessions-index; the others come from `project.readTree`.
    final projects = <_ProjectGroup>[];
    final activeWorkspace = state.workspace;
    if (activeWorkspace != null) {
      final key = AppState.workspaceKeyOf(activeWorkspace);
      if (key != null) {
        projects.add(
          _ProjectGroup(
            key: key,
            title: AppState.workspaceTitle(activeWorkspace),
            sessions: filter(state.sessions),
            loading: state.sessionsLoading,
            active: true,
            workspace: activeWorkspace,
          ),
        );
      }
    }
    for (final feed in state.projectFeeds) {
      final target = feed.appWorkspace ?? feed.project;
      final targetKey = AppState.workspaceKeyOf(target);
      if (targetKey == state.workspaceKey) continue;
      projects.add(
        _ProjectGroup(
          key: feed.key,
          title: feed.title,
          sessions: filter(feed.sessions),
          loading: feed.loading,
          error: feed.error,
          active: false,
          workspace: target,
          feed: feed,
        ),
      );
    }

    final pinned = <(_ProjectGroup, SessionSummary)>[];
    for (final group in projects) {
      for (final s in group.sessions) {
        if (state.isPinned(s.sessionId)) pinned.add((group, s));
      }
    }
    final hasAny = projects.any((g) => g.sessions.isNotEmpty);
    final queryMiss =
        _query.isNotEmpty &&
        pinned.isEmpty &&
        projects.every((g) => g.sessions.isEmpty);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showHeader) _header(context),
        _newTaskButton(context),
        _searchField(context),
        if (state.relayError != null)
          Padding(
            padding: EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: _banner(state.relayError!),
          ),
        Expanded(
          child: state.sessionsLoading && !hasAny
              ? Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Pal.accent,
                    ),
                  ),
                )
              : !hasAny && state.projectFeeds.isEmpty
              ? _empty(context)
              : RefreshIndicator(
                  color: Pal.accent,
                  backgroundColor: Pal.surface,
                  onRefresh: () async {
                    final w = state.workspace;
                    if (w != null) await state.openWorkspace(w);
                  },
                  child: ListView(
                    physics: AlwaysScrollableScrollPhysics(),
                    padding: EdgeInsets.fromLTRB(8, 2, 8, 12),
                    children: [
                      if (pinned.isNotEmpty) ...[
                        _sectionLabel(
                          context,
                          'Закреплённые',
                          icon: Icons.push_pin_outlined,
                        ),
                        for (final (group, s) in pinned)
                          _sessionTile(
                            context,
                            s,
                            group: group,
                            showProject: projects.length > 1,
                          ),
                      ],
                      if (queryMiss)
                        Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            'Ничего не найдено',
                            style: TextStyle(color: Pal.muted, fontSize: 12.5),
                          ),
                        ),
                      for (final group in projects)
                        _projectSection(context, group),
                    ],
                  ),
                ),
        ),
        _footer(context),
      ],
    );
  }

  Widget _projectSection(BuildContext context, _ProjectGroup group) {
    final state = widget.state;
    final rest = group.sessions
        .where((s) => !state.isPinned(s.sessionId))
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: group.active || group.workspace == null
              ? null
              : () => state.openWorkspace(
                  group.feed?.appWorkspace ?? group.workspace!,
                ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(8, 10, 6, 4),
            child: Row(
              children: [
                Icon(
                  group.active
                      ? Icons.folder_open_rounded
                      : Icons.folder_outlined,
                  size: 14,
                  color: group.active ? Pal.accent : Pal.muted,
                ),
                SizedBox(width: 7),
                Expanded(
                  child: Text(
                    group.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: group.active ? Pal.text : Pal.muted,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
                if (group.loading)
                  SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: Pal.muted,
                    ),
                  )
                else
                  Text(
                    '${group.sessions.length}',
                    style: TextStyle(color: Pal.muted, fontSize: 10),
                  ),
              ],
            ),
          ),
        ),
        if (group.error != null)
          Padding(
            padding: EdgeInsets.fromLTRB(30, 0, 8, 6),
            child: Text(
              group.error!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Color(0xFFE3B341), fontSize: 10.5),
            ),
          )
        else if (!group.loading && rest.isEmpty)
          Padding(
            padding: EdgeInsets.fromLTRB(30, 0, 8, 4),
            child: Text(
              'нет задач',
              style: TextStyle(color: Pal.muted, fontSize: 10.5),
            ),
          ),
        for (final s in rest) _sessionTile(context, s, group: group),
      ],
    );
  }

  // ---------------------------------------------------------------- header

  Widget _header(BuildContext context) {
    final state = widget.state;
    final status = switch (state.relayState.name) {
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
      padding: EdgeInsets.fromLTRB(12, 10, 6, 6),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: Pal.accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Text(
              'Z',
              style: TextStyle(
                color: Pal.accent,
                fontWeight: FontWeight.w900,
                fontSize: 17,
              ),
            ),
          ),
          SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  state.activeDevice?.name ?? 'ZCode',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                ),
                Row(
                  children: [
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
                        status,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Pal.muted, fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (widget.onCollapse != null)
            IconButton(
              tooltip: 'Свернуть список',
              onPressed: widget.onCollapse,
              icon: Icon(
                Icons.keyboard_double_arrow_left_rounded,
                size: 18,
                color: Pal.muted,
              ),
            ),
          PopupMenuButton<String>(
            tooltip: 'Ещё',
            color: Pal.surface2,
            icon: Icon(Icons.more_vert_rounded, size: 18, color: Pal.muted),
            onSelected: (value) {
              if (value == 'reconnect') state.connect();
              if (value == 'settings') widget.onSettings();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'reconnect',
                child: Text('Переподключиться'),
              ),
              PopupMenuItem(
                value: 'settings',
                child: Text('Настройки приложения'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- controls

  Widget _newTaskButton(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 2, 12, 8),
      child: FilledButton.icon(
        onPressed: widget.onNew,
        icon: Icon(Icons.add_rounded, size: 18),
        label: Text('Новая задача'),
        style: FilledButton.styleFrom(
          backgroundColor: Pal.accent,
          foregroundColor: Color(0xFF06231A),
          padding: EdgeInsets.symmetric(vertical: 12),
          textStyle: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
        ),
      ),
    );
  }

  Widget _searchField(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: TextField(
        controller: _search,
        style: TextStyle(fontSize: 13),
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Поиск по задачам',
          prefixIcon: Icon(Icons.search_rounded, size: 18, color: Pal.muted),
          prefixIconConstraints: BoxConstraints(minWidth: 34, minHeight: 30),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: Icon(Icons.close_rounded, size: 15, color: Pal.muted),
                  onPressed: () {
                    _search.clear();
                    setState(() => _query = '');
                  },
                ),
          contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        ),
        onChanged: (value) =>
            setState(() => _query = value.trim().toLowerCase()),
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String label, {IconData? icon}) {
    return Padding(
      padding: EdgeInsets.fromLTRB(8, 10, 8, 4),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: Pal.muted),
            SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              color: Pal.muted,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _sessionTile(
    BuildContext context,
    SessionSummary session, {
    _ProjectGroup? group,
    bool showProject = false,
  }) {
    final state = widget.state;
    final pinned = state.isPinned(session.sessionId);
    final active = state.sessionId == session.sessionId;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => _open(group, session),
      onLongPress: () => _showSessionMenu(context, session, group: group),
      child: Container(
        margin: EdgeInsets.only(bottom: 4),
        padding: EdgeInsets.fromLTRB(10, 8, 6, 8),
        decoration: BoxDecoration(
          color: active
              ? Pal.accent.withValues(alpha: 0.10)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: active
                ? Pal.accent.withValues(alpha: 0.35)
                : Colors.transparent,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.only(top: 3),
              child: session.running
                  ? SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        color: Pal.accent,
                      ),
                    )
                  : Container(
                      width: 6,
                      height: 6,
                      margin: EdgeInsets.only(left: 2),
                      decoration: BoxDecoration(
                        color: session.failed
                            ? Color(0xFFFF7B72)
                            : Pal.muted.withValues(alpha: 0.45),
                        shape: BoxShape.circle,
                      ),
                    ),
            ),
            SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    session.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.3,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                  if (showProject && group != null)
                    Padding(
                      padding: EdgeInsets.only(top: 1),
                      child: Text(
                        group.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Pal.accent, fontSize: 9.5),
                      ),
                    ),
                  if (session.preview != null &&
                      session.preview!.trim().isNotEmpty)
                    Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Text(
                        session.preview!.trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Pal.muted,
                          fontSize: 11,
                          height: 1.3,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(width: 4),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  formatTime(session.updatedAt),
                  style: TextStyle(color: Pal.muted, fontSize: 10),
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => state.togglePin(session.sessionId),
                  child: Padding(
                    padding: EdgeInsets.only(top: 2, left: 4, bottom: 2),
                    child: Icon(
                      pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                      size: 12,
                      color: pinned ? Pal.accent : Pal.muted,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _open(_ProjectGroup? group, SessionSummary session) {
    final feed = group?.feed;
    final target = feed?.appWorkspace;
    if (feed != null &&
        target != null &&
        AppState.workspaceKeyOf(target) != widget.state.workspaceKey &&
        widget.onOpenInProject != null) {
      widget.onOpenInProject!(feed, session);
    } else {
      widget.onOpen(session);
    }
  }

  void _showSessionMenu(
    BuildContext context,
    SessionSummary session, {
    _ProjectGroup? group,
  }) {
    final state = widget.state;
    showModalBottomSheet(
      context: context,
      backgroundColor: Pal.surface,
      isDismissible: true,
      enableDrag: true,
      showDragHandle: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                state.isPinned(session.sessionId)
                    ? Icons.push_pin
                    : Icons.push_pin_outlined,
                size: 20,
              ),
              title: Text(
                state.isPinned(session.sessionId)
                    ? 'Снять закрепление'
                    : 'Закрепить',
              ),
              onTap: () {
                state.togglePin(session.sessionId);
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: Icon(Icons.open_in_new_rounded, size: 20),
              title: Text('Открыть'),
              onTap: () {
                Navigator.pop(context);
                _open(group, session);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _empty(BuildContext context) {
    return ListView(
      physics: AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.all(20),
      children: [
        SizedBox(height: 30),
        Icon(Icons.forum_outlined, size: 34, color: Pal.muted),
        SizedBox(height: 10),
        Center(
          child: Text(
            'Пока нет задач',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
          ),
        ),
        SizedBox(height: 6),
        Center(
          child: Text(
            'Создай новую или открой существующую в ZCode на компьютере — '
            'список обновится сам.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Pal.muted, fontSize: 11.5, height: 1.45),
          ),
        ),
      ],
    );
  }

  Widget _footer(BuildContext context) {
    final state = widget.state;
    return Container(
      padding: EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Pal.border)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: Pal.surface2,
            child: Icon(
              Icons.person_outline_rounded,
              size: 14,
              color: Pal.muted,
            ),
          ),
          SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  state.activeDevice?.name ?? 'Компьютер',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
                ),
                Text(
                  state.workspace == null
                      ? 'нет проекта'
                      : AppState.workspaceTitle(state.workspace!),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Pal.muted, fontSize: 10),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Настройки приложения',
            onPressed: widget.onSettings,
            icon: Icon(Icons.settings_outlined, size: 19, color: Pal.muted),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _banner(String text) {
    return Container(
      padding: EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Color(0xFF2A1A1A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Color(0xFF5A2A2A)),
      ),
      child: Row(
        children: [
          Icon(Icons.link_off_rounded, size: 15, color: Color(0xFFFF9A93)),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: Color(0xFFFFB4AD), fontSize: 11.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProjectGroup {
  _ProjectGroup({
    required this.key,
    required this.title,
    required this.sessions,
    required this.loading,
    required this.active,
    this.error,
    this.workspace,
    this.feed,
  });

  final String key;
  final String title;
  final List<SessionSummary> sessions;
  final bool loading;
  final bool active;
  final String? error;
  final Map<String, dynamic>? workspace;
  final ProjectFeed? feed;
}
