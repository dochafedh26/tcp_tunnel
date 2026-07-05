import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'file_manager.dart';
import 'protocol.dart';
import 'device_manager.dart';

/// Manages the agent's WebSocket connection to the relay server and
/// forwards TCP traffic between the relay and local work resources.
class AgentService {
  final List<String> relayUrls;
  final String token;
  final String sharedDir;

  final Logger _log = Logger('AgentService');

  WebSocketChannel? _channel;
  bool _running = false;
  late final FileManager _fileManager;

  /// Active TCP sockets keyed by channelId.
  final Map<String, Socket> _sockets = {};

  /// Queued data frames for channels that are currently connecting.
  final Map<String, List<List<int>>> _pendingData = {};

  /// Active RAW TCP print servers keyed by port.
  final Map<int, ServerSocket> _activePrintServers = {};

  // ── Stats ─────────────────────────────────────────────────────────────────
  int bytesReceived = 0;
  int bytesSent = 0;
  int get activeChannels => _sockets.length;

  AgentService({required String relayUrl, required this.token, String? sharedDir})
      : relayUrls = relayUrl.split(',').map((u) => u.trim()).where((u) => u.isNotEmpty).toList(),
        sharedDir = sharedDir ?? Directory.current.path {
    _fileManager = FileManager(this.sharedDir);
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Start the agent with automatic reconnection.
  Future<void> start() async {
    _running = true;

    // Start virtual RAW TCP print servers for USB printers
    _startPrinterServers();

    if (relayUrls.isEmpty) {
      _log.severe('No relay URLs configured. Exiting.');
      return;
    }

    int urlIndex = 0;
    while (_running) {
      final currentUrl = relayUrls[urlIndex];
      try {
        await _connect(currentUrl);
      } catch (e, st) {
        _log.severe('Connection error to $currentUrl', e, st);
      }
      if (_running) {
        urlIndex = (urlIndex + 1) % relayUrls.length;
        _log.info('Reconnecting in 5 seconds to ${relayUrls[urlIndex]}...');
        await Future.delayed(const Duration(seconds: 5));
      }
    }
  }

  /// Stop the agent and close all connections.
  void stop() {
    _running = false;
    _closeAllSockets();
    _channel?.sink.close();
    _channel = null;
    _stopPrinterServers();
  }

  // ── Connection ────────────────────────────────────────────────────────────

  Future<void> _connect(String urlToConnect) async {
    var normalizedUrl = urlToConnect.trim();
    if (!normalizedUrl.startsWith('ws://') && !normalizedUrl.startsWith('wss://')) {
      if (normalizedUrl.startsWith('http://') || normalizedUrl.startsWith('https://')) {
        normalizedUrl = normalizedUrl.replaceFirst('http', 'ws');
      } else {
        normalizedUrl = 'wss://$normalizedUrl';
      }
    }

    _log.info('Connecting to relay at $normalizedUrl ...');
    _channel = IOWebSocketChannel.connect(Uri.parse(normalizedUrl));

    // Send auth immediately
    _channel!.sink.add(Protocol.authMessage(token, 'agent', name: Platform.localHostname));
    _log.info('Auth message sent with hostname: ${Platform.localHostname}');

    final completer = Completer<void>();

    _channel!.stream.listen(
      _handleMessage,
      onError: (Object e, StackTrace st) {
        _log.severe('WebSocket error', e, st);
        _closeAllSockets();
        if (!completer.isCompleted) completer.completeError(e, st);
      },
      onDone: () {
        _log.warning('WebSocket connection closed by relay');
        _closeAllSockets();
        if (!completer.isCompleted) completer.complete();
      },
      cancelOnError: true,
    );

    await completer.future;
  }

  // ── Message handling ──────────────────────────────────────────────────────

  void _handleMessage(dynamic data) {
    if (data is String) {
      _handleTextMessage(data);
    } else if (Protocol.isDataFrame(data)) {
      _handleDataFrame(data is List<int> ? data : List<int>.from(data as List));
    }
  }

  void _handleTextMessage(String text) {
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(text) as Map<String, dynamic>;
    } catch (e) {
      _log.warning('Failed to parse JSON: $text');
      return;
    }

    final type = msg['type'] as String?;
    switch (type) {
      case 'auth_ok':
        _log.info('✓ Authenticated with relay — agent is ready');

      case 'peer_connected':
        _log.info('Flutter client connected to relay — tunnel active');

      case 'peer_disconnected':
        _log.info('Flutter client disconnected from relay');

      case 'open':
        final channelId = msg['channelId'] as String;
        final host = msg['host'] as String;
        final port = msg['port'] as int;
        _openChannel(channelId, host, port);

      case 'close':
        final channelId = msg['channelId'] as String;
        _closeChannel(channelId, notify: false);

      case 'ping':
        _channel?.sink.add(Protocol.pongMessage());

      case 'auth_error':
        _log.severe('Authentication rejected by relay: ${msg['message']}');
        stop();

      case 'file_list_request':
        final requestId = msg['requestId'] as String;
        final path = msg['path'] as String? ?? '';
        try {
          final items = _fileManager.listDirectory(path);
          _channel?.sink.add(Protocol.fileListResponse(requestId, path, true, items));
        } catch (e) {
          _channel?.sink.add(Protocol.fileListResponse(requestId, path, false, [], error: e.toString()));
        }

      case 'file_download_request':
        final requestId = msg['requestId'] as String;
        final path = msg['path'] as String;
        _handleFileDownload(requestId, path);

      case 'file_upload_chunk':
        final requestId = msg['requestId'] as String;
        final path = msg['path'] as String;
        final chunkIndex = msg['chunkIndex'] as int;
        final base64Data = msg['data'] as String;
        final isLast = msg['isLast'] as bool;
        _handleFileUploadChunk(requestId, path, chunkIndex, base64Data, isLast);

      case 'file_create_dir_request':
        final requestId = msg['requestId'] as String;
        final path = msg['path'] as String;
        try {
          _fileManager.createDirectory(path);
          _channel?.sink.add(Protocol.fileUploadResponse(requestId, true));
        } catch (e) {
          _channel?.sink.add(Protocol.fileUploadResponse(requestId, false, error: e.toString()));
        }

      case 'file_delete_request':
        final requestId = msg['requestId'] as String;
        final path = msg['path'] as String;
        try {
          _fileManager.deleteEntity(path);
          _channel?.sink.add(Protocol.fileUploadResponse(requestId, true));
        } catch (e) {
          _channel?.sink.add(Protocol.fileUploadResponse(requestId, false, error: e.toString()));
        }

      case 'device_list_request':
        final requestId = msg['requestId'] as String;
        _handleDeviceListRequest(requestId);

      case 'usb_eject_request':
        final requestId = msg['requestId'] as String;
        final driveLetter = msg['driveLetter'] as String;
        _handleUsbEjectRequest(requestId, driveLetter);

      case 'usb_share_request':
        final requestId = msg['requestId'] as String;
        final drivePath = msg['drivePath'] as String;
        final shareName = msg['shareName'] as String;
        _handleUsbShareRequest(requestId, drivePath, shareName);

      case 'usb_unshare_request':
        final requestId = msg['requestId'] as String;
        final shareName = msg['shareName'] as String;
        _handleUsbUnshareRequest(requestId, shareName);

      case 'usb_bind_request':
        final requestId = msg['requestId'] as String;
        final busId = msg['busId'] as String;
        _handleUsbBindRequest(requestId, busId);

      case 'usb_unbind_request':
        final requestId = msg['requestId'] as String;
        final busId = msg['busId'] as String;
        _handleUsbUnbindRequest(requestId, busId);

      case 'print_job_request':
        final requestId = msg['requestId'] as String;
        final filePath = msg['filePath'] as String;
        final printerName = msg['printerName'] as String;
        final deleteAfter = msg['deleteAfter'] as bool? ?? false;
        _handlePrintJobRequest(requestId, filePath, printerName, deleteAfter: deleteAfter);

      case 'terminal_command_request':
        final requestId = msg['requestId'] as String;
        final command = msg['command'] as String;
        final cwd = msg['cwd'] as String;
        _handleTerminalCommand(requestId, command, cwd);

      case 'install_usbip_request':
        final requestId = msg['requestId'] as String;
        _handleInstallUsbipRequest(requestId);

      default:
        _log.fine('Unhandled message type: $type');
    }
  }

