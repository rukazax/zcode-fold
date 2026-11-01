import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/app_state.dart';
import 'src/ui/connect_page.dart';
import 'src/ui/home_page.dart';
import 'src/ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final secure = const FlutterSecureStorage();
  final state = AppState(prefs, secure);
  await state.init();
  runApp(ZCodeFoldApp(state: state));
}

class ZCodeFoldApp extends StatefulWidget {
  const ZCodeFoldApp({super.key, required this.state});

  final AppState state;

  @override
  State<ZCodeFoldApp> createState() => _ZCodeFoldAppState();
}

class _ZCodeFoldAppState extends State<ZCodeFoldApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.state.onAppResumed();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ZCode Fold',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      darkTheme: buildTheme(),
      themeMode: ThemeMode.dark,
      home: AnimatedBuilder(
        animation: widget.state,
        builder: (context, _) {
          if (widget.state.activeDevice == null) {
            return ConnectPage(state: widget.state);
          }
          return HomePage(state: widget.state);
        },
      ),
    );
  }
}
