import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../services/settings_service.dart';
import '../services/updater_service.dart';
import '../models/machine_profile.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _autoReconnect = true;

  Future<void> _discoverAgents() async {
    final settings = context.read<SettingsService>();
    final currentProfile = settings.selectedProfile;
    final relayUrlCtrl = TextEditingController(text: currentProfile.relayUrl);

    bool isLoading = false;
    List<Map<String, dynamic>> agents = [];
    String? errorMessage;
    bool hasQueried = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {

          Future<void> performQuery() async {
            setDialogState(() {
              isLoading = true;
              errorMessage = null;
              hasQueried = true;
            });

            try {
              var url = relayUrlCtrl.text.trim();
              if (url.isEmpty) {
                throw Exception('Relay URL is empty');
              }
              // Translate ws/wss to http/https
              if (url.startsWith('wss://')) {
                url = url.replaceFirst('wss://', 'https://');
              } else if (url.startsWith('ws://')) {
                url = url.replaceFirst('ws://', 'http://');
              } else {
                url = 'https://$url';
              }
              if (url.endsWith('/')) {
                url = url.substring(0, url.length - 1);
              }
              final targetUrl = '$url/health';

              final response = await http.get(Uri.parse(targetUrl)).timeout(const Duration(seconds: 8));
              if (response.statusCode == 200) {
                final data = jsonDecode(response.body) as Map<String, dynamic>;
                final sessions = data['sessions'] as List<dynamic>? ?? [];
                
                final foundAgents = sessions.map((s) => s as Map<String, dynamic>).toList();

                setDialogState(() {
                  agents = foundAgents;
                  isLoading = false;
                });
              } else {
                throw Exception('HTTP Status ${response.statusCode}');
              }
            } catch (e) {
              setDialogState(() {
                errorMessage = e.toString().replaceAll('Exception: ', '');
                isLoading = false;
              });
            }
          }

          Future<void> selectAgent(Map<String, dynamic> agent) async {
            final agentName = agent['agentName'] as String? ?? 'Unknown Agent';
            final tokenCtrl = TextEditingController();
            bool tokenObscured = true;

            final pairSuccess = await showDialog<bool>(
              context: ctx,
              builder: (pCtx) => StatefulBuilder(
                builder: (context, setPairState) => AlertDialog(
                  backgroundColor: const Color(0xFF0F1629),
                  title: Text('Pair with $agentName', style: const TextStyle(color: Colors.white)),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Please enter the Auth Token shown in the agent terminal on your work machine.',
                        style: TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: tokenCtrl,
                        obscureText: tokenObscured,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: 'Auth Token (UUID)',
                          labelStyle: const TextStyle(color: Color(0xFF8892A4)),
                          enabledBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF1A2340))),
                          focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF00BFA5))),
                          suffixIcon: IconButton(
                            icon: Icon(
                              tokenObscured ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                              size: 18,
                              color: const Color(0xFF8892A4),
                            ),
                            onPressed: () => setPairState(() => tokenObscured = !tokenObscured),
                          ),
                        ),
                      ),
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(pCtx, false),
                      child: const Text('Cancel', style: TextStyle(color: Color(0xFF8892A4))),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00BFA5)),
                      onPressed: () {
                        final tokenVal = tokenCtrl.text.trim();
                        if (tokenVal.isNotEmpty) {
                          Navigator.pop(pCtx, true);
                        }
                      },
                      child: const Text('Pair & Connect'),
                    ),
                  ],
                ),
              ),
            );

            if (pairSuccess == true) {
              final tokenVal = tokenCtrl.text.trim();
              final settings = context.read<SettingsService>();
              final list = List<MachineProfile>.from(settings.profiles);

              final newProfile = MachineProfile(
                id: const Uuid().v4(),
                name: agentName,
                relayUrl: relayUrlCtrl.text.trim(),
                token: tokenVal,
              );
              list.add(newProfile);
              await settings.saveProfiles(list);
              await settings.setSelectedProfileId(newProfile.id);

              Navigator.pop(ctx); // Close discovery dialog
              _showSnackBar('Paired and selected profile: $agentName');
            }
          }

          return AlertDialog(
            backgroundColor: const Color(0xFF0F1629),
            title: const Text('Discover Agents', style: TextStyle(color: Colors.white)),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: relayUrlCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Relay Server URL',
                      labelStyle: const TextStyle(color: Color(0xFF8892A4)),
                      hintText: 'wss://...',
                      hintStyle: const TextStyle(color: Color(0xFF4A5568)),
                      enabledBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF1A2340))),
                      focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF00BFA5))),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.search, color: Color(0xFF00BFA5)),
                        onPressed: performQuery,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (isLoading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: CircularProgressIndicator(color: Color(0xFF00BFA5)),
                    )
                  else if (errorMessage != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        'Error: $errorMessage',
                        style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                        textAlign: TextAlign.center,
                      ),
                    )
                  else if (hasQueried && agents.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        'No agents currently connected to this relay.',
                        style: TextStyle(color: Colors.white70, fontSize: 13),
                        textAlign: TextAlign.center,
                      ),
                    )
                  else if (agents.isNotEmpty)
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: agents.length,
                        itemBuilder: (context, index) {
                          final a = agents[index];
                          final name = a['agentName'] as String? ?? 'Unknown';
                          final hasClient = a['hasClient'] as bool? ?? false;
                          final hasAgent = a['hasAgent'] as bool? ?? false;

                          if (!hasAgent) return const SizedBox.shrink();

                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF0A0E1A),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: const Color(0xFF2A3450)),
                            ),
                            child: ListTile(
                              leading: const Icon(Icons.computer, color: Color(0xFF00E5FF)),
                              title: Text(name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                              subtitle: Text(
                                hasClient ? 'In Use (Tunnel Busy)' : 'Available (Waiting for connection)',
                                style: TextStyle(
                                  color: hasClient ? Colors.orangeAccent : const Color(0xFF00BFA5),
                                  fontSize: 11,
                                ),
                              ),
                              trailing: const Icon(Icons.chevron_right, color: Color(0xFF8892A4), size: 18),
                              onTap: () => selectAgent(a),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close', style: TextStyle(color: Color(0xFF8892A4))),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    final s = context.read<SettingsService>();
    _autoReconnect = s.autoReconnect;
  }

  void _showProfileDialog({MachineProfile? existing}) {
    final isEdit = existing != null;
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final urlCtrl = TextEditingController(text: existing?.relayUrl ?? (isEdit ? '' : SettingsService.defaultRelayUrl));
    final tokenCtrl = TextEditingController(text: existing?.token ?? const Uuid().v4());
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
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(
                            Icons.refresh_rounded,
                            size: 18,
                            color: Color(0xFF00BFA5),
                          ),
                          tooltip: 'Generate Random Token',
                          onPressed: () => setDialogState(() {
                            tokenCtrl.text = const Uuid().v4();
                          }),
                        ),
                        IconButton(
                          icon: Icon(
                            tokenObscured ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                            size: 18,
                            color: const Color(0xFF8892A4),
                          ),
                          onPressed: () => setDialogState(() => tokenObscured = !tokenObscured),
                        ),
                      ],
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
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _showProfileDialog(),
                      icon: const Icon(Icons.add),
                      label: const Text('Add Profile'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF00BFA5),
                        side: const BorderSide(color: Color(0xFF00BFA5)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _discoverAgents,
                      icon: const Icon(Icons.sensors, size: 18, color: Colors.white),
                      label: const Text('Discover', style: TextStyle(color: Colors.white)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00BFA5),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                ],
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
          _Section(
            title: 'Quick Reference',
            icon: Icons.info_outline_rounded,
            children: [
              const _InfoRow(label: 'Start relay server locally', value: 'node src/server.js'),
              _InfoRow(
                label: 'Start agent on work machine',
                value: 'dart run bin/agent.dart --relay ${settings.selectedProfile.relayUrl} --token ${settings.selectedProfile.token}',
              ),
              const _InfoRow(label: 'Compile agent to executable', value: 'dart compile exe bin/agent.dart -o agent.exe'),
            ],
          ),

          const SizedBox(height: 16),
          Center(
            child: Text(
              'TCP Tunnel App v${UpdaterService.currentVersion}',
              style: const TextStyle(color: Color(0xFF8892A4), fontSize: 11),
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
