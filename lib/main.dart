import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'app/controller.dart';
import 'ui/auth.dart';
import 'ui/home.dart';
import 'ui/kit.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.setTitle('Essaim');
    await windowManager.setMinimumSize(const Size(420, 640));
    // Closing the window must not stop the sharing.
    await windowManager.setPreventClose(true);
    await trayManager.setIcon('data/flutter_assets/assets/tray.ico');
    await trayManager.setToolTip('Essaim');
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'open', label: 'Ouvrir Essaim'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Quitter (arrête le partage)'),
    ]));
  }
  final app = AppController();
  runApp(EssaimApp(app));
  await app.init();
}

class EssaimApp extends StatefulWidget {
  const EssaimApp(this.app, {super.key});
  final AppController app;
  @override
  State<EssaimApp> createState() => _EssaimAppState();
}

class _EssaimAppState extends State<EssaimApp>
    with WidgetsBindingObserver, WindowListener, TrayListener {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isWindows) {
      windowManager.addListener(this);
      trayManager.addListener(this);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) widget.app.onBackgrounded();
    if (state == AppLifecycleState.resumed) widget.app.onResumed();
  }

  @override
  void onWindowClose() => windowManager.hide();

  @override
  void onTrayIconMouseDown() => _show();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  void _show() {
    windowManager.show();
    windowManager.focus();
  }

  @override
  void onTrayMenuItemClick(MenuItem item) {
    if (item.key == 'open') _show();
    if (item.key == 'quit') exit(0);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.app,
        builder: (_, _) => MaterialApp(
          title: 'Essaim',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          themeMode: widget.app.themeMode,
          home: switch (widget.app.phase) {
            Phase.loading => const Scaffold(body: Center(child: CircularProgressIndicator())),
            Phase.welcome => Welcome(widget.app),
            Phase.locked => LockScreen(widget.app),
            Phase.showCodes => RecoveryCodes(widget.app),
            Phase.home => Home(widget.app),
          },
        ),
      );
}