  Future<void> _handleDeviceListRequest(String requestId) async {
    try {
      final usbipdInstalled = await DeviceManager.isUsbipdInstalled();
      final usbDevices = await DeviceManager.getUsbDevices();
      final printers = await DeviceManager.getPrinters();
      final comPorts = await DeviceManager.getSerialPorts();
      _channel?.sink.add(Protocol.deviceListResponseV2(
        requestId, true, usbDevices, printers, comPorts,
        usbipdMissing: !usbipdInstalled,
      ));
    } catch (e) {
      _channel?.sink.add(Protocol.deviceListResponseV2(requestId, false, [], [], [], error: e.toString()));
    }
  }

  Future<void> _handleInstallUsbipRequest(String requestId) async {
    try {
      ProcessResult result;
      if (Platform.isWindows) {
        // Prefer bundled usbipd-win.msi next to the agent executable (included in the release ZIP)
        final currentExeDir = File(Platform.resolvedExecutable).parent.path;
        var msiFile = File('$currentExeDir/usbipd-win.msi');
        if (!msiFile.existsSync()) {
          // Also check C:\tcp_tunnel_agent\ (the installed service location)
          msiFile = File(r'C:\tcp_tunnel_agent\usbipd-win.msi');
        }

        if (msiFile.existsSync()) {
          _log.info('Installing usbipd-win from bundled MSI: ${msiFile.path}');
          result = await Process.run('powershell', [
            '-Command',
            'Start-Process msiexec.exe -ArgumentList "/i `"${msiFile.absolute.path}`" /qn /norestart" -Verb RunAs -Wait; exit \$LASTEXITCODE'
          ]);
        } else {
          // Fallback: attempt winget if no MSI is available
          _log.warning('usbipd-win.msi not found next to agent.exe — falling back to winget.');
          result = await Process.run('winget', [
            'install', 'OUST.Usbipd-Win',
            '--silent', '--accept-source-agreements', '--accept-package-agreements'
          ]);
        }
      } else if (Platform.isLinux) {
        result = await Process.run('apt-get', ['install', '-y', 'usbip']);
      } else {
        throw Exception('Unsupported platform for USBIP auto-installation');
      }
      final success = result.exitCode == 0;
      _channel?.sink.add(jsonEncode({
        'type': 'install_usbip_response',
        'requestId': requestId,
        'success': success,
        'error': success ? null : 'Installation failed with exit code ${result.exitCode}: ${result.stderr}',
      }));
    } catch (e) {
      _channel?.sink.add(jsonEncode({
        'type': 'install_usbip_response',
        'requestId': requestId,
        'success': false,
        'error': e.toString(),
      }));
    }
  }

