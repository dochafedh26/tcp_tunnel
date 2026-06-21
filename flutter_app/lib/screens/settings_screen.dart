import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:provider/provider.dart';
import '../services/settings_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _urlCtrl;
  late TextEditingController _tokenCtrl;
  bool _tokenObscured = true;
  bool _autoReconnect = true;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    final s = context.read<SettingsService>();
    _urlCtrl = TextEditingController(text: s.relayUrl);
    _tokenCtrl = TextEditingController(text: s.token);
    _autoReconnect = s.autoReconnect;
    _urlCtrl.addListener(_onChanged);
    _tokenCtrl.addListener(_onChanged);
  }

  void _onChanged() => setState(() => _dirty = true);

  @override
  void dispose() {
    _urlCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final s = context.read<SettingsService>();
    await s.setRelayUrl(_urlCtrl.text.trim());
    await s.setToken(_tokenCtrl.text.trim());
    await s.setAutoReconnect(_autoReconnect);
    setState(() => _dirty = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Settings saved'),
          backgroundColor: const Color(0xFF00BFA5),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Relay connection ────────────────────────────────────────────
          _Section(
            title: 'Relay Server',
            icon: Icons.cloud_outlined,
            children: [
              _SettingsField(
                controller: _urlCtrl,
                label: 'Relay URL',
                hint: 'ws://your-relay.railway.app or wss://...',
                icon: Icons.link,
                helperText: 'Use wss:// for production (Railway auto-provides HTTPS)',
              ),
              const SizedBox(height: 12),
              _SettingsField(
                controller: _tokenCtrl,
                label: 'Auth Token',
                hint: 'your-secret-token',
                icon: Icons.vpn_key_outlined,
                obscureText: _tokenObscured,
                suffix: IconButton(
                  icon: Icon(_tokenObscured ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                      size: 18, color: const Color(0xFF8892A4)),
                  onPressed: () => setState(() => _tokenObscured = !_tokenObscured),
                ),
                helperText: 'Must match AUTH_TOKEN on the relay server and agent',
              ),
            ],
          ).animate().fadeIn(duration: 400.ms).slideY(begin: 0.05, end: 0),

          const SizedBox(height: 16),

          // ── Behaviour ────────────────────────────────────────────────────
          _Section(
            title: 'Behaviour',
            icon: Icons.tune_rounded,
            children: [
              _SwitchTile(
                label: 'Auto-reconnect',
                subtitle: 'Automatically reconnect on connection loss',
                value: _autoReconnect,
                onChanged: (v) => setState(() { _autoReconnect = v; _dirty = true; }),
              ),
            ],
          ).animate().fadeIn(duration: 400.ms, delay: 80.ms).slideY(begin: 0.05, end: 0),

          const SizedBox(height: 16),

          // ── Quick reference ──────────────────────────────────────────────
          const _Section(
            title: 'Quick Reference',
            icon: Icons.info_outline_rounded,
            children: [
              _InfoRow(label: 'Start relay', value: 'node src/server.js'),
              _InfoRow(label: 'Start agent', value: 'dart run bin/agent.dart --relay <url> --token <token>'),
              _InfoRow(label: 'Compile agent', value: 'dart compile exe bin/agent.dart -o agent.exe'),
            ],
          ),

          const SizedBox(height: 24),

          // ── Save button ──────────────────────────────────────────────────
          AnimatedOpacity(
            opacity: _dirty ? 1.0 : 0.4,
            duration: const Duration(milliseconds: 200),
            child: ElevatedButton.icon(
              onPressed: _dirty ? _save : null,
              icon: const Icon(Icons.save_outlined),
              label: const Text('Save Settings', style: TextStyle(fontWeight: FontWeight.w700)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00BFA5),
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(vertical: 14),
                minimumSize: const Size(double.infinity, 50),
                elevation: 0,
              ),
            ),
          ),

          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

// ── Reusable section container ────────────────────────────────────────────────

class _Section extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Widget> children;
  const _Section({required this.title, required this.icon, required this.children});

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: const Color(0xFF1A2340).withValues(alpha: 0.9),
          border: Border.all(color: const Color(0xFF2A3450), width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: Row(
                children: [
                  Icon(icon, size: 16, color: const Color(0xFF00BFA5)),
                  const SizedBox(width: 8),
                  Text(title,
                      style: const TextStyle(
                          color: Color(0xFF00BFA5), fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.8)),
                ],
              ),
            ),
            const Divider(color: Color(0xFF2A3450), height: 1),
            Padding(padding: const EdgeInsets.all(16), child: Column(children: children)),
          ],
        ),
      );
}

class _SettingsField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final IconData icon;
  final bool obscureText;
  final Widget? suffix;
  final String? helperText;

  const _SettingsField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.icon,
    this.obscureText = false,
    this.suffix,
    this.helperText,
  });

  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        obscureText: obscureText,
        style: const TextStyle(color: Colors.white, fontSize: 13),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          helperText: helperText,
          helperStyle: const TextStyle(color: Color(0xFF5A6480), fontSize: 11),
          helperMaxLines: 2,
          prefixIcon: Icon(icon, size: 17, color: const Color(0xFF00BFA5)),
          suffixIcon: suffix,
          labelStyle: const TextStyle(color: Color(0xFF8892A4), fontSize: 13),
          hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.2), fontSize: 12),
          filled: true,
          fillColor: const Color(0xFF0A0E1A),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFF2A3450))),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFF2A3450))),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFF00BFA5), width: 1.5)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
      );
}

class _SwitchTile extends StatelessWidget {
  final String label;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _SwitchTile({required this.label, required this.subtitle, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500)),
              const SizedBox(height: 2),
              Text(subtitle, style: const TextStyle(color: Color(0xFF8892A4), fontSize: 12)),
            ]),
          ),
          Switch(value: value, onChanged: onChanged, activeThumbColor: const Color(0xFF00BFA5)),
        ],
      );
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(color: Color(0xFF8892A4), fontSize: 11, letterSpacing: 0.4)),
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xFF0A0E1A),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF2A3450)),
              ),
              child: Text(value,
                  style: const TextStyle(
                      color: Color(0xFF00E5FF), fontSize: 11, fontFamily: 'monospace', letterSpacing: 0.3)),
            ),
          ],
        ),
      );
}
