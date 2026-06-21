import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../models/log_entry.dart';
import '../services/tunnel_service.dart';

class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});
  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  final _scrollCtrl = ScrollController();
  bool _autoScroll = true;

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_autoScroll && _scrollCtrl.hasClients) {
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    }
  }

  Color _levelColor(LogLevel level) {
    switch (level) {
      case LogLevel.success: return const Color(0xFF00BFA5);
      case LogLevel.info:    return const Color(0xFF8892A4);
      case LogLevel.warning: return Colors.orange.shade400;
      case LogLevel.error:   return Colors.redAccent;
      case LogLevel.debug:   return const Color(0xFF448AFF);
    }
  }

  String _levelLabel(LogLevel level) {
    switch (level) {
      case LogLevel.success: return 'OK ';
      case LogLevel.info:    return 'INF';
      case LogLevel.warning: return 'WRN';
      case LogLevel.error:   return 'ERR';
      case LogLevel.debug:   return 'DBG';
    }
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<TunnelService>();
    final logs = svc.logs;

    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          // ── Toolbar ────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A2340),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF2A3450)),
                  ),
                  child: Text(
                    '${logs.length} entries',
                    style: const TextStyle(color: Color(0xFF8892A4), fontSize: 12),
                  ),
                ),
                const Spacer(),
                // Auto-scroll toggle
                _ToolbarBtn(
                  icon: _autoScroll ? Icons.vertical_align_bottom : Icons.vertical_align_center,
                  label: 'Auto-scroll',
                  active: _autoScroll,
                  onTap: () => setState(() => _autoScroll = !_autoScroll),
                ),
                const SizedBox(width: 8),
                // Clear button
                _ToolbarBtn(
                  icon: Icons.delete_sweep_outlined,
                  label: 'Clear',
                  active: false,
                  onTap: svc.clearLogs,
                ),
              ],
            ),
          ),

          // ── Log list ───────────────────────────────────────────────────
          Expanded(
            child: logs.isEmpty
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.receipt_long_outlined, size: 48, color: Color(0xFF2A3450)),
                        SizedBox(height: 12),
                        Text('No logs yet', style: TextStyle(color: Color(0xFF8892A4), fontSize: 14)),
                        SizedBox(height: 4),
                        Text('Connect to see tunnel activity', style: TextStyle(color: Color(0xFF5A6480), fontSize: 12)),
                      ],
                    ),
                  )
                : Container(
                    margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF080C18),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF1A2340)),
                    ),
                    child: ListView.builder(
                      controller: _scrollCtrl,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: logs.length,
                      itemBuilder: (_, i) {
                        final entry = logs[i];
                        final color = _levelColor(entry.level);
                        final label = _levelLabel(entry.level);
                        final time = DateFormat('HH:mm:ss.SSS').format(entry.timestamp);
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Time
                              Text(time,
                                  style: const TextStyle(
                                      color: Color(0xFF3A4560), fontSize: 10, fontFamily: 'monospace')),
                              const SizedBox(width: 8),
                              // Level badge
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                decoration: BoxDecoration(
                                  color: color.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(label,
                                    style: TextStyle(
                                        color: color, fontSize: 9, fontWeight: FontWeight.w700,
                                        fontFamily: 'monospace', letterSpacing: 0.5)),
                              ),
                              const SizedBox(width: 8),
                              // Message
                              Expanded(
                                child: Text(
                                  entry.message,
                                  style: TextStyle(color: color.withValues(alpha: 0.9), fontSize: 11, fontFamily: 'monospace'),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ToolbarBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _ToolbarBtn({required this.icon, required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: active ? const Color(0xFF00BFA5).withValues(alpha: 0.15) : const Color(0xFF1A2340),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: active ? const Color(0xFF00BFA5).withValues(alpha: 0.4) : const Color(0xFF2A3450),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: active ? const Color(0xFF00BFA5) : const Color(0xFF8892A4)),
              const SizedBox(width: 5),
              Text(label,
                  style: TextStyle(
                    color: active ? const Color(0xFF00BFA5) : const Color(0xFF8892A4),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  )),
            ],
          ),
        ),
      );
}
