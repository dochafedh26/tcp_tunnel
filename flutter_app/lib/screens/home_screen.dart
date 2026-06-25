import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:provider/provider.dart';
import '../services/settings_service.dart';
import '../services/tunnel_service.dart';
import '../models/tunnel_config.dart';
import '../widgets/tunnel_card.dart';
import '../widgets/add_tunnel_dialog.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  late AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 2))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  Future<void> _switchProfile(TunnelService svc, SettingsService settings, String profileId) async {
    if (svc.isConnected) {
      await svc.disconnect();
    }
    await settings.setSelectedProfileId(profileId);
    
    // Load and set tunnels for this profile
    final all = settings.rawTunnels.map(TunnelConfig.fromJson).toList();
    final filtered = all.where((t) => t.profileId == profileId).toList();
    svc.setTunnels(filtered);
    
    setState(() {});
  }

  Future<void> _toggleConnection(TunnelService svc, SettingsService settings) async {
    if (svc.isConnected) {
      await svc.disconnect();
    } else {
      final p = settings.selectedProfile;
      await svc.connect(p.relayUrl, p.token);
    }
  }

  Future<void> _showAddDialog(TunnelService svc, SettingsService settings, {TunnelConfig? existing}) async {
    final currentProfileId = settings.selectedProfileId;
    final result = await showDialog<TunnelConfig>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      builder: (_) => AddTunnelDialog(existing: existing, defaultProfileId: currentProfileId),
    );
    if (result == null) return;
    if (existing != null) {
      svc.updateTunnel(result);
    } else {
      svc.addTunnel(result);
    }
    // Persist tunnels for this profile
    await settings.saveTunnelsForProfile(currentProfileId, svc.tunnels);
  }

  Future<void> _deleteTunnel(TunnelService svc, SettingsService settings, TunnelConfig config) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A2340),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Remove Tunnel', style: TextStyle(color: Colors.white)),
        content: Text('Remove "${config.name}"?',
            style: const TextStyle(color: Color(0xFF8892A4))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel', style: TextStyle(color: Color(0xFF8892A4)))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove', style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (confirm == true) {
      svc.removeTunnel(config.id);
      await settings.saveTunnelsForProfile(settings.selectedProfileId, svc.tunnels);
    }
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<TunnelService>();
    final settings = context.read<SettingsService>();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          // ── Profile Selector Card ─────────────────────────────────────
          Container(
            margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF0F1629),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF1A2340)),
            ),
            child: Row(
              children: [
                const Icon(Icons.computer_outlined, color: Color(0xFF00BFA5), size: 20),
                const SizedBox(width: 12),
                const Text('Active Machine:', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w500)),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      dropdownColor: const Color(0xFF0F1629),
                      value: settings.selectedProfileId,
                      icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Color(0xFF00BFA5)),
                      items: settings.profiles.map((p) {
                        return DropdownMenuItem<String>(
                          value: p.id,
                          child: Text(p.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                        );
                      }).toList(),
                      onChanged: svc.isConnected
                          ? null // Disable switching if active tunnel is running (forces disconnection)
                          : (val) {
                              if (val != null) {
                                _switchProfile(svc, settings, val);
                              }
                            },
                    ),
                  ),
                ),
              ],
            ),
          ).animate().fadeIn(duration: 350.ms).slideY(begin: -0.05, end: 0),

          // ── Connection header card ────────────────────────────────────
          _ConnectionHeader(
            svc: svc,
            pulseCtrl: _pulseCtrl,
            onToggle: () => _toggleConnection(svc, settings),
          ).animate().fadeIn(duration: 400.ms).slideY(begin: -0.1, end: 0),

          // ── Tunnel list ────────────────────────────────────────────────
          Expanded(
            child: svc.tunnels.isEmpty
                ? _EmptyState(onAdd: () => _showAddDialog(svc, settings))
                : ListView.builder(
                    padding: const EdgeInsets.only(top: 8, bottom: 100),
                    itemCount: svc.tunnels.length,
                    itemBuilder: (_, i) {
                      final config = svc.tunnels[i];
                      return TunnelCard(
                        key: ValueKey(config.id),
                        config: config,
                        connectionState: svc.state,
                        peerConnected: svc.peerConnected,
                        onEdit: () => _showAddDialog(svc, settings, existing: config),
                        onDelete: () => _deleteTunnel(svc, settings, config),
                        onToggle: (v) async {
                          svc.updateTunnel(config.copyWith(enabled: v));
                          await settings.saveTunnelsForProfile(settings.selectedProfileId, svc.tunnels);
                        },
                      ).animate().fadeIn(duration: 300.ms, delay: (i * 60).ms).slideX(begin: 0.05, end: 0);
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddDialog(svc, settings),
        backgroundColor: const Color(0xFF00BFA5),
        foregroundColor: Colors.black,
        icon: const Icon(Icons.add),
        label: const Text('Add Tunnel', style: TextStyle(fontWeight: FontWeight.w700)),
        elevation: 4,
      ),
    );
  }
}

// ── Connection Header ─────────────────────────────────────────────────────────

class _ConnectionHeader extends StatelessWidget {
  final TunnelService svc;
  final AnimationController pulseCtrl;
  final VoidCallback onToggle;

