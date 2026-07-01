import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../models/log_entry.dart';
import '../models/tunnel_config.dart';

/// Connection state of the tunnel service.
enum TunnelConnectionState { disconnected, connecting, connected, error }

/// Core service that manages:
///  1. A WebSocket connection to the relay server
///  2. Local TCP servers (one per enabled tunnel) listening on localPort
///  3. Bridging local TCP sockets ↔ relay WebSocket channels
class TunnelService extends ChangeNotifier {
  // ── State ──────────────────────────────────────────────────────────────────
  TunnelConnectionState _state = TunnelConnectionState.disconnected;
  TunnelConnectionState get state => _state;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  bool get isConnected => _state == TunnelConnectionState.connected;

  // ── Tunnels ────────────────────────────────────────────────────────────────
  final List<TunnelConfig> _tunnels = [];
  List<TunnelConfig> get tunnels => List.unmodifiable(_tunnels);

  /// Active local TCP servers: tunnelId → ServerSocket
  final Map<String, ServerSocket> _servers = {};

  /// Active forwarding channels: channelId → local Socket
  final Map<String, Socket> _localSockets = {};

  /// Pending channels waiting for relay 'opened' confirmation
  final Set<String> _pendingChannels = {};

  // ── File Explorer State ────────────────────────────────────────────────────
  final Map<String, Completer<List<Map<String, dynamic>>>> _fileListCompleters = {};
  final Map<String, _ActiveFileDownload> _activeDownloads = {};
  final Map<String, Completer<void>> _activeUploadCompleters = {};
  final Map<String, Completer<bool>> _fileActionCompleters = {};

  // ── Stats ──────────────────────────────────────────────────────────────────
  int _bytesIn = 0;
  int _bytesOut = 0;
  int get bytesIn => _bytesIn;
  int get bytesOut => _bytesOut;
  int get activeChannels => _localSockets.length;

  // ── Logs ───────────────────────────────────────────────────────────────────
  final List<LogEntry> _logs = [];
  List<LogEntry> get logs => List.unmodifiable(_logs);

  // ── WebSocket ──────────────────────────────────────────────────────────────
  WebSocketChannel? _ws;
  StreamSubscription? _wsSub;
  bool _peerConnected = false;
  bool get peerConnected => _peerConnected;

  // ── Auto-reconnect ─────────────────────────────────────────────────────────
  String? _lastRelayUrl;
  String? _lastToken;
  bool _autoReconnect = true;
  bool get autoReconnect => _autoReconnect;
  void setAutoReconnect(bool v) => _autoReconnect = v;

  static const _uuid = Uuid();

  // ── Wire protocol constants ────────────────────────────────────────────────
  static const int _dataFrameType = 0x01;
  static const int _headerLength = 37;

  // ── Public API ─────────────────────────────────────────────────────────────

  void setTunnels(List<TunnelConfig> tunnels) {
    _tunnels
      ..clear()
      ..addAll(tunnels);
    notifyListeners();
  }

  void addTunnel(TunnelConfig config) {
    _tunnels.add(config);
    notifyListeners();
    if (isConnected && config.enabled) {
      _startTunnelListener(config);
    }
  }

  void updateTunnel(TunnelConfig config) {
    final idx = _tunnels.indexWhere((t) => t.id == config.id);
    if (idx == -1) return;

    // Stop old listener if running
    _stopTunnelListener(config.id);
    _tunnels[idx] = config;
    notifyListeners();

    if (isConnected && config.enabled) {
      _startTunnelListener(config);
    }
  }

  void removeTunnel(String id) {
    _stopTunnelListener(id);
    _tunnels.removeWhere((t) => t.id == id);
    notifyListeners();
  }

