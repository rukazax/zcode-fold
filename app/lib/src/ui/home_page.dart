import 'package:flutter/material.dart';

import '../app_state.dart';
import 'chat_pane.dart';
import 'connect_page.dart';
import 'file_browser_page.dart';
import 'fold_layout.dart';
import 'pc_bridge_dialog.dart';
import 'sessions_pane.dart';
import 'theme.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.state});

  final AppState state;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// Swipe-collapse state for the sessions pane (wide layout only).
  bool _listCollapsed = false;
  static const _collapsedWidth = 44.0;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        final fold = FoldInfo.of(context);
        final wide = fold.isUnfolded;
        final open = state.hasOpenChat;

        if (wide) {
          // ~30% of the screen for the task sidebar (a bit wider than ¼ so the
          // desktop-style header/search fit), clamped to stay usable.
          final share = fold.size.width * 0.30;
          final leftWidth = (share.clamp(250.0, 480.0)).toDouble();
          final hinge = fold.hingeWidth;
          return Scaffold(
            body: SafeArea(
              child: Row(
                children: [
                  AnimatedContainer(
                    duration: Duration(milliseconds: 200),
                    curve: Curves.easeOutCubic,
                    width: _listCollapsed ? _collapsedWidth : leftWidth,
                    child: _listCollapsed
                        ? _collapsedRail()
                        : GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onHorizontalDragEnd: (details) {
                              final v = details.primaryVelocity ?? 0;
                              if (v < -180) {
                                setState(() => _listCollapsed = true);
                              }
                            },
                            child: SessionsPane(
                              state: state,
                              onOpen: (s) => state.openTaskAnywhere(
                                s.sessionId,
                                title: s.title,
                              ),
                              onOpenInProject: (feed, s) =>
                                  state.openSessionInProject(feed, s),
                              onNew: state.startDraft,
                              onSettings: () => _showSettings(context),
                              onCollapse: () =>
                                  setState(() => _listCollapsed = true),
                            ),
                          ),
                  ),
                  Container(
                    width: hinge > 0 ? hinge + 1 : 1,
                    color: hinge > 0 ? Pal.bg : Pal.border,
                  ),
                  Expanded(
                    child: open
                        ? ChatPane(state: state, onBack: state.closeChat)
                        : _placeholder(),
                  ),
                ],
              ),
            ),
          );
        }

        return Scaffold(
          body: SafeArea(
            child: AnimatedSwitcher(
              duration: Duration(milliseconds: 180),
              child: open
                  ? ChatPane(
                      key: ValueKey('chat'),
                      state: state,
                      onBack: state.closeChat,
                    )
                  : SessionsPane(
                      key: ValueKey('list'),
                      state: state,
                      onOpen: (s) =>
                          state.openTaskAnywhere(s.sessionId, title: s.title),
                      onOpenInProject: (feed, s) =>
                          state.openSessionInProject(feed, s),
                      onNew: state.startDraft,
                      onSettings: () => _showSettings(context),
                    ),
            ),
          ),
        );
      },
    );
  }

  /// Narrow rail shown when the sessions pane is swiped away. Swipe right (or
  /// tap) to bring the list back.
  Widget _collapsedRail() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragEnd: (details) {
        final v = details.primaryVelocity ?? 0;
        if (v > 120) setState(() => _listCollapsed = false);
      },
      onTap: () => setState(() => _listCollapsed = false),
      child: Container(
        decoration: BoxDecoration(
          color: Pal.surface,
          border: Border(right: BorderSide(color: Pal.border)),
        ),
        child: Column(
          children: [
            SizedBox(height: 10),
            Icon(
              Icons.keyboard_double_arrow_right_rounded,
              size: 18,
              color: Pal.muted,
            ),
            SizedBox(height: 6),
            Icon(Icons.forum_outlined, size: 18, color: Pal.accent),
            SizedBox(height: 6),
            RotatedBox(
              quarterTurns: 3,
              child: Text(
                'сессии · ${widget.state.sessions.length}',
                style: TextStyle(fontSize: 10, color: Pal.muted),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.devices_fold_outlined,
            size: 44,
            color: Pal.muted.withValues(alpha: 0.7),
          ),
          SizedBox(height: 14),
          Text(
            'Выбери сессию слева',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
          ),
          SizedBox(height: 6),
          Text(
            'Или начни новую — экран разложен, работаем в две колонки',
            textAlign: TextAlign.center,
            style: TextStyle(color: Pal.muted, fontSize: 12.5),
          ),
        ],
      ),
    );
  }

  void _showSettings(BuildContext context) {
    final state = widget.state;
    showModalBottomSheet(
      context: context,
      backgroundColor: Pal.surface,
      isScrollControlled: true,
      isDismissible: true,
      enableDrag: true,
      showDragHandle: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) => AnimatedBuilder(
        animation: state,
        builder: (context, _) {
          final fold = FoldInfo.of(context);
          return SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(20, 14, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Pal.border,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  SizedBox(height: 16),
                  Text(
                    'Компьютеры',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                  SizedBox(height: 10),
                  for (final device in state.devices)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        device.id == state.activeDevice?.id
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        color: device.id == state.activeDevice?.id
                            ? Pal.accent
                            : Pal.muted,
                        size: 20,
                      ),
                      title: Text(device.name, style: TextStyle(fontSize: 14)),
                      subtitle: Text(
                        _host(device.url),
                        style: TextStyle(color: Pal.muted, fontSize: 11.5),
                      ),
                      trailing: IconButton(
                        icon: Icon(
                          Icons.delete_outline,
                          size: 18,
                          color: Pal.muted,
                        ),
                        onPressed: () => state.removeDevice(device),
                      ),
                      onTap: () {
                        state.selectDevice(device);
                        Navigator.of(sheetContext).pop();
                      },
                    ),
                  SizedBox(height: 6),
                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ConnectPage(state: state),
                        ),
                      );
                    },
                    icon: Icon(Icons.add_rounded, size: 18),
                    label: Text('Подключить компьютер'),
                  ),
                  SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                      _showPcFilesDialog(context);
                    },
                    icon: Icon(Icons.folder_open_rounded, size: 18),
                    label: Text(
                      state.hasPcFiles
                          ? 'Файлы ПК: ${state.bridgeFsUrl}'
                          : 'Файлы ПК (мост)',
                    ),
                  ),
                  Divider(height: 28),
                  Text(
                    'Экран',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                  SizedBox(height: 6),
                  Text(
                    '${fold.size.width.round()} × ${fold.size.height.round()} dp · '
                    '${fold.hasVerticalHinge
                        ? 'вертикальный шарнир'
                        : fold.horizontalHinge != null
                        ? 'горизонт. шарнир'
                        : 'без шарнира'} · '
                    '${fold.isUnfolded ? 'две колонки' : 'одна колонка'}',
                    style: TextStyle(
                      color: Pal.muted,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                  SizedBox(height: 14),
                  Text(
                    'Проект: ${state.workspace == null ? '—' : AppState.workspaceTitle(state.workspace!)}',
                    style: TextStyle(color: Pal.muted, fontSize: 12),
                  ),
                  Text(
                    'Связь: ${state.relayState.name}',
                    style: TextStyle(color: Pal.muted, fontSize: 12),
                  ),
                  Text(
                    'Аккаунт Z.ai: ${state.hasJwt ? 'токен есть' : 'нужен вход'}',
                    style: TextStyle(
                      color: state.hasJwt ? Pal.muted : const Color(0xFFE3B341),
                      fontSize: 12,
                    ),
                  ),
                  if (state.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        state.error!,
                        style: const TextStyle(
                          color: Color(0xFFFF9A93),
                          fontSize: 11.5,
                          height: 1.35,
                        ),
                      ),
                    ),
                  if (state.loginRequired)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () {
                          Navigator.of(sheetContext).pop();
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ConnectPage(state: state),
                            ),
                          );
                        },
                        child: const Text('Подключить / войти'),
                      ),
                    ),
                  SizedBox(height: 6),
                  Text(
                    'Список: ${state.sessions.length} сессий · ${_listCollapsed ? 'свёрнут' : 'развёрнут'} · свайп влево/вправо',
                    style: TextStyle(color: Pal.muted, fontSize: 12),
                  ),
                  SizedBox(height: 6),
                  Text(
                    'Просмотр, подключение и подтверждения — бесплатны: '
                    'токены списываются, только когда отправлена задача.',
                    style: TextStyle(
                      color: Pal.muted,
                      fontSize: 11.5,
                      height: 1.45,
                    ),
                  ),
                  SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: () {
                      state.disconnect();
                      Navigator.of(sheetContext).pop();
                    },
                    icon: Icon(Icons.link_off_rounded, size: 18),
                    label: Text('Отключиться'),
                  ),
                  SizedBox(height: 8),
                  Center(
                    child: Text(
                      'ZCode Fold 0.6.3 · прямое подключение ZCode Remote',
                      style: TextStyle(color: Pal.muted, fontSize: 10.5),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _showPcFilesDialog(BuildContext context) async {
    final state = widget.state;
    // Saved bridge → open the project folder directly, no questions asked.
    var ready = await state.autoConfigurePc();
    if (!ready) {
      if (!context.mounted) return;
      ready = await showPcBridgeDialog(context, state);
    }
    if (ready && context.mounted) {
      final workspace = state.workspace;
      final path = workspace == null
          ? null
          : workspace['workspacePath']?.toString();
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => FileBrowserPage(
            state: state,
            initialPath: (path == null || path.isEmpty) ? null : path,
          ),
        ),
      );
    }
  }

  String _host(String url) {
    final parsed = Uri.tryParse(url);
    if (parsed == null) return url;
    final name =
        parsed.queryParameters['name'] ?? parsed.queryParameters['mid'];
    return name != null ? '$name · ${parsed.host}' : parsed.host;
  }
}