  const _ConnectionHeader({required this.svc, required this.pulseCtrl, required this.onToggle});

  Color get _stateColor {
    switch (svc.state) {
      case TunnelConnectionState.connected:
        return svc.peerConnected ? const Color(0xFF00BFA5) : Colors.orange.shade400;
      case TunnelConnectionState.connecting:
        return Colors.blue.shade300;
      case TunnelConnectionState.error:
        return Colors.redAccent;
      case TunnelConnectionState.disconnected:
        return const Color(0xFF8892A4);
    }
  }

  String get _stateLabel {
    switch (svc.state) {
      case TunnelConnectionState.connected:
        return svc.peerConnected ? 'Tunnel Active' : 'Connected — Waiting for Agent';
      case TunnelConnectionState.connecting:
        return 'Connecting...';
      case TunnelConnectionState.error:
        return 'Error: ${svc.errorMessage ?? "Unknown"}';
      case TunnelConnectionState.disconnected:
        return 'Disconnected';
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / 1048576).toStringAsFixed(1)}MB';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF1A2340).withValues(alpha: 0.95),
            const Color(0xFF0F1629),
          ],
        ),
        border: Border.all(color: _stateColor.withValues(alpha: 0.4), width: 1),
        boxShadow: [
          BoxShadow(color: _stateColor.withValues(alpha: 0.1), blurRadius: 20, offset: const Offset(0, 6)),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              // Pulse orb
              AnimatedBuilder(
                animation: pulseCtrl,
                builder: (_, __) => Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _stateColor.withValues(alpha: 
                        svc.state == TunnelConnectionState.connected ? 0.15 + pulseCtrl.value * 0.1 : 0.1),
                    border: Border.all(
                      color: _stateColor.withValues(alpha: 
                          svc.state == TunnelConnectionState.connected ? 0.6 + pulseCtrl.value * 0.4 : 0.3),
                      width: 1.5,
                    ),
                    boxShadow: svc.isConnected
                        ? [BoxShadow(color: _stateColor.withValues(alpha: 0.3 * pulseCtrl.value), blurRadius: 16)]
                        : null,
                  ),
                  child: Icon(
                    svc.isConnected ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
                    color: _stateColor,
                    size: 22,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_stateLabel,
                        style: TextStyle(
                          color: _stateColor,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        )),
                    const SizedBox(height: 2),
                    Text(
                      '${svc.tunnels.where((t) => t.enabled).length} tunnel(s) configured  •  ${svc.activeChannels} active',
                      style: const TextStyle(color: Color(0xFF8892A4), fontSize: 12),
                    ),
                  ],
                ),
              ),
              // Connect/Disconnect button
              _ConnectButton(
                state: svc.state,
                onPressed: onToggle,
                color: _stateColor,
              ),
            ],
          ),

          if (svc.isConnected) ...[
            const SizedBox(height: 16),
            const Divider(color: Color(0xFF2A3450), height: 1),
            const SizedBox(height: 12),
            // Traffic stats
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _StatChip(icon: Icons.arrow_downward, label: 'IN', value: _formatBytes(svc.bytesIn), color: const Color(0xFF00BFA5)),
                _StatChip(icon: Icons.arrow_upward, label: 'OUT', value: _formatBytes(svc.bytesOut), color: const Color(0xFF448AFF)),
                _StatChip(icon: Icons.swap_horiz, label: 'CHANNELS', value: '${svc.activeChannels}', color: Colors.purple.shade300),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ConnectButton extends StatelessWidget {
  final TunnelConnectionState state;
  final VoidCallback onPressed;
  final Color color;
  const _ConnectButton({required this.state, required this.onPressed, required this.color});

  @override
  Widget build(BuildContext context) {
    final isConnecting = state == TunnelConnectionState.connecting;
    final isConnected = state == TunnelConnectionState.connected;
    return ElevatedButton(
      onPressed: isConnecting ? null : onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: isConnected ? Colors.redAccent.withValues(alpha: 0.15) : color.withValues(alpha: 0.15),
        foregroundColor: isConnected ? Colors.redAccent : color,
        side: BorderSide(color: isConnected ? Colors.redAccent.withValues(alpha: 0.4) : color.withValues(alpha: 0.4)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        elevation: 0,
      ),
      child: isConnecting
          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
          : Text(
              isConnected ? 'Disconnect' : 'Connect',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  const _StatChip({required this.icon, required this.label, required this.value, required this.color});
  @override
  Widget build(BuildContext context) => Column(
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 12, color: color),
              const SizedBox(width: 4),
              Text(label, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 0.5)),
            ],
          ),
          const SizedBox(height: 2),
          Text(value, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
        ],
      );
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onAdd;
  const _EmptyState({required this.onAdd});
  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.alt_route_rounded, size: 64, color: const Color(0xFF00BFA5).withValues(alpha: 0.3)),
            const SizedBox(height: 16),
            const Text('No tunnels yet', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            const Text('Add a tunnel to forward a local port\nto a resource on your work network',
                textAlign: TextAlign.center, style: TextStyle(color: Color(0xFF8892A4), fontSize: 13, height: 1.5)),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Add First Tunnel'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00BFA5),
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              ),
            ),
          ],
        ),
      );
}