  /// Connect to the relay server and start all enabled tunnel listeners.
  Future<void> connect(String relayUrl, String token) async {
    if (_state == TunnelConnectionState.connecting ||
        _state == TunnelConnectionState.connected) {
      return;
    }

    _setState(TunnelConnectionState.connecting);
    _lastRelayUrl = relayUrl.trim();
    _lastToken = token;

    var normalizedUrl = relayUrl.trim();
    if (!normalizedUrl.startsWith('ws://') && !normalizedUrl.startsWith('wss://')) {
      if (normalizedUrl.startsWith('http://') || normalizedUrl.startsWith('https://')) {
        normalizedUrl = normalizedUrl.replaceFirst('http', 'ws');
      } else {
        normalizedUrl = 'wss://$normalizedUrl';
      }
    }

    _log(LogLevel.info, 'Connecting to relay at $normalizedUrl...');

    try {
      _ws = IOWebSocketChannel.connect(
        Uri.parse(normalizedUrl),
        pingInterval: const Duration(seconds: 20),
      );

      // Send auth
      _send(jsonEncode({'type': 'auth', 'token': token, 'role': 'client'}));
      _log(LogLevel.info, 'Auth message sent');

      _wsSub = _ws!.stream.listen(
        _handleMessage,
        onError: (Object err) {
          _log(LogLevel.error, 'WebSocket error: $err');
          _onDisconnected(err.toString());
        },
        onDone: () {
          _log(LogLevel.warning, 'Relay connection closed');
          _onDisconnected(null);
        },
        cancelOnError: true,
      );

    } catch (e) {
      _log(LogLevel.error, 'Failed to connect: $e');
      _setState(TunnelConnectionState.error, error: e.toString());
    }
  }

  /// Disconnect from the relay and stop all tunnel listeners.
  Future<void> disconnect() async {
    _log(LogLevel.info, 'Disconnecting...');
    _lastRelayUrl = null; // Clear credentials to suppress auto-reconnect
    _lastToken = null;
    await _cleanup();
    _setState(TunnelConnectionState.disconnected);
    _log(LogLevel.info, 'Disconnected');
  }

  // ── Message handling ───────────────────────────────────────────────────────

  void _handleMessage(dynamic data) {
    if (data is String) {
      _handleTextMessage(data);
    } else {
      final bytes = data is Uint8List ? data : Uint8List.fromList(data as List<int>);
      if (bytes.isNotEmpty && bytes[0] == _dataFrameType && bytes.length >= _headerLength) {
        _handleDataFrame(bytes);
      }
    }
  }

