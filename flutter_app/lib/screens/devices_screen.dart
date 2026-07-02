import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/tunnel_service.dart';

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

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshDevices();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _refreshDevices() async {
    final service = context.read<TunnelService>();
    if (!service.isConnected || !service.peerConnected) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final data = await service.fetchRemoteDevices();
      setState(() {
        _usbDevices = data['usbDevices'] ?? [];
        _printers = data['printers'] ?? [];
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

    // ── Disconnected / Offline state ──────────────────────────────────────────
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
                Text(
                  'Work Agent Offline',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                ),
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
                    SizedBox(width: 8),
                    Text('USB Devices'),
                  ],
                ),
              ),
              Tab(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.print_rounded, size: 18),
                    SizedBox(width: 8),
                    Text('Printers'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _refreshDevices,
        color: const Color(0xFF00BFA5),
        backgroundColor: const Color(0xFF0F1629),
        child: _loading
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
                    ],
                  ),
      ),
    );
  }

  Widget _buildUsbTab(TunnelService service) {
    if (_usbDevices.isEmpty) {
      return const Center(
        child: Text('No connected USB devices found.', style: TextStyle(color: Color(0xFF8892A4))),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _usbDevices.length,
      itemBuilder: (context, index) {
        final device = _usbDevices[index];
        final isStorage = device['class'] == 'Storage';

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
                  backgroundColor: isStorage ? Colors.blue.withValues(alpha: 0.15) : const Color(0xFF00BFA5).withValues(alpha: 0.15),
                  child: Icon(
                    isStorage ? Icons.folder_open_rounded : Icons.usb_rounded,
                    color: isStorage ? Colors.blue : const Color(0xFF00BFA5),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        device['name'] ?? 'Unknown USB Device',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.white),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'ID: ${device['id'] ?? 'N/A'}',
                        style: const TextStyle(color: Color(0xFF8892A4), fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (isStorage && device['driveLetter'] != null)
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00BFA5),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    icon: const Icon(Icons.arrow_forward_rounded, size: 16),
                    label: const Text('Browse', style: TextStyle(fontSize: 13)),
                    onPressed: () {
                      service.requestedBrowsePath = device['driveLetter'];
                      if (widget.onTabChange != null) {
                        widget.onTabChange!(1); // index 1 is File Explorer tab
                      }
                    },
                  )
                else
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: device['status'] == 'OK' ? Colors.green.withValues(alpha: 0.15) : Colors.grey.withValues(alpha: 0.15),
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
          ),
        );
      },
    );
  }

  Widget _buildPrintersTab(TunnelService service) {
    if (_printers.isEmpty) {
      return const Center(
        child: Text('No printers found on the remote machine.', style: TextStyle(color: Color(0xFF8892A4))),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _printers.length,
      itemBuilder: (context, index) {
        final printer = _printers[index];
        final isDefault = printer['isDefault'] ?? false;

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
                  backgroundColor: const Color(0xFF00BFA5).withValues(alpha: 0.15),
                  child: const Icon(Icons.print_rounded, color: Color(0xFF00BFA5)),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              printer['name'] ?? 'Unknown Printer',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.white),
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
                                border: Border.all(color: const Color(0xFF00BFA5).withValues(alpha: 0.3), width: 0.5),
                              ),
                              child: const Text('Default', style: TextStyle(color: Color(0xFF00BFA5), fontSize: 9, fontWeight: FontWeight.bold)),
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
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00BFA5),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: const Icon(Icons.upload_file_rounded, size: 16),
                  label: const Text('Print File', style: TextStyle(fontSize: 13)),
                  onPressed: () => _selectAndPrintFile(service, printer['name']),
                ),
              ],
            ),
          ),
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
                content: Text(snapshot.error.toString().replaceAll('Exception: ', ''), style: const TextStyle(color: Colors.white70)),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close'),
                  ),
                ],
              );
            }

            return AlertDialog(
              backgroundColor: const Color(0xFF0F1629),
              title: const Text('Success'),
              content: Text('"$fileName" has been sent to remote printer "$printerName" successfully.', style: const TextStyle(color: Colors.white70)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('OK'),
                ),
              ],
            );
          },
        );
      },
    );
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
    setState(() {
      _loading = true;
      _error = null;
      _selectedFile = null;
    });

    try {
      final items = await widget.service.fetchRemoteFiles(path);
      setState(() {
        _items = items;
        _currentPath = path;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString().replaceAll('Exception: ', '');
        _loading = false;
      });
    }
  }

  void _navigateUp() {
    if (_currentPath.isEmpty) return;
    // Handle Windows drive letters or unix slash
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
                                  setState(() {
                                    _selectedFile = path;
                                  });
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
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF00BFA5),
            foregroundColor: Colors.white,
          ),
          onPressed: _selectedFile != null ? () => Navigator.pop(context, _selectedFile) : null,
          child: const Text('Select'),
        ),
      ],
    );
  }
}
