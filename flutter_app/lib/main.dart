import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'models/tunnel_config.dart';
import 'services/settings_service.dart';
import 'services/tunnel_service.dart';
import 'screens/home_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/logs_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final settings = SettingsService();
  await settings.init();

  final tunnel = TunnelService();
  // Restore persisted tunnels
  final raw = settings.rawTunnels;
  if (raw.isNotEmpty) {
    tunnel.setTunnels(raw.map(TunnelConfig.fromJson).toList());
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: tunnel),
        Provider.value(value: settings),
      ],
      child: const TcpTunnelApp(),
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

class _ShellState extends State<_Shell> {
  int _tabIndex = 0;

  static const _screens = [
    HomeScreen(),
    LogsScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
              icon: _NavIcon(icon: Icons.receipt_long_outlined, active: _tabIndex == 1),
              label: 'Logs',
            ),
            BottomNavigationBarItem(
              icon: _NavIcon(icon: Icons.settings_outlined, active: _tabIndex == 2),
              label: 'Settings',
            ),
          ],
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
