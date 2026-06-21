import 'package:flutter/material.dart';
import '../../models/tunnel_config.dart';
import '../../services/tunnel_service.dart';

/// Glassmorphism card representing a single tunnel rule with live status.
class TunnelCard extends StatelessWidget {
  final TunnelConfig config;
  final TunnelConnectionState connectionState;
  final bool peerConnected;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<bool> onToggle;

  const TunnelCard({
    super.key,
    required this.config,
    required this.connectionState,
    required this.peerConnected,
    required this.onEdit,
    required this.onDelete,
    required this.onToggle,
  });

  Color _statusColor(BuildContext context) {
    if (!config.enabled) return Colors.grey.shade600;
    if (connectionState == TunnelConnectionState.connected && peerConnected) {
      return const Color(0xFF00BFA5);
    }
    if (connectionState == TunnelConnectionState.connected) {
      return Colors.orange.shade400;
    }
    return Colors.grey.shade600;
  }

  String _statusLabel() {
    if (!config.enabled) return 'Disabled';
    if (connectionState == TunnelConnectionState.connected && peerConnected) return 'Active';
    if (connectionState == TunnelConnectionState.connected) return 'Waiting for agent';
    if (connectionState == TunnelConnectionState.connecting) return 'Connecting...';
    return 'Inactive';
  }

  @override
  Widget build(BuildContext context) {
    final statusColor = _statusColor(context);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF1A2340).withValues(alpha: 0.9),
            const Color(0xFF0F1629).withValues(alpha: 0.95),
          ],
        ),
        border: Border.all(
          color: statusColor.withValues(alpha: config.enabled ? 0.35 : 0.12),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: statusColor.withValues(alpha: config.enabled ? 0.08 : 0.03),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onEdit,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                // ── Status indicator dot ──────────────────────────────────
                _StatusDot(color: statusColor, active: config.enabled &&
                    connectionState == TunnelConnectionState.connected && peerConnected),
                const SizedBox(width: 14),

                // ── Tunnel info ───────────────────────────────────────────
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        config.name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.2,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          _PortChip(label: 'localhost:${config.localPort}', color: const Color(0xFF00BFA5)),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 6),
                            child: Icon(Icons.arrow_forward, size: 12, color: Color(0xFF8892A4)),
                          ),
                          _PortChip(label: '${config.remoteHost}:${config.remotePort}', color: const Color(0xFF448AFF)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _statusLabel(),
                        style: TextStyle(
                          color: statusColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  ),
                ),

                // ── Actions ───────────────────────────────────────────────
                Column(
                  children: [
                    Switch(
                      value: config.enabled,
                      onChanged: onToggle,
                      activeThumbColor: const Color(0xFF00BFA5),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _IconBtn(icon: Icons.edit_outlined, onTap: onEdit, color: const Color(0xFF8892A4)),
                        _IconBtn(icon: Icons.delete_outline, onTap: onDelete, color: Colors.redAccent.shade200),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusDot extends StatefulWidget {
  final Color color;
  final bool active;
  const _StatusDot({required this.color, required this.active});
  @override
  State<_StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<_StatusDot> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(seconds: 2))
      ..repeat(reverse: true);
    _pulse = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 12,
      height: 12,
      child: widget.active
          ? AnimatedBuilder(
              animation: _pulse,
              builder: (_, __) => Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color.withValues(alpha: _pulse.value),
                  boxShadow: [BoxShadow(color: widget.color.withValues(alpha: 0.5), blurRadius: 6)],
                ),
              ),
            )
          : Container(
              decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color),
            ),
    );
  }
}

class _PortChip extends StatelessWidget {
  final String label;
  final Color color;
  const _PortChip({required this.label, required this.color});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.3), width: 0.5),
        ),
        child: Text(label, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w600)),
      );
}

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color color;
  const _IconBtn({required this.icon, required this.onTap, required this.color});
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 16, color: color),
        ),
      );
}
