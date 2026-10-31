import 'package:flutter/material.dart';

import '../app_state.dart';
import 'chat_pane.dart';
import 'connect_page.dart';
import 'fold_layout.dart';
import 'sessions_pane.dart';
import 'theme.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        final fold = FoldInfo.of(context);
        final wide = fold.isUnfolded;
        final hasSession = state.hasSession;

        if (wide) {
          final leftWidth = fold.hasVerticalHinge
              ? fold.leftPaneWidth
              : (fold.size.width >= 1100 ? 360.0 : 320.0);
          final hinge = fold.hingeWidth;
          return Scaffold(
            body: SafeArea(
              child: Row(
                children: [
                  SizedBox(
                    width: leftWidth,
                    child: SessionsPane(
                      state: state,
                      onOpen: state.openSession,
                      onNew: state.newSession,
                      onSettings: () => _showSettings(context),
                    ),
                  ),
                  Container(
                    width: hinge > 0 ? hinge + 1 : 1,
                    color: hinge > 0 ? kBg : kBorder,
                  ),
                  Expanded(
                    child: hasSession
                        ? ChatPane(
                            state: state,
                            onBack: state.closeSession,
                            onSettings: () => _showSettings(context),
                          )
                        : _placeholder(context),
                  ),
                ],
              ),
            ),
          );
        }

        return Scaffold(
          body: SafeArea(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: hasSession
                  ? ChatPane(
                      key: const ValueKey('chat'),
                      state: state,
                      onBack: state.closeSession,
                      onSettings: () => _showSettings(context),
                    )
                  : SessionsPane(
                      key: const ValueKey('list'),
                      state: state,
                      onOpen: state.openSession,
                      onNew: state.newSession,
                      onSettings: () => _showSettings(context),
                    ),
            ),
          ),
        );
      },
    );
  }

  Widget _placeholder(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.devices_fold_outlined,
              size: 44, color: kMuted.withValues(alpha: 0.7)),
          const SizedBox(height: 14),
          const Text('Выбери сессию слева',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
          const SizedBox(height: 6),
          const Text('Экран разложен — работаем в две колонки',
              style: TextStyle(color: kMuted, fontSize: 12.5)),
        ],
      ),
    );
  }

  void _showSettings(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: kSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (sheetContext) => AnimatedBuilder(
        animation: state,
        builder: (context, _) {
          final fold = FoldInfo.of(context);
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                          color: kBorder, borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('Подключения',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  const SizedBox(height: 10),
                  for (final profile in state.profiles)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        profile.id == state.activeProfile?.id
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        color: profile.id == state.activeProfile?.id ? kAccent : kMuted,
                        size: 20,
                      ),
                      title: Text(profile.name, style: const TextStyle(fontSize: 14)),
                      subtitle: Text(profile.hubUrl,
                          style: const TextStyle(color: kMuted, fontSize: 11.5)),
                      onTap: () {
                        state.selectProfile(profile);
                        Navigator.of(sheetContext).pop();
                      },
                    ),
                  const SizedBox(height: 6),
                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => ConnectPage(state: state),
                      ));
                    },
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('Добавить подключение'),
                  ),
                  const Divider(height: 28),
                  const Text('Экран',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                  const SizedBox(height: 6),
                  Text(
                    '${fold.size.width.round()} × ${fold.size.height.round()} dp · '
                    '${fold.hasVerticalHinge ? 'вертикальный шарнир' : fold.horizontalHinge != null ? 'горизонт. шарнир' : 'без шарнира'} · '
                    '${fold.isUnfolded ? 'две колонки' : 'одна колонка'}',
                    style: const TextStyle(color: kMuted, fontSize: 12, height: 1.5),
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: () {
                      state.closeSession();
                      Navigator.of(sheetContext).pop();
                    },
                    icon: const Icon(Icons.link_off_rounded, size: 18),
                    label: const Text('Отключиться от сессии'),
                  ),
                  const SizedBox(height: 8),
                  const Center(
                    child: Text('ZCode Fold 0.1.0 · ACP over WebSocket',
                        style: TextStyle(color: kMuted, fontSize: 10.5)),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
