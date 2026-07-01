import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../services/tunnel_service.dart';

class FileExplorerScreen extends StatefulWidget {
  const FileExplorerScreen({super.key});

  @override
  State<FileExplorerScreen> createState() => _FileExplorerScreenState();
}

class _FileExplorerScreenState extends State<FileExplorerScreen> {
  String _currentPath = '';
  List<Map<String, dynamic>> _items = [];
  bool _loading = false;
  String? _error;
  String _filterQuery = '';

  // Local transfers monitoring
  String? _activeTransferName;
  double _activeTransferProgress = 0.0;
  bool _isTransferring = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final service = context.read<TunnelService>();
      if (service.isConnected && service.peerConnected) {
        _loadDirectory('');
      }
    });
  }

  Future<void> _loadDirectory(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final service = context.read<TunnelService>();
      final files = await service.fetchRemoteFiles(path);
      setState(() {
        _items = files;
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

    // Check if the current path is a Windows drive root (e.g. "C:", "C:/", "c:/")
    final driveRootRegExp = RegExp(r'^[a-zA-Z]:/?$');
    if (driveRootRegExp.hasMatch(_currentPath)) {
      _loadDirectory('');
      return;
    }

    // Also check for Unix root
    if (_currentPath == '/') {
      _loadDirectory('');
      return;
    }

    final parts = _currentPath.split('/');
    if (parts.isNotEmpty) {
      parts.removeLast();
    }
    _loadDirectory(parts.join('/'));
  }

  void _navigateTo(String path) {
    _loadDirectory(path);
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = 0;
    double size = bytes.toDouble();
    while (size >= 1024 && i < suffixes.length - 1) {
      size /= 1024;
      i++;
    }
    return '${size.toStringAsFixed(1)} ${suffixes[i]}';
  }

  String _formatDate(int ms) {
    final date = DateTime.fromMillisecondsSinceEpoch(ms);
    return DateFormat('yyyy-MM-dd HH:mm').format(date);
  }

  String _getDownloadsDirectory() {
    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile != null) {
        return '$userProfile\\Downloads';
      }
    } else {
      final home = Platform.environment['HOME'];
      if (home != null) {
        return '$home/Downloads';
      }
    }
    return Directory.current.path;
  }

  Future<void> _showCreateFolderDialog() async {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F1629),
        title: const Text('Create Folder', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: ctrl,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Folder Name',
            hintStyle: TextStyle(color: Color(0xFF4A5568)),
            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF1A2340))),
            focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF00BFA5))),
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
              final name = ctrl.text.trim();
              if (name.isNotEmpty) {
                Navigator.pop(ctx);
                final newPath = _currentPath.isEmpty ? name : '$_currentPath/$name';
                try {
                  final service = context.read<TunnelService>();
                  await service.createRemoteDirectory(newPath);
                  _loadDirectory(_currentPath);
                } catch (e) {
                  _showErrorSnackBar('Failed to create folder: $e');
                }
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  Future<void> _showDeleteConfirmDialog(String path, String name) async {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F1629),
        title: const Text('Confirm Delete', style: TextStyle(color: Colors.white)),
        content: Text('Are you sure you want to delete "$name"?', style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Color(0xFF8892A4))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                final service = context.read<TunnelService>();
                await service.deleteRemoteEntity(path);
                _loadDirectory(_currentPath);
              } catch (e) {
                _showErrorSnackBar('Failed to delete: $e');
              }
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Future<void> _showDownloadDialog(String remotePath, String name) async {
    final defaultLocalPath = '${_getDownloadsDirectory()}${Platform.pathSeparator}$name';
    final ctrl = TextEditingController(text: defaultLocalPath);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F1629),
        title: const Text('Download File', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Save To Local Path:', style: TextStyle(color: Colors.white70, fontSize: 13)),
            const SizedBox(height: 8),
            TextField(
              controller: ctrl,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF1A2340))),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF00BFA5))),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Color(0xFF8892A4))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00BFA5)),
            onPressed: () {
              final localPath = ctrl.text.trim();
              Navigator.pop(ctx);
              if (localPath.isNotEmpty) {
                _startDownload(remotePath, localPath, name);
              }
            },
            child: const Text('Download'),
          ),
        ],
      ),
    );
  }

  Future<void> _startDownload(String remotePath, String localPath, String name) async {
    setState(() {
      _isTransferring = true;
      _activeTransferName = 'Downloading $name';
      _activeTransferProgress = 0.0;
    });

    try {
      final service = context.read<TunnelService>();
      await service.downloadRemoteFile(
        remotePath,
        localPath,
        onProgress: (bytesReceived) {
          // Note: Since we don't send file size in this simple protocol version, 
          // we update progress by animating it or just displaying bytes.
          // For UX, let's increment a counter or represent chunk increments.
          setState(() {
            _activeTransferProgress = -1.0; // Indeterminate/active state
          });
        },
      );
      _showSuccessSnackBar('Downloaded "$name" successfully!');
    } catch (e) {
      _showErrorSnackBar('Download failed: $e');
    } finally {
      setState(() {
        _isTransferring = false;
        _activeTransferName = null;
      });
    }
  }

  Future<void> _showUploadDialog() async {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F1629),
        title: const Text('Upload File', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Enter local absolute file path:', style: TextStyle(color: Colors.white70, fontSize: 13)),
            const SizedBox(height: 8),
            TextField(
              controller: ctrl,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: 'e.g., C:\\path\\to\\file.txt',
                hintStyle: TextStyle(color: Color(0xFF4A5568)),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF1A2340))),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF00BFA5))),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Color(0xFF8892A4))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00BFA5)),
            onPressed: () {
              final localPath = ctrl.text.trim();
              Navigator.pop(ctx);
              if (localPath.isNotEmpty) {
                _startUpload(localPath);
              }
            },
            child: const Text('Upload'),
          ),
        ],
      ),
    );
  }

  Future<void> _startUpload(String localPath) async {
    final file = File(localPath);
    if (!file.existsSync()) {
      _showErrorSnackBar('Local file does not exist.');
      return;
    }

    final name = file.path.split(Platform.pathSeparator).last;
    final remoteDestPath = _currentPath.isEmpty ? name : '$_currentPath/$name';

    setState(() {
      _isTransferring = true;
      _activeTransferName = 'Uploading $name';
      _activeTransferProgress = 0.0;
    });

    try {
      final service = context.read<TunnelService>();
      await service.uploadLocalFile(
        localPath,
        remoteDestPath,
        onProgress: (progress) {
          setState(() {
            _activeTransferProgress = progress;
          });
        },
      );
      _showSuccessSnackBar('Uploaded "$name" successfully!');
      _loadDirectory(_currentPath);
    } catch (e) {
      _showErrorSnackBar('Upload failed: $e');
    } finally {
      setState(() {
        _isTransferring = false;
        _activeTransferName = null;
      });
    }
  }

  void _showErrorSnackBar(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: Colors.redAccent,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showSuccessSnackBar(String msg) {
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
                  'To browse remote files, connect to the relay server and ensure the work agent is online.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFF8892A4), height: 1.4),
                ),
              ],
            ),
          ).animate().scale(delay: 100.ms, duration: 300.ms, curve: Curves.easeOutBack),
        ),
      );
    }

    final filteredItems = _items.where((item) {
      final name = item['name'] as String? ?? '';
      return name.toLowerCase().contains(_filterQuery.toLowerCase());
    }).toList();

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      body: Column(
        children: [
          // ── Breadcrumb path bar ────────────────────────────────────────────
          _buildBreadcrumbs(),

          // ── Action / Search controls ───────────────────────────────────────
          _buildControlBar(),

          // ── Transfer progress banner ───────────────────────────────────────
          if (_isTransferring) _buildTransferProgressBanner(),

          // ── Main File List ────────────────────────────────────────────────
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF00BFA5)))
                : _error != null
                    ? _buildErrorWidget()
                    : filteredItems.isEmpty
                        ? _buildEmptyWidget()
                        : ListView.separated(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            itemCount: filteredItems.length,
                            separatorBuilder: (_, __) => const Divider(color: Color(0xFF151D35), height: 1),
                            itemBuilder: (ctx, idx) {
                              final item = filteredItems[idx];
                              return _buildFileItem(item)
                                  .animate(delay: (idx * 20).ms)
                                  .fadeIn(duration: 250.ms)
                                  .slideX(begin: 0.03, end: 0);
                            },
                          ),
          ),
        ],
      ),
    );
  }

  Widget _buildBreadcrumbs() {
    final parts = _currentPath.split('/').where((p) => p.isNotEmpty).toList();
    return Container(
      color: const Color(0xFF0F1629),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_upward, size: 20, color: Color(0xFF00BFA5)),
            onPressed: _currentPath.isEmpty ? null : _navigateUp,
            tooltip: 'Go Up Directory',
          ),
          const SizedBox(width: 8),
          InkWell(
            onTap: () => _navigateTo(''),
            child: const Icon(Icons.home_outlined, size: 20, color: Colors.white70),
          ),
          if (parts.isNotEmpty)
            const Icon(Icons.chevron_right, size: 16, color: Color(0xFF4A5568)),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: parts.isEmpty
                    ? const []
                    : List.generate(parts.length * 2 - 1, (index) {
                        if (index.isOdd) {
                          return const Icon(Icons.chevron_right, size: 16, color: Color(0xFF4A5568));
                        }
                        final partIdx = index ~/ 2;
                        final fullSubPath = parts.sublist(0, partIdx + 1).join('/');
                        final isLast = partIdx == parts.length - 1;
                        return InkWell(
                          onTap: isLast ? null : () => _navigateTo(fullSubPath),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                            child: Text(
                              parts[partIdx],
                              style: TextStyle(
                                color: isLast ? const Color(0xFF00BFA5) : Colors.white70,
                                fontWeight: isLast ? FontWeight.bold : FontWeight.normal,
                              ),
                            ),
                          ),
                        );
                      }),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControlBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 40,
              decoration: BoxDecoration(
                color: const Color(0xFF0F1629),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF1A2340)),
              ),
              child: TextField(
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: const InputDecoration(
                  hintText: 'Search files...',
                  hintStyle: TextStyle(color: Color(0xFF4A5568), fontSize: 13),
                  prefixIcon: Icon(Icons.search, size: 16, color: Color(0xFF8892A4)),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 8),
                ),
                onChanged: (val) => setState(() => _filterQuery = val),
              ),
            ),
          ),
          const SizedBox(width: 12),
          IconButton(
            style: IconButton.styleFrom(
              backgroundColor: const Color(0xFF0F1629),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: const BorderSide(color: Color(0xFF1A2340)),
              ),
            ),
            icon: const Icon(Icons.create_new_folder_outlined, color: Color(0xFF00BFA5), size: 20),
            onPressed: _showCreateFolderDialog,
            tooltip: 'New Folder',
          ),
          const SizedBox(width: 8),
          IconButton(
            style: IconButton.styleFrom(
              backgroundColor: const Color(0xFF0F1629),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: const BorderSide(color: Color(0xFF1A2340)),
              ),
            ),
            icon: const Icon(Icons.upload_file_outlined, color: Color(0xFF00BFA5), size: 20),
            onPressed: _showUploadDialog,
            tooltip: 'Upload File',
          ),
        ],
      ),
    );
  }

  Widget _buildTransferProgressBanner() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0F1629),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF00BFA5).withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _activeTransferName ?? 'Transferring...',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
              ),
              if (_activeTransferProgress >= 0)
                Text(
                  '${(_activeTransferProgress * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(color: Color(0xFF00BFA5), fontWeight: FontWeight.bold, fontSize: 12),
                ),
            ],
          ),
          const SizedBox(height: 8),
          _activeTransferProgress >= 0
              ? LinearProgressIndicator(
                  value: _activeTransferProgress,
                  backgroundColor: const Color(0xFF1A2340),
                  color: const Color(0xFF00BFA5),
                  minHeight: 4,
                )
              : const LinearProgressIndicator(
                  backgroundColor: Color(0xFF1A2340),
                  color: Color(0xFF00BFA5),
                  minHeight: 4,
                ),
        ],
      ),
    );
  }

  Widget _buildFileItem(Map<String, dynamic> item) {
    final name = item['name'] as String? ?? '';
    final path = item['path'] as String? ?? '';
    final isDir = item['isDir'] as bool? ?? false;
    final size = item['size'] as int? ?? 0;
    final modified = item['modified'] as int? ?? 0;

    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: isDir
              ? Colors.amber.withValues(alpha: 0.1)
              : const Color(0xFF00BFA5).withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Icon(
          isDir ? Icons.folder : Icons.insert_drive_file_outlined,
          color: isDir ? Colors.amber : const Color(0xFF00BFA5),
          size: 20,
        ),
      ),
      title: Text(
        name,
        style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        isDir ? 'Directory' : '${_formatBytes(size)}  •  ${_formatDate(modified)}',
        style: const TextStyle(color: Color(0xFF8892A4), fontSize: 11),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isDir)
            IconButton(
              icon: const Icon(Icons.download_for_offline_outlined, color: Color(0xFF00BFA5), size: 20),
              onPressed: () => _showDownloadDialog(path, name),
              tooltip: 'Download',
            ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
            onPressed: () => _showDeleteConfirmDialog(path, name),
            tooltip: 'Delete',
          ),
        ],
      ),
      onTap: isDir ? () => _navigateTo(path) : null,
    );
  }

  Widget _buildErrorWidget() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 40),
            const SizedBox(height: 16),
            Text(
              _error ?? 'Error loading files',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, height: 1.4),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00BFA5)),
              onPressed: () => _loadDirectory(_currentPath),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyWidget() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.folder_open, color: Color(0xFF1E294B), size: 56),
          SizedBox(height: 16),
          Text(
            'This folder is empty',
            style: TextStyle(color: Color(0xFF8892A4), fontSize: 14),
          ),
        ],
      ),
    );
  }
}
