import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart';

import 'models/tunnel_config.dart';
import 'services/settings_service.dart';
import 'services/tunnel_service.dart';
import 'services/updater_service.dart';
import 'screens/home_screen.dart';
import 'screens/file_explorer_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/logs_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize communication port for foreground task
  FlutterForegroundTask.initCommunicationPort();

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();

    WindowOptions windowOptions = const WindowOptions(
      size: Size(800, 600),
      minimumSize: Size(450, 550),
      center: true,
      title: 'TCP Tunnel',
    );

    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });

    await windowManager.setPreventClose(true);
  }

  if (Platform.isAndroid) {
    // Request notification permission (required for Android 13+)
    await Permission.notification.request();

    // Ask user to exempt us from battery optimization so Android cannot
    // kill our process when we go to the background.
    if (await Permission.ignoreBatteryOptimizations.isDenied) {
      await Permission.ignoreBatteryOptimizations.request();
    }

    // Configure flutter_foreground_task — runs a proper Android Foreground
    // Service that survives Home button / app switching.
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'tcp_tunnel_channel',
        channelName: 'TCP Tunnel',
        channelDescription: 'Keeps the TCP tunnel connected in the background',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  final settings = SettingsService();
  await settings.init();

  final tunnel = TunnelService();
  // Restore persisted tunnels for the selected profile
  final raw = settings.rawTunnels;
  if (raw.isNotEmpty) {
    final filtered = raw
        .map(TunnelConfig.fromJson)
        .where((t) => t.profileId == settings.selectedProfileId)
        .toList();
    tunnel.setTunnels(filtered);
  }

  runApp(
    WithForegroundTask(
      child: MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: tunnel),
          ChangeNotifierProvider.value(value: settings),
        ],
        child: const TcpTunnelApp(),
      ),
    ),
  );
}

class TcpTunnelApp extends StatelessWidget {
  const TcpTunnelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TCP Tunnel',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(),
      home: const _Shell(),
    );
  }

  ThemeData _buildTheme() {
    final base = ThemeData.dark();
    return base.copyWith(
      scaffoldBackgroundColor: const Color(0xFF0A0E1A),
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFF00BFA5),
        secondary: Color(0xFF00E5FF),
        surface: Color(0xFF0F1629),
        error: Colors.redAccent,
      ),
      textTheme: GoogleFonts.interTextTheme(base.textTheme).apply(
        bodyColor: Colors.white,
        displayColor: Colors.white,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF0A0E1A),
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
        iconTheme: IconThemeData(color: Colors.white),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: Color(0xFF0D1120),
        selectedItemColor: Color(0xFF00BFA5),
        unselectedItemColor: Color(0xFF4A5568),
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
    );
  }
}

