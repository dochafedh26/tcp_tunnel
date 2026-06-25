import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import '../../models/tunnel_config.dart';

/// Dialog to add or edit a tunnel forwarding rule.
class AddTunnelDialog extends StatefulWidget {
  final TunnelConfig? existing;
  final String defaultProfileId;

  const AddTunnelDialog({super.key, this.existing, required this.defaultProfileId});

  @override
  State<AddTunnelDialog> createState() => _AddTunnelDialogState();
}

class _AddTunnelDialogState extends State<AddTunnelDialog> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameCtrl;
  late TextEditingController _localPortCtrl;
  late TextEditingController _remoteHostCtrl;
  late TextEditingController _remotePortCtrl;
  bool _enabled = true;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _nameCtrl = TextEditingController(text: e?.name ?? '');
    _localPortCtrl = TextEditingController(text: e?.localPort.toString() ?? '');
    _remoteHostCtrl = TextEditingController(text: e?.remoteHost ?? '');
    _remotePortCtrl = TextEditingController(text: e?.remotePort.toString() ?? '');
    _enabled = e?.enabled ?? true;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _localPortCtrl.dispose();
    _remoteHostCtrl.dispose();
    _remotePortCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final config = TunnelConfig(
      id: widget.existing?.id ?? const Uuid().v4(),
      profileId: widget.existing?.profileId ?? widget.defaultProfileId,
      name: _nameCtrl.text.trim(),
      localPort: int.parse(_localPortCtrl.text.trim()),
      remoteHost: _remoteHostCtrl.text.trim(),
      remotePort: int.parse(_remotePortCtrl.text.trim()),
      enabled: _enabled,
    );
    Navigator.of(context).pop(config);
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 420,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1A2340), Color(0xFF0F1629)],
          ),
          border: Border.all(color: const Color(0xFF00BFA5).withValues(alpha: 0.3), width: 1),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 30, offset: const Offset(0, 10)),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Header ──────────────────────────────────────────────
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF00BFA5).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.alt_route_rounded, color: Color(0xFF00BFA5), size: 20),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      isEdit ? 'Edit Tunnel' : 'Add Tunnel',
                      style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                // ── Name ─────────────────────────────────────────────────
                _Field(
                  controller: _nameCtrl,
                  label: 'Tunnel Name',
                  hint: 'e.g. RDP Work PC',
                  icon: Icons.label_outline,
                  validator: (v) => (v?.trim().isEmpty ?? true) ? 'Name required' : null,
                ),
                const SizedBox(height: 16),

                // ── Local port ───────────────────────────────────────────
                _Field(
                  controller: _localPortCtrl,
                  label: 'Local Port',
                  hint: 'e.g. 13389',
                  icon: Icons.laptop_outlined,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  validator: (v) {
                    final n = int.tryParse(v ?? '');
                    if (n == null || n < 1 || n > 65535) return 'Enter a valid port (1–65535)';
                    return null;
                  },
                ),
                const SizedBox(height: 16),

                // ── Remote host + port ───────────────────────────────────
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: _Field(
                        controller: _remoteHostCtrl,
                        label: 'Remote Host',
                        hint: 'e.g. 192.168.1.10',
                        icon: Icons.dns_outlined,
                        validator: (v) => (v?.trim().isEmpty ?? true) ? 'Host required' : null,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: _Field(
                        controller: _remotePortCtrl,
                        label: 'Remote Port',
                        hint: '3389',
                        icon: Icons.settings_ethernet,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        validator: (v) {
                          final n = int.tryParse(v ?? '');
                          if (n == null || n < 1 || n > 65535) return 'Invalid';
                          return null;
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // ── Enable toggle ────────────────────────────────────────
                Row(
                  children: [
                    const Text('Enable tunnel', style: TextStyle(color: Color(0xFF8892A4), fontSize: 14)),
                    const Spacer(),
                    Switch(
                      value: _enabled,
                      onChanged: (v) => setState(() => _enabled = v),
                      activeThumbColor: const Color(0xFF00BFA5),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                // ── Buttons ──────────────────────────────────────────────
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF8892A4),
                          side: const BorderSide(color: Color(0xFF2A3450)),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _submit,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00BFA5),
                          foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          elevation: 0,
                        ),
                        child: Text(isEdit ? 'Save Changes' : 'Add Tunnel',
                            style: const TextStyle(fontWeight: FontWeight.w700)),
                      ),
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

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final IconData icon;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final FormFieldValidator<String>? validator;

  const _Field({
    required this.controller,
    required this.label,
    required this.hint,
    required this.icon,
    this.keyboardType,
    this.inputFormatters,
    this.validator,
  });

  @override
  Widget build(BuildContext context) => TextFormField(
        controller: controller,
        keyboardType: keyboardType,
        inputFormatters: inputFormatters,
        validator: validator,
        style: const TextStyle(color: Colors.white, fontSize: 14),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          prefixIcon: Icon(icon, size: 18, color: const Color(0xFF00BFA5)),
          labelStyle: const TextStyle(color: Color(0xFF8892A4), fontSize: 13),
          hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.2), fontSize: 13),
          filled: true,
          fillColor: const Color(0xFF0A0E1A),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFF2A3450)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFF2A3450)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFF00BFA5), width: 1.5),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Colors.redAccent),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
      );
}
