import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../services/settings_service.dart';
import '../models/machine_profile.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _autoReconnect = true;

  @override
  void initState() {
    super.initState();
    final s = context.read<SettingsService>();
    _autoReconnect = s.autoReconnect;
  }

  void _showProfileDialog({MachineProfile? existing}) {
    final isEdit = existing != null;
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final urlCtrl = TextEditingController(text: existing?.relayUrl ?? '');
    final tokenCtrl = TextEditingController(text: existing?.token ?? '');
    bool tokenObscured = true;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF0F1629),
          title: Text(isEdit ? 'Edit Machine Profile' : 'Add Machine Profile', style: const TextStyle(color: Colors.white)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Machine Name',
                    labelStyle: TextStyle(color: Color(0xFF8892A4)),
                    enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF1A2340))),
                    focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF00BFA5))),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: urlCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Relay URL',
                    labelStyle: TextStyle(color: Color(0xFF8892A4)),
                    hintText: 'wss://...',
                    hintStyle: TextStyle(color: Color(0xFF4A5568)),
                    enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF1A2340))),
                    focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF00BFA5))),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: tokenCtrl,
                  obscureText: tokenObscured,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Auth Token',
                    labelStyle: const TextStyle(color: Color(0xFF8892A4)),
                    enabledBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF1A2340))),
                    focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF00BFA5))),
                    suffixIcon: IconButton(
                      icon: Icon(
                        tokenObscured ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                        size: 18,
                        color: const Color(0xFF8892A4),
                      ),
                      onPressed: () => setDialogState(() => tokenObscured = !tokenObscured),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel', style: TextStyle(color: Color(0xFF8892A4))),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00BFA5)),
              onPressed: () async {
                final name = nameCtrl.text.trim();
                final url = urlCtrl.text.trim();
                final token = tokenCtrl.text.trim();

                if (name.isNotEmpty && url.isNotEmpty && token.isNotEmpty) {
                  Navigator.pop(ctx);
                  final settings = context.read<SettingsService>();
                  final list = List<MachineProfile>.from(settings.profiles);

                  if (isEdit) {
                    final idx = list.indexWhere((p) => p.id == existing.id);
                    if (idx != -1) {
                      list[idx] = existing.copyWith(name: name, relayUrl: url, token: token);
                    }
                  } else {
                    final newProfile = MachineProfile(
                      id: const Uuid().v4(),
                      name: name,
                      relayUrl: url,
                      token: token,
                    );
                    list.add(newProfile);
                  }

                  await settings.saveProfiles(list);
                  _showSnackBar('Profile saved');
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteProfile(MachineProfile profile) async {
    final settings = context.read<SettingsService>();
    if (settings.profiles.length <= 1) {
      _showSnackBar('Cannot delete the only remaining profile.');
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F1629),
        title: const Text('Delete Profile', style: TextStyle(color: Colors.white)),
        content: Text('Are you sure you want to delete "${profile.name}"?', style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Color(0xFF8892A4))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      final list = List<MachineProfile>.from(settings.profiles);
      list.removeWhere((p) => p.id == profile.id);
      await settings.saveProfiles(list);

      // If we deleted the active profile, reset selectedProfileId to the first one
      if (settings.selectedProfileId == profile.id) {
        await settings.setSelectedProfileId(list.first.id);
      }
      _showSnackBar('Profile deleted');
    }
  }

  void _showSnackBar(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: const Color(0xFF00BFA5),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Machine Profiles Section ─────────────────────────────────────
          _Section(
            title: 'Machine Profiles',
            icon: Icons.computer_outlined,
            children: [
              ...settings.profiles.map((profile) {
                final isActive = settings.selectedProfileId == profile.id;
                return Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A0E1A),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isActive ? const Color(0xFF00BFA5).withValues(alpha: 0.5) : const Color(0xFF2A3450),
                      width: isActive ? 1.5 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.circle,
                        size: 10,
                        color: isActive ? const Color(0xFF00BFA5) : const Color(0xFF4A5568),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              profile.name,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              profile.relayUrl,
                              style: const TextStyle(color: Color(0xFF8892A4), fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 18, color: Color(0xFF00BFA5)),
                        onPressed: () => _showProfileDialog(existing: profile),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
                        onPressed: () => _deleteProfile(profile),
                      ),
                    ],
                  ),
                );
              }),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => _showProfileDialog(),
                icon: const Icon(Icons.add),
                label: const Text('Add Machine Profile'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF00BFA5),
                  side: const BorderSide(color: Color(0xFF00BFA5)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  minimumSize: const Size(double.infinity, 44),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
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
                onChanged: (v) async {
                  setState(() => _autoReconnect = v);
                  await settings.setAutoReconnect(v);
                },
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