  void _handleTextMessage(String text) {
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final type = msg['type'] as String?;
    switch (type) {
      case 'auth_ok':
        _log(LogLevel.success, 'Authenticated with relay ✓');
        _setState(TunnelConnectionState.connected);
        _startAllTunnelListeners();
        if (Platform.isAndroid) {
          FlutterForegroundTask.startService(
            notificationTitle: 'TCP Tunnel Active',
            notificationText: 'Tunnel is connected and running',
          ).then((_) {}).catchError((e) {
            _log(LogLevel.warning, 'Failed to start foreground service: $e');
          });
        }

      case 'auth_error':
        _log(LogLevel.error, 'Authentication failed: ${msg['message']}');
        _setState(TunnelConnectionState.error, error: msg['message'] as String?);

      case 'peer_connected':
        _peerConnected = true;
        _log(LogLevel.success, 'Work agent is online — tunnel fully active ✓');
        notifyListeners();

      case 'peer_disconnected':
        _peerConnected = false;
        _log(LogLevel.warning, 'Work agent disconnected');
        notifyListeners();

      case 'opened':
        final channelId = msg['channelId'] as String;
        _pendingChannels.remove(channelId);
        _log(LogLevel.debug, 'Channel $channelId opened');

      case 'close':
        final channelId = msg['channelId'] as String;
        _closeLocalSocket(channelId);

      case 'error':
        final channelId = msg['channelId'] as String;
        _log(LogLevel.error, 'Channel error: ${msg['message']}');
        _closeLocalSocket(channelId);

      case 'ping':
        _send(jsonEncode({'type': 'pong'}));

      case 'file_list_response':
        final requestId = msg['requestId'] as String;
        final success = msg['success'] as bool;
        final error = msg['error'] as String?;
        final items = List<Map<String, dynamic>>.from(msg['items'] as List? ?? []);
        final completer = _fileListCompleters.remove(requestId);
        if (completer != null) {
          if (success) {
            completer.complete(items);
          } else {
            completer.completeError(Exception(error ?? 'Failed to list files'));
          }
        }

      case 'file_download_chunk':
        final requestId = msg['requestId'] as String;
        final base64Data = msg['data'] as String;
        final isLast = msg['isLast'] as bool;
        final download = _activeDownloads[requestId];
        if (download != null) {
          try {
            final bytes = base64Decode(base64Data);
            download.sink.add(bytes);
            download.bytesReceived += bytes.length;
            if (download.onProgress != null) {
              download.onProgress!(download.bytesReceived.toDouble());
            }
            if (isLast) {
              _activeDownloads.remove(requestId);
              download.sink.close().then((_) {
                download.completer.complete();
              });
            }
          } catch (e) {
            _activeDownloads.remove(requestId);
            download.sink.close().then((_) {
              download.completer.completeError(e);
            });
          }
        }

      case 'file_upload_response':
        final requestId = msg['requestId'] as String;
        final success = msg['success'] as bool;
        final error = msg['error'] as String?;
        final uploadCompleter = _activeUploadCompleters.remove(requestId);
        if (uploadCompleter != null) {
          if (success) {
            uploadCompleter.complete();
          } else {
            uploadCompleter.completeError(Exception(error ?? 'Upload failed'));
          }
        }
        final actionCompleter = _fileActionCompleters.remove(requestId);
        if (actionCompleter != null) {
          actionCompleter.complete(success);
        }

      case 'file_error':
        final requestId = msg['requestId'] as String;
        final message = msg['message'] as String;
        final download = _activeDownloads.remove(requestId);
        if (download != null) {
          download.sink.close().then((_) {
            download.completer.completeError(Exception(message));
          });
        }
        final uploadCompleter = _activeUploadCompleters.remove(requestId);
        if (uploadCompleter != null) {
          uploadCompleter.completeError(Exception(message));
        }
        final fileListCompleter = _fileListCompleters.remove(requestId);
        if (fileListCompleter != null) {
          fileListCompleter.completeError(Exception(message));
        }
    }
  }

  void _handleDataFrame(Uint8List frame) {
    final channelId = ascii.decode(frame.sublist(1, _headerLength));
    final payload = frame.sublist(_headerLength);
    final socket = _localSockets[channelId];
    if (socket != null) {
      socket.add(payload);
      _bytesIn += payload.length;
      notifyListeners();
    }
  }

  // ── Tunnel listeners ───────────────────────────────────────────────────────

  void _startAllTunnelListeners() {
    for (final tunnel in _tunnels.where((t) => t.enabled)) {
      _startTunnelListener(tunnel);
    }
  }