  Future<void> _handleUsbEjectRequest(String requestId, String driveLetter) async {
    try {
      final success = await DeviceManager.ejectUsbDrive(driveLetter);
      _channel?.sink.add(Protocol.usbEjectResponse(requestId, success,
          error: success ? null : 'Failed to eject drive'));
    } catch (e) {
      _channel?.sink.add(Protocol.usbEjectResponse(requestId, false, error: e.toString()));
    }
  }

  Future<void> _handleUsbShareRequest(String requestId, String drivePath, String shareName) async {
    try {
      final success = await DeviceManager.shareUsbDrive(drivePath, shareName);
      _channel?.sink.add(Protocol.usbShareResponse(requestId, success, shareName,
          error: success ? null : 'Failed to create network share. Ensure the agent runs as Administrator.'));
    } catch (e) {
      _channel?.sink.add(Protocol.usbShareResponse(requestId, false, shareName, error: e.toString()));
    }
  }

  Future<void> _handleUsbUnshareRequest(String requestId, String shareName) async {
    try {
      final success = await DeviceManager.removeUsbShare(shareName);
      _channel?.sink.add(Protocol.usbUnshareResponse(requestId, success,
          error: success ? null : 'Failed to remove share'));
    } catch (e) {
      _channel?.sink.add(Protocol.usbUnshareResponse(requestId, false, error: e.toString()));
    }
  }

  Future<void> _handleUsbBindRequest(String requestId, String busId) async {
    try {
      final success = await DeviceManager.bindUsbDevice(busId);
      _channel?.sink.add(Protocol.usbBindResponse(requestId, success,
          error: success ? null : 'Failed to bind device via usbip'));
    } catch (e) {
      _channel?.sink.add(Protocol.usbBindResponse(requestId, false, error: e.toString()));
    }
  }

  Future<void> _handleUsbUnbindRequest(String requestId, String busId) async {
    try {
      final success = await DeviceManager.unbindUsbDevice(busId);
      _channel?.sink.add(Protocol.usbUnbindResponse(requestId, success,
          error: success ? null : 'Failed to unbind device'));
    } catch (e) {
      _channel?.sink.add(Protocol.usbUnbindResponse(requestId, false, error: e.toString()));
    }
  }