class _Shell extends StatefulWidget {
  const _Shell();
  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> with WindowListener, TrayListener {
  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      windowManager.addListener(this);
      trayManager.addListener(this);
      _initTray();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkForUpdates();
    });
  }

  @override
  void dispose() {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
    }
    super.dispose();
  }

  void _initTray() async {
    try {
      final String iconPath = Platform.isWindows ? 'assets/app_icon.ico' : 'assets/app_icon.png';
      await trayManager.setIcon(iconPath);
      
      final Menu menu = Menu(
        items: [
          MenuItem(
            key: 'show_app',
            label: 'Show App',
          ),
          MenuItem.separator(),
          MenuItem(
            key: 'exit_app',
            label: 'Exit',
          ),
        ],
      );
      await trayManager.setContextMenu(menu);
      await trayManager.setToolTip('TCP Tunnel');
    } catch (e) {
      debugPrint('Failed to initialize tray: $e');
    }
  }

  @override
  void onWindowClose() async {
    final isPreventClose = await windowManager.isPreventClose();
    if (isPreventClose) {
      await windowManager.hide();
    }
  }

  @override
  void onTrayIconMouseDown() async {
    final isVisible = await windowManager.isVisible();
    if (isVisible) {
      await windowManager.hide();
    } else {
      await windowManager.show();
      await windowManager.focus();
    }
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    if (menuItem.key == 'show_app') {
      await windowManager.show();
      await windowManager.focus();
    } else if (menuItem.key == 'exit_app') {
      await windowManager.setPreventClose(false);
      await windowManager.close();
    }
  }

  void _checkForUpdates() async {
    final settings = context.read<SettingsService>();
    final release = await UpdaterService.checkLatestRelease(settings.githubToken);
    if (release == null || !mounted) return;

    final String latestVersion = (release['tag_name'] as String).replaceFirst('v', '');
    final String notes = release['body'] ?? 'No release notes provided.';
    final assets = release['assets'] as List<dynamic>;

    // Find update asset depending on platform (APK for Android, ZIP/EXE for Windows)
    String targetExtension = Platform.isAndroid ? '.apk' : '.zip';
    final asset = assets.firstWhere(
      (a) => (a['name'] as String).endsWith(targetExtension),
      orElse: () => null,
    );

    if (asset == null) return;
    final String downloadUrl = asset['browser_download_url'];

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text('Update Available (v$latestVersion)'),
        backgroundColor: const Color(0xFF0F1629),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('A new version of TCP Tunnel is available. Would you like to update?'),
            const SizedBox(height: 12),
            const Text('Release Notes:', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Container(
              constraints: const BoxConstraints(maxHeight: 150),
              width: double.maxFinite,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(4),
              ),
              child: SingleChildScrollView(
                child: Text(notes, style: const TextStyle(fontSize: 12, color: Colors.white70)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Later'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              _downloadAndInstall(downloadUrl);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00BFA5),
              foregroundColor: Colors.white,
            ),
            child: const Text('Update Now'),
          ),
        ],
      ),
    );
  }

  void _downloadAndInstall(String url) {
    double progress = 0.0;
    StateSetter? dialogStateSetter;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF0F1629),
          title: const Text('Downloading Update...'),
          content: StatefulBuilder(
            builder: (context, setState) {
              dialogStateSetter = setState;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(
                    value: progress,
                    color: const Color(0xFF00BFA5),
                    backgroundColor: Colors.white24,
                  ),
                  const SizedBox(height: 12),
                  Text('${(progress * 100).toStringAsFixed(0)}%'),
                ],
              );
            },
          ),
        );
      },
    );

    UpdaterService.downloadAndInstallApk(
      url,
      (p) {
        if (dialogStateSetter != null) {
          dialogStateSetter!(() {
            progress = p;
          });
        }
      },
      (error) {
        Navigator.of(context).pop(); // Close download dialog
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: const Color(0xFF0F1629),
            title: const Text('Update Failed'),
            content: Text(error),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      },
      () {
        Navigator.of(context).pop(); // Close download dialog
      },
    );
  }

  static const _screens = [
    HomeScreen(),
    FileExplorerScreen(),
    LogsScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        const MethodChannel('com.tcptunnel.app/lifecycle').invokeMethod('moveTaskToBack');
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0A0E1A),
      // ── App bar ────────────────────────────────────────────────────────
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E1A),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFF00BFA5).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.lan_outlined, color: Color(0xFF00BFA5), size: 18),
            ),
            const SizedBox(width: 10),
            const Text('TCP Tunnel',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white)),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF00BFA5).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF00BFA5).withValues(alpha: 0.3), width: 0.5),
              ),
              child: const Text('v1.0',
                  style: TextStyle(color: Color(0xFF00BFA5), fontSize: 10, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: const Color(0xFF1A2340)),
        ),
      ),

      // ── Body ───────────────────────────────────────────────────────────
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: _screens[_tabIndex],
      ),

      // ── Bottom nav ─────────────────────────────────────────────────────
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Color(0xFF1A2340), width: 1)),
        ),
        child: BottomNavigationBar(
          currentIndex: _tabIndex,
          onTap: (i) => setState(() => _tabIndex = i),
          items: [
            BottomNavigationBarItem(
              icon: _NavIcon(icon: Icons.alt_route_rounded, active: _tabIndex == 0),
              label: 'Tunnels',
            ),
            BottomNavigationBarItem(
              icon: _NavIcon(icon: Icons.folder_open_outlined, active: _tabIndex == 1),
              label: 'Files',
            ),
            BottomNavigationBarItem(
              icon: _NavIcon(icon: Icons.receipt_long_outlined, active: _tabIndex == 2),
              label: 'Logs',
            ),
            BottomNavigationBarItem(
              icon: _NavIcon(icon: Icons.settings_outlined, active: _tabIndex == 3),
              label: 'Settings',
            ),
          ],
        ),
      ),
    ),
  );
}
}

class _NavIcon extends StatelessWidget {
  final IconData icon;
  final bool active;
  const _NavIcon({required this.icon, required this.active});

  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF00BFA5).withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon),
      );
}