  Future<void> _startTunnelListener(TunnelConfig config) async {
    if (_servers.containsKey(config.id)) return;
    try {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, config.localPort);
      _servers[config.id] = server;
      _log(LogLevel.info,
          'Listening on localhost:${config.localPort} → ${config.remoteHost}:${config.remotePort} [${config.name}]');

      server.listen((Socket socket) {
        final channelId = _uuid.v4();
        _localSockets[channelId] = socket;
        _log(LogLevel.debug, 'New local connection on ${config.name}, channelId=$channelId');

        // Ask relay to open a channel to the work resource
        _send(jsonEncode({
          'type': 'open',
          'channelId': channelId,
          'host': config.remoteHost,
          'port': config.remotePort,
        }));
        _pendingChannels.add(channelId);

        // Forward local TCP data → relay
        socket.listen(
          (Uint8List data) {
            _sendDataFrame(channelId, data);
            _bytesOut += data.length;
            notifyListeners();
          },
          onDone: () {
            _send(jsonEncode({'type': 'close', 'channelId': channelId}));
            _localSockets.remove(channelId);
            notifyListeners();
          },
          onError: (_) {
            _send(jsonEncode({'type': 'close', 'channelId': channelId}));
            _localSockets.remove(channelId)?.destroy();
            notifyListeners();
          },
          cancelOnError: true,
        );
      });
      notifyListeners();
    } catch (e) {
      _log(LogLevel.error, 'Cannot bind port ${config.localPort}: $e');
    }
  }

  void _stopTunnelListener(String tunnelId) {
    _servers.remove(tunnelId)?.close();
  }

  void _closeLocalSocket(String channelId) {
    _localSockets.remove(channelId)?.destroy();
  }

  // ── Wire encoding ──────────────────────────────────────────────────────────

  void _send(String text) {
    try {
      _ws?.sink.add(text);
    } catch (_) {}
  }

  void _sendDataFrame(String channelId, List<int> data) {
    try {
      final channelBytes = ascii.encode(channelId);
      final frame = Uint8List(_headerLength + data.length);
      frame[0] = _dataFrameType;
      frame.setRange(1, _headerLength, channelBytes);
      frame.setRange(_headerLength, frame.length, data);
      _ws?.sink.add(frame);
    } catch (_) {}
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  void _setState(TunnelConnectionState state, {String? error}) {
    _state = state;
    _errorMessage = error;
    notifyListeners();
  }

  void _onDisconnected(String? reason) {
    _cleanup();
    _setState(TunnelConnectionState.disconnected);
    _peerConnected = false;

    // Auto-reconnect after 5 seconds if we have stored credentials
    if (_autoReconnect && _lastRelayUrl != null && _lastToken != null) {
      _log(LogLevel.info, 'Auto-reconnecting in 5 seconds...');
      Future.delayed(const Duration(seconds: 5), () {
        if (_state == TunnelConnectionState.disconnected &&
            _lastRelayUrl != null && _lastToken != null) {
          connect(_lastRelayUrl!, _lastToken!);
        }
      });
    }
  }

  Future<void> _cleanup() async {
    if (Platform.isAndroid) {
      try {
        await FlutterForegroundTask.stopService();
      } catch (_) {}
    }
    await _wsSub?.cancel();
    _wsSub = null;
    await _ws?.sink.close();
    _ws = null;
    for (final s in _servers.values) {
      await s.close();
    }
    _servers.clear();
    for (final s in _localSockets.values) {
      s.destroy();
    }
    _localSockets.clear();
    _pendingChannels.clear();
    _peerConnected = false;

    // Clean up file explorer state
    for (final download in _activeDownloads.values) {
      download.sink.close().catchError((_) => null);
      download.completer.completeError(Exception('Disconnected'));
    }
    _activeDownloads.clear();
    for (final completer in _fileListCompleters.values) {
      completer.completeError(Exception('Disconnected'));
    }
    _fileListCompleters.clear();
    for (final completer in _activeUploadCompleters.values) {
      completer.completeError(Exception('Disconnected'));
    }
    _activeUploadCompleters.clear();
    for (final completer in _fileActionCompleters.values) {
      completer.completeError(Exception('Disconnected'));
    }
    _fileActionCompleters.clear();
  }

  void _log(LogLevel level, String message) {
    _logs.add(LogEntry(timestamp: DateTime.now(), level: level, message: message));
    if (_logs.length > 500) _logs.removeAt(0); // cap log size
    notifyListeners();
  }

  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }

  // ── Remote File Operations ──────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> fetchRemoteFiles(String path) async {
    if (!isConnected) throw Exception('Not connected to relay');
    final requestId = _uuid.v4();
    final completer = Completer<List<Map<String, dynamic>>>();
    _fileListCompleters[requestId] = completer;

    _send(jsonEncode({
      'type': 'file_list_request',
      'requestId': requestId,
      'path': path,
    }));

    return completer.future;
  }

  Future<void> createRemoteDirectory(String remotePath) async {
    if (!isConnected) throw Exception('Not connected to relay');
    final requestId = _uuid.v4();
    final completer = Completer<bool>();
    _fileActionCompleters[requestId] = completer;

    _send(jsonEncode({
      'type': 'file_create_dir_request',
      'requestId': requestId,
      'path': remotePath,
    }));

    final success = await completer.future;
    if (!success) throw Exception('Failed to create remote directory');
  }

  Future<void> deleteRemoteEntity(String remotePath) async {
    if (!isConnected) throw Exception('Not connected to relay');
    final requestId = _uuid.v4();
    final completer = Completer<bool>();
    _fileActionCompleters[requestId] = completer;

    _send(jsonEncode({
      'type': 'file_delete_request',
      'requestId': requestId,
      'path': remotePath,
    }));

    final success = await completer.future;
    if (!success) throw Exception('Failed to delete remote item');
  }

  Future<void> downloadRemoteFile(String remotePath, String localSavePath, {Function(double)? onProgress}) async {
    if (!isConnected) throw Exception('Not connected to relay');
    final requestId = _uuid.v4();
    final completer = Completer<void>();

    final file = File(localSavePath);
    await file.parent.create(recursive: true);
    final sink = file.openWrite();

    _activeDownloads[requestId] = _ActiveFileDownload(
      remotePath: remotePath,
      localSavePath: localSavePath,
      sink: sink,
      completer: completer,
      onProgress: onProgress,
    );

    _send(jsonEncode({
      'type': 'file_download_request',
      'requestId': requestId,
      'path': remotePath,
    }));

    try {
      await completer.future;
    } catch (e) {
      await sink.close();
      try {
        await file.delete();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> uploadLocalFile(String localPath, String remoteDestPath, {Function(double)? onProgress}) async {
    if (!isConnected) throw Exception('Not connected to relay');
    final file = File(localPath);
    if (!file.existsSync()) throw Exception('Local file does not exist');

    final requestId = _uuid.v4();
    final completer = Completer<void>();
    _activeUploadCompleters[requestId] = completer;

    final fileLength = await file.length();
    final openFile = await file.open();

    try {
      const chunkSize = 64 * 1024;
      int bytesSent = 0;
      int chunkIndex = 0;

      while (bytesSent < fileLength) {
        final remaining = fileLength - bytesSent;
        final toRead = remaining < chunkSize ? remaining : chunkSize;
        final chunk = await openFile.read(toRead);
        bytesSent += toRead;

        final isLast = bytesSent >= fileLength;
        final base64Data = base64Encode(chunk);

        _send(jsonEncode({
          'type': 'file_upload_chunk',
          'requestId': requestId,
          'path': remoteDestPath,
          'chunkIndex': chunkIndex++,
          'data': base64Data,
          'isLast': isLast,
        }));

        if (onProgress != null && fileLength > 0) {
          onProgress(bytesSent / fileLength);
        }

        await Future.delayed(const Duration(milliseconds: 5));
      }

      await completer.future;
    } catch (e) {
      rethrow;
    } finally {
      await openFile.close();
      _activeUploadCompleters.remove(requestId);
    }
  }

  @override
  void dispose() {
    _cleanup();
    super.dispose();
  }
}

class _ActiveFileDownload {
  final String remotePath;
  final String localSavePath;
  final IOSink sink;
  final Completer<void> completer;
  final Function(double)? onProgress;
  int bytesReceived = 0;

  _ActiveFileDownload({
    required this.remotePath,
    required this.localSavePath,
    required this.sink,
    required this.completer,
    this.onProgress,
  });
}