  Future<void> _handlePrintJobRequest(String requestId, String filePath, String printerName, {bool deleteAfter = false}) async {
    try {
      final resolvedPath = _fileManager.resolvePath(filePath);
      final success = await DeviceManager.printFile(resolvedPath, printerName);
      if (success) {
        _channel?.sink.add(Protocol.printJobResponse(requestId, true));
      } else {
        _channel?.sink.add(Protocol.printJobResponse(requestId, false, error: 'Print command execution failed'));
      }
      if (deleteAfter) {
        try {
          final file = File(resolvedPath);
          if (file.existsSync()) {
            await file.delete();
          }
        } catch (_) {}
      }
    } catch (e) {
      _channel?.sink.add(Protocol.printJobResponse(requestId, false, error: e.toString()));
    }
  }

  Future<void> _handleTerminalCommand(String requestId, String command, String cwd) async {
    try {
      final ProcessResult result;
      final workingDir = cwd.trim().isEmpty ? sharedDir : cwd;
      
      if (Platform.isWindows) {
        result = await Process.run(
          'powershell.exe',
          ['-NoProfile', '-NonInteractive', '-Command', command],
          workingDirectory: workingDir,
        );
      } else {
        result = await Process.run(
          '/bin/sh',
          ['-c', command],
          workingDirectory: workingDir,
        );
      }
      
      _channel?.sink.add(Protocol.terminalCommandResponse(
        requestId,
        true,
        result.exitCode,
        result.stdout.toString(),
        result.stderr.toString(),
      ));
    } catch (e) {
      _channel?.sink.add(Protocol.terminalCommandResponse(
        requestId,
        false,
        -1,
        '',
        '',
        error: e.toString(),
      ));
    }
  }

  Future<void> _handleFileDownload(String requestId, String path) async {
    try {
      List<int>? prevChunk;
      int chunkIndex = 0;
      await for (final chunk in _fileManager.readFile(path)) {
        if (prevChunk != null) {
          final base64Data = base64Encode(prevChunk);
          _channel?.sink.add(Protocol.fileDownloadChunk(requestId, chunkIndex++, base64Data, false));
        }
        prevChunk = chunk;
      }
      if (prevChunk != null) {
        final base64Data = base64Encode(prevChunk);
        _channel?.sink.add(Protocol.fileDownloadChunk(requestId, chunkIndex, base64Data, true));
      } else {
        _channel?.sink.add(Protocol.fileDownloadChunk(requestId, 0, '', true));
      }
    } catch (e) {
      _channel?.sink.add(Protocol.fileError(requestId, e.toString()));
    }
  }

  Future<void> _handleFileUploadChunk(String requestId, String path, int chunkIndex, String base64Data, bool isLast) async {
    try {
      final chunk = base64Decode(base64Data);
      await _fileManager.writeFileChunk(requestId, path, chunk, isLast);
      if (isLast) {
        _channel?.sink.add(Protocol.fileUploadResponse(requestId, true));
      }
    } catch (e) {
      _fileManager.cancelWrite(requestId);
      _channel?.sink.add(Protocol.fileUploadResponse(requestId, false, error: e.toString()));
    }
  }

  void _handleDataFrame(List<int> frame) {
    try {
      final (:channelId, :data) = Protocol.decodeDataFrame(frame);
      final socket = _sockets[channelId];
      if (socket != null) {
        socket.add(data);
        bytesSent += data.length;
      } else if (_pendingData.containsKey(channelId)) {
        _log.fine('Queueing data frame for pending channel $channelId');
        _pendingData[channelId]!.add(data);
      } else {
        _log.warning('Data for unknown channel $channelId — dropping');
      }
    } catch (e) {
      _log.warning('Failed to decode data frame: $e');
    }
  }

  // ── Channel management ────────────────────────────────────────────────────

