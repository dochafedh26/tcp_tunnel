import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';
import '../services/tunnel_service.dart';
import '../services/settings_service.dart';
import '../models/tunnel_config.dart';

class DevicesScreen extends StatefulWidget {
  final Function(int)? onTabChange;

  const DevicesScreen({super.key, this.onTabChange});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _loading = false;
  String? _error;
  List<Map<String, dynamic>> _usbDevices = [];
  List<Map<String, dynamic>> _printers = [];
  List<Map<String, dynamic>> _comPorts = [];
  final Set<String> _sharedDrives = {};
  List<Map<String, String>> _localAttachedDevices = [];
  bool _localUsbipInstalled = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkLocalUsbip();
      _refreshDevices();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _checkLocalUsbip() async {
    final service = context.read<TunnelService>();
    final installed = await service.isLocalUsbipInstalled();
    if (mounted) {
      setState(() {
        _localUsbipInstalled = installed;
      });
    }
  }

  Future<void> _refreshDevices() async {
    final service = context.read<TunnelService>();
    if (!service.isConnected || !service.peerConnected) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await _checkLocalUsbip();
      final data = await service.fetchRemoteDevices();
      final localAttached = await service.getLocalAttachedUsbDevices();
      setState(() {
        _usbDevices = List<Map<String, dynamic>>.from(data['usbDevices'] ?? []);
        _printers = List<Map<String, dynamic>>.from(data['printers'] ?? []);
        _comPorts = List<Map<String, dynamic>>.from(data['comPorts'] ?? []);
        _localAttachedDevices = localAttached;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString().replaceAll('Exception: ', '');
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<TunnelService>();

    if (!service.isConnected || !service.peerConnected) {
      return Scaffold(
        backgroundColor: const Color(0xFF0A0E1A),
        body: Center(
          child: Container(
            margin: const EdgeInsets.all(24),
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: const Color(0xFF0F1629),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF1A2340)),
            ),
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.cloud_off_outlined, color: Colors.orangeAccent, size: 48),
                SizedBox(height: 16),
                Text('Work Agent Offline',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                SizedBox(height: 8),
                Text(
                  'To manage remote USB & printers, connect to the relay server and ensure the work agent is online.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFF8892A4), height: 1.4),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(48),
        child: Container(
          color: const Color(0xFF0D1120),
          child: TabBar(
            controller: _tabController,
            indicatorColor: const Color(0xFF00BFA5),
            labelColor: const Color(0xFF00BFA5),
            unselectedLabelColor: const Color(0xFF8892A4),
            tabs: const [
              Tab(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.usb_rounded, size: 18),
                    SizedBox(width: 6),
                    Text('USB'),
                  ],
                ),
              ),
              Tab(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.print_rounded, size: 18),
                    SizedBox(width: 6),
                    Text('Printers'),
                  ],
                ),
              ),
              Tab(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.cable_rounded, size: 18),
                    SizedBox(width: 6),
                    Text('COM Ports'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.small(
        backgroundColor: const Color(0xFF00BFA5),
        onPressed: _refreshDevices,
        tooltip: 'Refresh devices',
        child: const Icon(Icons.refresh_rounded, color: Colors.white),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF00BFA5)))
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 48),
                        const SizedBox(height: 16),
                        Text(_error!, style: const TextStyle(color: Colors.white70), textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00BFA5)),
                          onPressed: _refreshDevices,
                          child: const Text('Retry'),
                        )
                      ],
                    ),
                  ),
                )
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _buildUsbTab(service),
                    _buildPrintersTab(service),
                    _buildComPortsTab(),
                  ],
                ),
    );
  }

  Widget _buildUsbTab(TunnelService service) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ── USBIP missing banners ──────────────────────────────
        ..._buildUsbipBanners(service),
        if (_usbDevices.isEmpty) ...[
          const SizedBox(height: 48),
          const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.usb_off_rounded, color: Color(0xFF8892A4), size: 48),
                SizedBox(height: 12),
                Text('No USB devices connected on the remote machine.',
                    style: TextStyle(color: Color(0xFF8892A4))),
              ],
            ),
          ),
        ] else ...[
          ...List.generate(_usbDevices.length, (index) {
            final device = _usbDevices[index];
        final isStorage = device['class'] == 'Storage';
        final isUsbip = device['class'] == 'USBIP';
        final driveLetter = device['driveLetter'] as String?;
        final isShared = driveLetter != null && _sharedDrives.contains(driveLetter);

        // Check if attached locally
        final busId = device['busId'] as String?;
        final localAttach = _localAttachedDevices.firstWhere(
          (d) => d['busId'] == busId,
          orElse: () => {},
        );
        final isAttachedLocally = localAttach.isNotEmpty;
        final localPort = localAttach['port'];

        return Card(
          color: const Color(0xFF0F1629),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: isAttachedLocally
                  ? Colors.blue.withValues(alpha: 0.5)
                  : (isShared ? const Color(0xFF00BFA5).withValues(alpha: 0.5) : const Color(0xFF1A2340)),
            ),
          ),
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: isStorage
                          ? Colors.blue.withValues(alpha: 0.15)
                          : (isUsbip ? Colors.orange.withValues(alpha: 0.15) : const Color(0xFF00BFA5).withValues(alpha: 0.15)),
                      child: Icon(
                        isStorage
                            ? Icons.folder_open_rounded
                            : (isUsbip ? Icons.cable_rounded : Icons.usb_rounded),
                        color: isStorage ? Colors.blue : (isUsbip ? Colors.orange : const Color(0xFF00BFA5)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  device['name'] ?? 'Unknown USB Device',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold, fontSize: 15, color: Colors.white),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (isShared)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF00BFA5).withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.share_rounded, size: 10, color: Color(0xFF00BFA5)),
                                      SizedBox(width: 3),
                                      Text('Shared', style: TextStyle(color: Color(0xFF00BFA5), fontSize: 10, fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                ),
                              if (isAttachedLocally)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.blue.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.check_circle_rounded, size: 10, color: Colors.blue),
                                      SizedBox(width: 3),
                                      Text('Attached Locally', style: TextStyle(color: Colors.blue, fontSize: 10, fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          if (isStorage && (device['size'] as int? ?? 0) > 0)
                            Text(
                              _formatStorageSubtitle(device),
                              style: const TextStyle(color: Color(0xFF8892A4), fontSize: 12),
                            )
                          else if (isUsbip)
                            Text(
                              'BUSID: ${device['busId'] ?? 'N/A'} · VID:PID: ${device['vidPid'] ?? 'N/A'} · Status: ${device['status'] ?? 'Not Shared'}',
                              style: const TextStyle(color: Color(0xFF8892A4), fontSize: 12),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            )
                          else
                            Text(
                              'ID: ${device['id'] ?? 'N/A'}',
                              style: const TextStyle(color: Color(0xFF8892A4), fontSize: 12),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (isStorage && (device['size'] as int? ?? 0) > 0) ...[
                  const SizedBox(height: 10),
                  _buildCapacityBar(device),
                ],
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (isStorage && driveLetter != null) ...[
                      _actionButton(
                        icon: Icons.arrow_forward_rounded,
                        label: 'Browse',
                        color: const Color(0xFF00BFA5),
                        onPressed: () {
                          service.requestedBrowsePath = driveLetter;
                          widget.onTabChange?.call(1);
                        },
                      ),
                      const SizedBox(width: 8),
                      _actionButton(
                        icon: isShared ? Icons.link_off_rounded : Icons.share_rounded,
                        label: isShared ? 'Unshare' : 'Share',
                        color: isShared ? Colors.orange : const Color(0xFF3B82F6),
                        onPressed: () => isShared
                            ? _unshareDrive(service, 'usb_share')
                            : _shareDrive(service, device),
                      ),
                      const SizedBox(width: 8),
                      _actionButton(
                        icon: Icons.eject_rounded,
                        label: 'Eject',
                        color: Colors.redAccent,
                        onPressed: () => _ejectDrive(service, device),
                      ),
                    ] else if (isUsbip && busId != null) ...[
                      if (isAttachedLocally) ...[
                        _actionButton(
                          icon: Icons.power_settings_new_rounded,
                          label: 'Detach Local',
                          color: Colors.redAccent,
                          onPressed: () => _detachUsbipDevice(service, busId, localPort),
                        ),
                      ] else ...[
                        _actionButton(
                          icon: Icons.link_rounded,
                          label: 'Attach Local',
                          color: const Color(0xFF00BFA5),
                          onPressed: () => _attachUsbipDevice(service, busId),
                        ),
                        if (device['status'] == 'Shared') ...[
                          const SizedBox(width: 8),
                          _actionButton(
                            icon: Icons.link_off_rounded,
                            label: 'Unbind Remote',
                            color: Colors.orange,
                            onPressed: () => _unbindRemoteDevice(service, busId),
                          ),
                        ],
                      ],
                    ] else
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: device['status'] == 'OK'
                              ? Colors.green.withValues(alpha: 0.15)
                              : Colors.grey.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          device['status'] ?? 'Unknown',
                          style: TextStyle(
                            color: device['status'] == 'OK' ? Colors.green : Colors.grey,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      }),
        ],
      ],
    );
  }

  List<Widget> _buildUsbipBanners(TunnelService service) {
    return [
      if (!_localUsbipInstalled)
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.redAccent.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.redAccent.withValues(alpha: 0.3)),
          ),
          child: Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: Colors.redAccent),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Local USBIP Client Missing',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                    SizedBox(height: 2),
                    Text('Install USBIP client on this machine to attach remote USB devices.',
                        style: TextStyle(color: Colors.white70, fontSize: 11)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                ),
                onPressed: () async {
                  final success = await service.installLocalUsbip();
                  if (success && mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('UAC prompt opened. Wait for installation, then tap Refresh.'),
                    ));
                    Timer.periodic(const Duration(seconds: 3), (timer) async {
                      final installed = await service.isLocalUsbipInstalled();
                      if (installed && mounted) {
                        setState(() {
                          _localUsbipInstalled = true;
                        });
                        timer.cancel();
                      }
                      if (timer.tick > 20) timer.cancel();
                    });
                  }
                },
                child: const Text('Install'),
              ),
            ],
          ),
        ),
      if (service.usbipdMissing)
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.orangeAccent.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.orangeAccent.withValues(alpha: 0.3)),
          ),
          child: Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Remote USBIP Host Missing',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                    SizedBox(height: 2),
                    Text('Install USBIP on the work machine to expose its USB devices.',
                        style: TextStyle(color: Colors.white70, fontSize: 11)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orangeAccent,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                ),
                onPressed: () async {
                  setState(() => _loading = true);
                  try {
                    final success = await service.installRemoteUsbip();
                    if (success && mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Remote USBIP installation triggered! Refreshing...'),
                        backgroundColor: Colors.green,
                      ));
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text('Failed to install remote USBIP: ${e.toString().replaceAll('Exception: ', '')}'),
                        backgroundColor: Colors.redAccent,
                      ));
                    }
                  } finally {
                    _refreshDevices();
                  }
                },
                child: const Text('Install'),
              ),
            ],
          ),
        ),
    ];
  }

  Widget _buildCapacityBar(Map<String, dynamic> device) {
    final total = (device['size'] as int? ?? 0).toDouble();
    final free = (device['freeSpace'] as int? ?? 0).toDouble();
    final used = total - free;
    final fraction = total > 0 ? (used / total).clamp(0.0, 1.0) : 0.0;

    Color barColor;
    if (fraction < 0.7) {
      barColor = const Color(0xFF00BFA5);
    } else if (fraction < 0.9) {
      barColor = Colors.orange;
    } else {
      barColor = Colors.redAccent;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: fraction,
            backgroundColor: const Color(0xFF1A2340),
            valueColor: AlwaysStoppedAnimation<Color>(barColor),
            minHeight: 6,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '${_formatBytes(used.toInt())} used',
              style: const TextStyle(color: Color(0xFF8892A4), fontSize: 11),
            ),
            Text(
              '${_formatBytes(free.toInt())} free',
              style: TextStyle(color: barColor, fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ],
    );
  }

  String _formatStorageSubtitle(Map<String, dynamic> device) {
    final total = device['size'] as int? ?? 0;
    final fileSystem = device['fileSystem'] as String? ?? '';
    if (total == 0) return device['id'] ?? '';
    return '${_formatBytes(total)} total${fileSystem.isNotEmpty ? ' · $fileSystem' : ''}';
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return ElevatedButton.icon(
      style: ElevatedButton.styleFrom(
        backgroundColor: color.withValues(alpha: 0.12),
        foregroundColor: color,
        elevation: 0,
        side: BorderSide(color: color.withValues(alpha: 0.3), width: 0.8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      icon: Icon(icon, size: 14),
      label: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      onPressed: onPressed,
    );
  }

  Future<void> _ejectDrive(TunnelService service, Map<String, dynamic> device) async {
    final driveLetter = device['driveLetter'] as String?;
    if (driveLetter == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F1629),
        title: const Text('Eject USB Drive'),
        content: Text(
          'Safely eject "${device['name']}" ($driveLetter) from the remote machine?',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eject', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await service.ejectRemoteUsbDrive(driveLetter);
      setState(() => _usbDevices.removeWhere((d) => d['driveLetter'] == driveLetter));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$driveLetter ejected successfully'),
            backgroundColor: const Color(0xFF00BFA5),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Eject failed: ${e.toString().replaceAll('Exception: ', '')}'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  Future<void> _shareDrive(TunnelService service, Map<String, dynamic> device) async {
    final driveLetter = device['driveLetter'] as String?;
    if (driveLetter == null) return;

    final drivePath = '$driveLetter\\';
    const shareName = 'usb_share';

    try {
      await service.shareRemoteUsbDrive(drivePath, shareName);
      setState(() => _sharedDrives.add(driveLetter));

      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF0F1629),
          title: const Row(
            children: [
              Icon(Icons.share_rounded, color: Color(0xFF00BFA5), size: 20),
              SizedBox(width: 8),
              Text('Drive Shared!', style: TextStyle(color: Colors.white)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'The USB drive is now shared through the tunnel.\n\nTo access it on your local machine:',
                style: TextStyle(color: Colors.white70, height: 1.4),
              ),
              const SizedBox(height: 16),
              const Text('1. Add a tunnel for port 445 → localhost:445 in the Tunnels tab',
                  style: TextStyle(color: Color(0xFF8892A4), fontSize: 12)),
              const SizedBox(height: 6),
              const Text('2. Map a network drive in Windows Explorer:',
                  style: TextStyle(color: Color(0xFF8892A4), fontSize: 12)),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF070A13),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const SelectableText(
                  r'\\127.0.0.1\usb_share',
                  style: TextStyle(fontFamily: 'Courier', color: Color(0xFF00BFA5), fontSize: 13),
                ),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                icon: const Icon(Icons.copy_rounded, size: 14),
                label: const Text('Copy path'),
                onPressed: () => Clipboard.setData(
                  const ClipboardData(text: r'\\127.0.0.1\usb_share'),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Share failed: ${e.toString().replaceAll('Exception: ', '')}'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  Future<void> _unshareDrive(TunnelService service, String shareName) async {
    try {
      await service.unshareRemoteUsbDrive(shareName);
      setState(() => _sharedDrives.clear());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Network share removed'),
            backgroundColor: Color(0xFF00BFA5),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to remove share: ${e.toString().replaceAll('Exception: ', '')}'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  Widget _buildPrintersTab(TunnelService service) {
    if (_printers.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.print_disabled_rounded, color: Color(0xFF8892A4), size: 48),
            SizedBox(height: 12),
            Text('No printers found on the remote machine.',
                style: TextStyle(color: Color(0xFF8892A4))),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _printers.length,
      itemBuilder: (context, index) {
        final printer = _printers[index];
        final isDefault = printer['isDefault'] as bool? ?? false;

        return Card(
          color: const Color(0xFF0F1629),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0xFF1A2340)),
          ),
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: const Color(0xFF00BFA5).withValues(alpha: 0.15),
                      child: const Icon(Icons.print_rounded, color: Color(0xFF00BFA5)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  printer['name'] ?? 'Unknown Printer',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold, fontSize: 15, color: Colors.white),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (isDefault) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF00BFA5).withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(
                                        color: const Color(0xFF00BFA5).withValues(alpha: 0.3), width: 0.5),
                                  ),
                                  child: const Text('Default',
                                      style: TextStyle(
                                          color: Color(0xFF00BFA5), fontSize: 9, fontWeight: FontWeight.bold)),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Status: ${printer['status'] ?? 'Offline'}',
                            style: TextStyle(
                              color: printer['status'] == 'Idle' ? Colors.green : Colors.redAccent,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _actionButton(
                      icon: Icons.folder_outlined,
                      label: 'Print Remote File',
                      color: const Color(0xFF8892A4),
                      onPressed: () => _selectAndPrintFile(service, printer['name']),
                    ),
                    const SizedBox(width: 8),
                    _actionButton(
                      icon: Icons.upload_file_rounded,
                      label: 'Print Local File',
                      color: const Color(0xFF00BFA5),
                      onPressed: () => _selectAndPrintLocalFile(service, printer['name']),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildComPortsTab() {
    if (_comPorts.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cable_rounded, color: Color(0xFF8892A4), size: 48),
            SizedBox(height: 12),
            Text('No serial/COM port devices found.',
                style: TextStyle(color: Color(0xFF8892A4))),
            SizedBox(height: 6),
            Text(
              'Devices like Arduino, GPS, modems appear here when connected.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF4A5568), fontSize: 12),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _comPorts.length,
      itemBuilder: (context, index) {
        final port = _comPorts[index];
        return Card(
          color: const Color(0xFF0F1629),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0xFF1A2340)),
          ),
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: Colors.purple.withValues(alpha: 0.15),
                  child: const Icon(Icons.cable_rounded, color: Colors.purple),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        port['name'] ?? 'Unknown COM Port',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15, color: Colors.white),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if ((port['description'] as String? ?? '').isNotEmpty &&
                          port['description'] != port['name']) ...[
                        const SizedBox(height: 2),
                        Text(
                          port['description'] as String,
                          style: const TextStyle(color: Color(0xFF8892A4), fontSize: 12),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: port['status'] == 'OK' || port['status'] == 'Unknown'
                        ? Colors.green.withValues(alpha: 0.15)
                        : Colors.grey.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    port['status'] ?? 'Unknown',
                    style: TextStyle(
                      color: port['status'] == 'OK' ? Colors.green : Colors.grey,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _selectAndPrintLocalFile(TunnelService service, String printerName) async {
    try {
      final result = await FilePicker.platform.pickFiles();
      if (result == null || result.files.single.path == null) return;
      final localPath = result.files.single.path!;
      final filename = result.files.single.name;
      final tempDestPath = 'temp_print_${DateTime.now().millisecondsSinceEpoch}_$filename';
      if (mounted) _showLocalPrintingProgress(service, localPath, tempDestPath, printerName);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error picking file: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  void _showLocalPrintingProgress(
      TunnelService service, String localPath, String tempDestPath, String printerName) {
    double uploadProgress = 0.0;
    String statusText = 'Uploading local file...';
    bool isUploading = true;
    bool isFinished = false;
    String? errorMessage;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> runProcess() async {
              try {
                await service.uploadLocalFile(localPath, tempDestPath,
                    onProgress: (progress) {
                  setDialogState(() {
                    uploadProgress = progress;
                    statusText = 'Uploading: ${(progress * 100).toStringAsFixed(0)}%';
                  });
                });
                setDialogState(() {
                  isUploading = false;
                  statusText = 'Spooling print job on remote agent...';
                });
                await service.triggerRemotePrint(tempDestPath, printerName, deleteAfter: true);
                setDialogState(() {
                  isFinished = true;
                  statusText = 'Print job completed successfully!';
                });
              } catch (e) {
                setDialogState(() {
                  errorMessage = e.toString().replaceAll('Exception: ', '');
                  isFinished = true;
                });
              }
            }

            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (statusText == 'Uploading local file...') runProcess();
            });

            if (errorMessage != null) {
              return AlertDialog(
                backgroundColor: const Color(0xFF0F1629),
                title: const Text('Print Job Failed'),
                content: Text(errorMessage!, style: const TextStyle(color: Colors.white70)),
                actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
              );
            }

            if (isFinished) {
              final fileName = localPath.split(Platform.isWindows ? '\\' : '/').last;
              return AlertDialog(
                backgroundColor: const Color(0xFF0F1629),
                title: const Text('Success'),
                content: Text('"$fileName" sent to "$printerName" successfully.',
                    style: const TextStyle(color: Colors.white70)),
                actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
              );
            }

            return AlertDialog(
              backgroundColor: const Color(0xFF0F1629),
              title: Text(isUploading ? 'Uploading Print File' : 'Spooling Print Job'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isUploading)
                    LinearProgressIndicator(
                        value: uploadProgress,
                        color: const Color(0xFF00BFA5),
                        backgroundColor: Colors.white24)
                  else
                    const CircularProgressIndicator(color: Color(0xFF00BFA5)),
                  const SizedBox(height: 16),
                  Text(statusText, style: const TextStyle(color: Colors.white70, fontSize: 13)),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _selectAndPrintFile(TunnelService service, String printerName) async {
    final selectedFile = await showDialog<String>(
      context: context,
      builder: (context) => _RemoteFilePickerDialog(service: service),
    );
    if (selectedFile != null && mounted) {
      _showPrintingProgress(service, selectedFile, printerName);
    }
  }

  void _showPrintingProgress(TunnelService service, String filePath, String printerName) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return FutureBuilder(
          future: service.triggerRemotePrint(filePath, printerName),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const AlertDialog(
                backgroundColor: Color(0xFF0F1629),
                title: Text('Sending Print Job...'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Color(0xFF00BFA5)),
                    SizedBox(height: 16),
                    Text('Executing remote print process...', style: TextStyle(color: Colors.white70)),
                  ],
                ),
              );
            }
            final fileName = filePath.split(Platform.isWindows ? '\\' : '/').last;
            if (snapshot.hasError) {
              return AlertDialog(
                backgroundColor: const Color(0xFF0F1629),
                title: const Text('Print Job Failed'),
                content: Text(snapshot.error.toString().replaceAll('Exception: ', ''),
                    style: const TextStyle(color: Colors.white70)),
                actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
              );
            }
            return AlertDialog(
              backgroundColor: const Color(0xFF0F1629),
              title: const Text('Success'),
              content: Text('"$fileName" sent to "$printerName" successfully.',
                  style: const TextStyle(color: Colors.white70)),
              actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
            );
          },
        );
      },
    );
  }

  Future<void> _attachUsbipDevice(TunnelService service, String busId) async {
    setState(() => _loading = true);
    try {
      final hasUsbipTunnel = service.tunnels.any((t) => t.enabled && t.localPort == 3240 && t.remotePort == 3240);
      if (!hasUsbipTunnel) {
        final settings = context.read<SettingsService>();
        final existingTunnelIdx = settings.rawTunnels.indexWhere((t) => t['localPort'] == 3240);
        if (existingTunnelIdx != -1) {
          final tc = TunnelConfig.fromJson(settings.rawTunnels[existingTunnelIdx]);
          final updated = tc.copyWith(enabled: true);
          service.updateTunnel(updated);
          final updatedAll = List<Map<String, dynamic>>.from(settings.rawTunnels);
          updatedAll[existingTunnelIdx] = updated.toJson();
          await settings.saveTunnels(updatedAll);
        } else {
          final newTunnel = TunnelConfig(
            id: const Uuid().v4(),
            profileId: settings.selectedProfileId,
            name: 'USBIP Auto-Tunnel',
            localPort: 3240,
            remoteHost: 'localhost',
            remotePort: 3240,
            enabled: true,
          );
          service.addTunnel(newTunnel);
          final updatedAll = List<Map<String, dynamic>>.from(settings.rawTunnels)..add(newTunnel.toJson());
          await settings.saveTunnels(updatedAll);
        }
        await Future.delayed(const Duration(milliseconds: 1000));
      }

      final bindSuccess = await service.bindRemoteUsbDevice(busId);
      if (!bindSuccess) {
        throw Exception('Failed to bind USB device on remote agent.');
      }

      final attachSuccess = await service.attachLocalUsbDevice(busId);
      if (!attachSuccess) {
        throw Exception('Remote device bound, but local usbip attach failed. Ensure the usbip client is installed locally.');
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('USB device attached successfully!'),
          backgroundColor: Colors.green,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error: ${e.toString().replaceAll('Exception: ', '')}'),
          backgroundColor: Colors.redAccent,
        ));
      }
    } finally {
      _refreshDevices();
    }
  }

  Future<void> _detachUsbipDevice(TunnelService service, String busId, String? localPort) async {
    setState(() => _loading = true);
    try {
      if (localPort != null) {
        final detachSuccess = await service.detachLocalUsbDevice(localPort);
        if (!detachSuccess) {
          throw Exception('Local usbip detach failed.');
        }
      }

      final unbindSuccess = await service.unbindRemoteUsbDevice(busId);
      if (!unbindSuccess) {
        throw Exception('Failed to unbind USB device on remote agent.');
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('USB device detached successfully.'),
          backgroundColor: Colors.green,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error detaching: ${e.toString().replaceAll('Exception: ', '')}'),
          backgroundColor: Colors.redAccent,
        ));
      }
    } finally {
      _refreshDevices();
    }
  }

  Future<void> _unbindRemoteDevice(TunnelService service, String busId) async {
    setState(() => _loading = true);
    try {
      final unbindSuccess = await service.unbindRemoteUsbDevice(busId);
      if (!unbindSuccess) {
        throw Exception('Failed to unbind USB device on remote agent.');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('USB device unbound from remote sharing.'),
          backgroundColor: Colors.green,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error unbinding: ${e.toString().replaceAll('Exception: ', '')}'),
          backgroundColor: Colors.redAccent,
        ));
      }
    } finally {
      _refreshDevices();
    }
  }
}

class _RemoteFilePickerDialog extends StatefulWidget {
  final TunnelService service;
  const _RemoteFilePickerDialog({required this.service});

  @override
  State<_RemoteFilePickerDialog> createState() => _RemoteFilePickerDialogState();
}

class _RemoteFilePickerDialogState extends State<_RemoteFilePickerDialog> {
  String _currentPath = '';
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String? _error;
  String? _selectedFile;

  @override
  void initState() {
    super.initState();
    _loadDirectory('');
  }

  Future<void> _loadDirectory(String path) async {
    setState(() { _loading = true; _error = null; _selectedFile = null; });
    try {
      final items = await widget.service.fetchRemoteFiles(path);
      setState(() { _items = items; _currentPath = path; _loading = false; });
    } catch (e) {
      setState(() { _error = e.toString().replaceAll('Exception: ', ''); _loading = false; });
    }
  }

  void _navigateUp() {
    if (_currentPath.isEmpty) return;
    final sep = _currentPath.contains('\\') ? '\\' : '/';
    final parts = _currentPath.split(sep);
    if (parts.length <= 1 || (parts.length == 2 && parts[1].isEmpty)) {
      _loadDirectory('');
    } else {
      parts.removeLast();
      _loadDirectory(parts.join(sep));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF0F1629),
      title: const Text('Select File to Print', style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: double.maxFinite,
        height: 350,
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_upward_rounded, color: Colors.white70),
                  onPressed: _currentPath.isNotEmpty ? _navigateUp : null,
                ),
                Expanded(
                  child: Text(
                    _currentPath.isEmpty ? 'Root Directory' : _currentPath,
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const Divider(color: Color(0xFF1A2340)),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator(color: Color(0xFF00BFA5)))
                  : _error != null
                      ? Center(child: Text(_error!, style: const TextStyle(color: Colors.redAccent)))
                      : ListView.builder(
                          itemCount: _items.length,
                          itemBuilder: (context, index) {
                            final item = _items[index];
                            final isDir = item['isDir'] as bool? ?? false;
                            final name = item['name'] as String;
                            final path = item['path'] as String;
                            final isSelected = _selectedFile == path;
                            return ListTile(
                              dense: true,
                              leading: Icon(
                                isDir ? Icons.folder_rounded : Icons.insert_drive_file_outlined,
                                color: isDir ? const Color(0xFF00BFA5) : const Color(0xFF8892A4),
                              ),
                              title: Text(name, style: const TextStyle(color: Colors.white)),
                              selected: isSelected,
                              selectedTileColor: const Color(0xFF00BFA5).withValues(alpha: 0.1),
                              onTap: () {
                                if (isDir) {
                                  _loadDirectory(path);
                                } else {
                                  setState(() => _selectedFile = path);
                                }
                              },
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00BFA5), foregroundColor: Colors.white),
          onPressed: _selectedFile != null ? () => Navigator.pop(context, _selectedFile) : null,
          child: const Text('Select'),
        ),
      ],
    );
  }
}