  Future<void> _openChannel(String channelId, String host, int port) async {
    _log.info('Opening channel $channelId → $host:$port');
    _pendingData[channelId] = [];
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 10),
      );
      _sockets[channelId] = socket;
      _log.info('TCP connected to $host:$port for channel $channelId');

      // Confirm to relay
      _channel?.sink.add(Protocol.openedMessage(channelId));

      // Flush any queued data to the socket
      final queue = _pendingData.remove(channelId);
      if (queue != null) {
        for (final data in queue) {
          socket.add(data);
          bytesSent += data.length;
        }
      }

      // Forward TCP data → relay
      socket.listen(
        (Uint8List data) {
          final frame = Protocol.encodeDataFrame(channelId, data);
          _channel?.sink.add(frame);
          bytesReceived += data.length;
        },
        onDone: () {
          _log.fine('TCP socket closed for channel $channelId');
          _closeChannel(channelId, notify: true);
        },
        onError: (Object e) {
          _log.warning('Socket error on channel $channelId: $e');
          _channel?.sink.add(Protocol.errorMessage(channelId, e.toString()));
          _sockets.remove(channelId)?.destroy();
        },
        cancelOnError: true,
      );
    } on SocketException catch (e) {
      _pendingData.remove(channelId);
      _log.warning('Cannot connect to $host:$port — ${e.message}');
      _channel?.sink.add(Protocol.errorMessage(channelId, e.message));
    } catch (e) {
      _pendingData.remove(channelId);
      _log.warning('Error opening channel $channelId: $e');
      _channel?.sink.add(Protocol.errorMessage(channelId, e.toString()));
    }
  }

  void _closeChannel(String channelId, {required bool notify}) {
    _pendingData.remove(channelId);
    final socket = _sockets.remove(channelId);
    if (socket != null) {
      socket.destroy();
      if (notify) {
        _channel?.sink.add(Protocol.closeMessage(channelId));
      }
      _log.fine('Closed channel $channelId');
    }
  }

  void _closeAllSockets() {
    for (final socket in _sockets.values) {
      socket.destroy();
    }
    _sockets.clear();
    _pendingData.clear();
  }

  Future<void> _startPrinterServers() async {
    try {
      final printers = await DeviceManager.getPrinters();
      if (printers.isEmpty) {
        _log.info('No system printers found to expose.');
        return;
      }

      // Sort printers so the default one is first
      printers.sort((a, b) {
        final aDefault = a['isDefault'] as bool? ?? false;
        final bDefault = b['isDefault'] as bool? ?? false;
        if (aDefault && !bDefault) return -1;
        if (!aDefault && bDefault) return 1;
        return (a['name'] as String).compareTo(b['name'] as String);
      });

      int port = 9100;
      for (final printer in printers) {
        final printerName = printer['name'] as String;
        final currentPort = port;
        port++;

        try {
          final server = await ServerSocket.bind('127.0.0.1', currentPort);
          _activePrintServers[currentPort] = server;
          _log.info('Exposed printer "$printerName" as RAW print server on 127.0.0.1:$currentPort');

          server.listen((socket) async {
            _log.info('Received RAW print job connection for "$printerName" on port $currentPort');
            final bytes = <int>[];
            socket.listen(
              (data) {
                bytes.addAll(data);
              },
              onDone: () async {
                socket.close();
                if (bytes.isEmpty) {
                  _log.warning('Print job socket closed with 0 bytes.');
                  return;
                }

                _log.info('Received ${bytes.length} bytes of raw print data. Spooling to printer "$printerName"...');

                // Save to a temporary file
                final tempDir = Directory.systemTemp;
                final tempFile = File('${tempDir.path}/raw_print_${DateTime.now().millisecondsSinceEpoch}.prn');
                try {
                  await tempFile.writeAsBytes(bytes);
                  final success = await DeviceManager.printFile(tempFile.path, printerName);
                  if (success) {
                    _log.info('Successfully spooled raw print job to "$printerName"');
                  } else {
                    _log.severe('Failed to spool raw print job to "$printerName"');
                  }
                } catch (e) {
                  _log.severe('Error spooling print job to "$printerName": $e');
                } finally {
                  try {
                    if (tempFile.existsSync()) {
                      await tempFile.delete();
                    }
                  } catch (_) {}
                }
              },
              onError: (e) {
                _log.severe('Socket error on print server port $currentPort: $e');
                socket.close();
              }
            );
          });
        } catch (e) {
          _log.severe('Failed to bind print server on port $currentPort for "$printerName": $e');
        }
      }
    } catch (e) {
      _log.severe('Failed to set up printer servers: $e');
    }
  }

  void _stopPrinterServers() {
    for (final server in _activePrintServers.values) {
      try {
        server.close();
      } catch (_) {}
    }
    _activePrintServers.clear();
    _log.info('Stopped all local print servers.');
  }
}
