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
import 'background_tunnel_handler.dart';

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

  // ── Device/Printer Explorer State ──────────────────────────────────────────
  final Map<String, Completer<Map<String, dynamic>>> _deviceListCompleters = {};
  final Map<String, Completer<void>> _printJobCompleters = {};

  // ── Terminal Shell State ────────────────────────────────────────────────────
  final Map<String, Completer<Map<String, dynamic>>> _terminalCommandCompleters = {};

  // ── USB Control State ───────────────────────────────────────────────────────
  final Map<String, Completer<bool>> _usbEjectCompleters = {};
  final Map<String, Completer<bool>> _usbShareCompleters = {};
  final Map<String, Completer<bool>> _usbUnshareCompleters = {};
  final Map<String, Completer<bool>> _usbBindCompleters = {};
  final Map<String, Completer<bool>> _usbUnbindCompleters = {};
  final Map<String, Completer<bool>> _installRemoteUsbipCompleters = {};

  // ── USBIP State ────────────────────────────────────────────────────────────
  bool _usbipdMissing = false;
  bool get usbipdMissing => _usbipdMissing;

  // ── Stats ──────────────────────────────────────────────────────────────────
  int _bytesIn = 0;
  int _bytesOut = 0;
  int get bytesIn => _bytesIn;
  int get bytesOut => _bytesOut;
  int get activeChannels => _localSockets.length;

  String? _requestedBrowsePath;
  String? get requestedBrowsePath => _requestedBrowsePath;
  set requestedBrowsePath(String? value) {
    _requestedBrowsePath = value;
    notifyListeners();
  }

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

  // ── Constructor ────────────────────────────────────────────────────────────
  TunnelService() {
    if (Platform.isAndroid) {
      FlutterForegroundTask.addTaskDataCallback(_onReceiveTaskData);
    }
  }

  void _onReceiveTaskData(Object data) {
    if (data is Map<String, dynamic>) {
      final type = data['type'] as String?;
      switch (type) {
        case 'state':
          final val = data['value'] as String;
          final err = data['error'] as String?;
          if (val == 'connected') {
            _setState(TunnelConnectionState.connected);
          } else if (val == 'connecting') {
            _setState(TunnelConnectionState.connecting);
          } else if (val == 'disconnected') {
            _setState(TunnelConnectionState.disconnected);
          } else if (val == 'error') {
            _setState(TunnelConnectionState.error, error: err);
          }
        case 'log':
          final lvlStr = data['level'] as String;
          final msg = data['message'] as String;
          LogLevel level = LogLevel.info;
          if (lvlStr == 'success') level = LogLevel.success;
          if (lvlStr == 'warning') level = LogLevel.warning;
          if (lvlStr == 'error') level = LogLevel.error;
          if (lvlStr == 'debug') level = LogLevel.debug;
          _log(level, msg);
        case 'stats':
          _bytesIn = data['bytesIn'] as int;
          _bytesOut = data['bytesOut'] as int;
          _peerConnected = data['peerConnected'] as bool;
          notifyListeners();
        case 'file_explorer_response':
          final responseData = data['data'] as Map<String, dynamic>;
          _handleTextMessage(jsonEncode(responseData));
      }
    }
  }

  void _syncTunnelsToTask() {
    if (Platform.isAndroid && isConnected) {
      FlutterForegroundTask.sendDataToTask({
        'action': 'updateTunnels',
        'tunnels': _tunnels.map((t) => t.toJson()).toList(),
      });
    }
  }

  // ── Wire protocol constants ────────────────────────────────────────────────
  static const int _dataFrameType = 0x01;
  static const int _headerLength = 37;

  // ── Public API ─────────────────────────────────────────────────────────────

  void setTunnels(List<TunnelConfig> tunnels) {
    _tunnels
      ..clear()
      ..addAll(tunnels);
    notifyListeners();
    _syncTunnelsToTask();
  }

  void addTunnel(TunnelConfig config) {
    _tunnels.add(config);
    notifyListeners();
    if (isConnected && config.enabled) {
      if (!Platform.isAndroid) {
        _startTunnelListener(config);
      }
    }
    _syncTunnelsToTask();
  }

  void updateTunnel(TunnelConfig config) {
    final idx = _tunnels.indexWhere((t) => t.id == config.id);
    if (idx == -1) return;

    // Stop old listener if running
    if (!Platform.isAndroid) {
      _stopTunnelListener(config.id);
    }
    _tunnels[idx] = config;
    notifyListeners();

    if (isConnected && config.enabled) {
      if (!Platform.isAndroid) {
        _startTunnelListener(config);
      }
    }
    _syncTunnelsToTask();
  }

  void removeTunnel(String id) {
    if (!Platform.isAndroid) {
      _stopTunnelListener(id);
    }
    _tunnels.removeWhere((t) => t.id == id);
    notifyListeners();
    _syncTunnelsToTask();
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

    if (Platform.isAndroid) {
      final started = await FlutterForegroundTask.startService(
        notificationTitle: 'TCP Tunnel Active',
        notificationText: 'Tunnel is connected and running',
        callback: startBackgroundTunnelCallback,
        serviceTypes: [ForegroundServiceTypes.dataSync],
      );
      if (started is ServiceRequestSuccess) {
        FlutterForegroundTask.sendDataToTask({
          'action': 'connect',
          'relayUrl': relayUrl,
          'token': token,
          'tunnels': _tunnels.map((t) => t.toJson()).toList(),
        });
      } else {
        _log(LogLevel.error, 'Failed to start Android foreground service');
        _setState(TunnelConnectionState.error, error: 'Foreground service failed to start');
      }
      return;
    }

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
    if (Platform.isAndroid) {
      FlutterForegroundTask.sendDataToTask({'action': 'disconnect'});
      await FlutterForegroundTask.stopService();
      _setState(TunnelConnectionState.disconnected);
    } else {
      await _cleanup();
      _setState(TunnelConnectionState.disconnected);
    }
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
            serviceTypes: [ForegroundServiceTypes.dataSync],
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
        final deviceListCompleter = _deviceListCompleters.remove(requestId);
        if (deviceListCompleter != null) {
          deviceListCompleter.completeError(Exception(message));
        }
        final printJobCompleter = _printJobCompleters.remove(requestId);
        if (printJobCompleter != null) {
          printJobCompleter.completeError(Exception(message));
        }
        final terminalCommandCompleter = _terminalCommandCompleters.remove(requestId);
        if (terminalCommandCompleter != null) {
          terminalCommandCompleter.completeError(Exception(message));
        }

      case 'device_list_response':
        final requestId = msg['requestId'] as String;
        final success = msg['success'] as bool;
        final error = msg['error'] as String?;
        final usbDevices = List<Map<String, dynamic>>.from(msg['usbDevices'] as List? ?? []);
        final printers = List<Map<String, dynamic>>.from(msg['printers'] as List? ?? []);
        final comPorts = List<Map<String, dynamic>>.from(msg['comPorts'] as List? ?? []);
        _usbipdMissing = msg['usbipdMissing'] as bool? ?? false;
        notifyListeners();
        final completer = _deviceListCompleters.remove(requestId);
        if (completer != null) {
          if (success) {
            completer.complete({
              'usbDevices': usbDevices,
              'printers': printers,
              'comPorts': comPorts,
              'usbipdMissing': _usbipdMissing,
            });
          } else {
            completer.completeError(Exception(error ?? 'Failed to list devices'));
          }
        }

      case 'print_job_response':
        final requestId = msg['requestId'] as String;
        final success = msg['success'] as bool;
        final error = msg['error'] as String?;
        final completer = _printJobCompleters.remove(requestId);
        if (completer != null) {
          if (success) {
            completer.complete();
          } else {
            completer.completeError(Exception(error ?? 'Print job failed'));
          }
        }

      case 'terminal_command_response':
        final requestId = msg['requestId'] as String;
        final success = msg['success'] as bool;
        final exitCode = msg['exitCode'] as int? ?? 0;
        final stdout = msg['stdout'] as String? ?? '';
        final stderr = msg['stderr'] as String? ?? '';
        final error = msg['error'] as String?;
        final completer = _terminalCommandCompleters.remove(requestId);
        if (completer != null) {
          if (success) {
            completer.complete({
              'exitCode': exitCode,
              'stdout': stdout,
              'stderr': stderr,
            });
          } else {
            completer.completeError(Exception(error ?? 'Failed to execute terminal command'));
          }
        }

      case 'usb_eject_response':
        final requestId = msg['requestId'] as String;
        final success = msg['success'] as bool;
        final error = msg['error'] as String?;
        final completer = _usbEjectCompleters.remove(requestId);
        if (completer != null) {
          if (success) {
            completer.complete(true);
          } else {
            completer.completeError(Exception(error ?? 'Eject failed'));
          }
        }

      case 'usb_share_response':
        final requestId = msg['requestId'] as String;
        final success = msg['success'] as bool;
        final error = msg['error'] as String?;
        final completer = _usbShareCompleters.remove(requestId);
        if (completer != null) {
          if (success) {
            completer.complete(true);
          } else {
            completer.completeError(Exception(error ?? 'Share failed'));
          }
        }

      case 'usb_unshare_response':
        final requestId = msg['requestId'] as String;
        final success = msg['success'] as bool;
        final error = msg['error'] as String?;
        final completer = _usbUnshareCompleters.remove(requestId);
        if (completer != null) {
          if (success) {
            completer.complete(true);
          } else {
            completer.completeError(Exception(error ?? 'Unshare failed'));
          }
        }

      case 'usb_bind_response':
        final requestId = msg['requestId'] as String;
        final success = msg['success'] as bool;
        final error = msg['error'] as String?;
        final completer = _usbBindCompleters.remove(requestId);
        if (completer != null) {
          if (success) {
            completer.complete(true);
          } else {
            completer.completeError(Exception(error ?? 'USBIP Bind failed'));
          }
        }

      case 'usb_unbind_response':
        final requestId = msg['requestId'] as String;
        final success = msg['success'] as bool;
        final error = msg['error'] as String?;
        final completer = _usbUnbindCompleters.remove(requestId);
        if (completer != null) {
          if (success) {
            completer.complete(true);
          } else {
            completer.completeError(Exception(error ?? 'USBIP Unbind failed'));
          }
        }

      case 'install_usbip_response':
        final installRequestId = msg['requestId'] as String;
        final installSuccess = msg['success'] as bool;
        final installError = msg['error'] as String?;
        final installCompleter = _installRemoteUsbipCompleters.remove(installRequestId);
        if (installCompleter != null) {
          if (installSuccess) {
            installCompleter.complete(true);
          } else {
            installCompleter.completeError(Exception(installError ?? 'Remote USBIP installation failed'));
          }
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
    if (Platform.isAndroid) return;
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
    if (Platform.isAndroid) {
      FlutterForegroundTask.sendDataToTask({
        'action': 'send_text',
        'text': text,
      });
    } else {
      try {
        _ws?.sink.add(text);
      } catch (_) {}
    }
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

    // Clean up device explorer state
    for (final completer in _deviceListCompleters.values) {
      completer.completeError(Exception('Disconnected'));
    }
    _deviceListCompleters.clear();
    for (final completer in _printJobCompleters.values) {
      completer.completeError(Exception('Disconnected'));
    }
    _printJobCompleters.clear();
    for (final completer in _terminalCommandCompleters.values) {
      completer.completeError(Exception('Disconnected'));
    }
    _terminalCommandCompleters.clear();

    // Clean up USB control completers
    for (final completer in _usbEjectCompleters.values) {
      completer.completeError(Exception('Disconnected'));
    }
    _usbEjectCompleters.clear();
    for (final completer in _usbShareCompleters.values) {
      completer.completeError(Exception('Disconnected'));
    }
    _usbShareCompleters.clear();
    for (final completer in _usbUnshareCompleters.values) {
      completer.completeError(Exception('Disconnected'));
    }
    _usbUnshareCompleters.clear();
    for (final completer in _usbBindCompleters.values) {
      completer.completeError(Exception('Disconnected'));
    }
    _usbBindCompleters.clear();
    for (final completer in _usbUnbindCompleters.values) {
      completer.completeError(Exception('Disconnected'));
    }
    _usbUnbindCompleters.clear();
    for (final completer in _installRemoteUsbipCompleters.values) {
      completer.completeError(Exception('Disconnected'));
    }
    _installRemoteUsbipCompleters.clear();
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

  // ── Remote Device Operations ────────────────────────────────────────────────

  Future<Map<String, dynamic>> fetchRemoteDevices() async {
    if (!isConnected) throw Exception('Not connected to relay');
    final requestId = _uuid.v4();
    final completer = Completer<Map<String, List<Map<String, dynamic>>>>();
    _deviceListCompleters[requestId] = completer;

    _send(jsonEncode({
      'type': 'device_list_request',
      'requestId': requestId,
    }));

    return completer.future;
  }

  Future<void> triggerRemotePrint(String remoteFilePath, String printerName, {bool deleteAfter = false}) async {
    if (!isConnected) throw Exception('Not connected to relay');
    final requestId = _uuid.v4();
    final completer = Completer<void>();
    _printJobCompleters[requestId] = completer;

    _send(jsonEncode({
      'type': 'print_job_request',
      'requestId': requestId,
      'filePath': remoteFilePath,
      'printerName': printerName,
      'deleteAfter': deleteAfter,
    }));

    return completer.future;
  }

  // ── Remote Terminal Operations ──────────────────────────────────────────────

  Future<Map<String, dynamic>> executeRemoteCommand(String command, String cwd) async {
    if (!isConnected) throw Exception('Not connected to relay');
    final requestId = _uuid.v4();
    final completer = Completer<Map<String, dynamic>>();
    _terminalCommandCompleters[requestId] = completer;

    _send(jsonEncode({
      'type': 'terminal_command_request',
      'requestId': requestId,
      'command': command,
      'cwd': cwd,
    }));

    return completer.future;
  }

  Future<bool> ejectRemoteUsbDrive(String driveLetter) async {
    if (!isConnected) throw Exception('Not connected to relay');
    final requestId = _uuid.v4();
    final completer = Completer<bool>();
    _usbEjectCompleters[requestId] = completer;
    _send(jsonEncode({
      'type': 'usb_eject_request',
      'requestId': requestId,
      'driveLetter': driveLetter,
    }));
    return completer.future;
  }

  Future<bool> shareRemoteUsbDrive(String drivePath, String shareName) async {
    if (!isConnected) throw Exception('Not connected to relay');
    final requestId = _uuid.v4();
    final completer = Completer<bool>();
    _usbShareCompleters[requestId] = completer;
    _send(jsonEncode({
      'type': 'usb_share_request',
      'requestId': requestId,
      'drivePath': drivePath,
      'shareName': shareName,
    }));
    return completer.future;
  }

  Future<bool> unshareRemoteUsbDrive(String shareName) async {
    if (!isConnected) throw Exception('Not connected to relay');
    final requestId = _uuid.v4();
    final completer = Completer<bool>();
    _usbUnshareCompleters[requestId] = completer;
    _send(jsonEncode({
      'type': 'usb_unshare_request',
      'requestId': requestId,
      'shareName': shareName,
    }));
    return completer.future;
  }

  // ── Remote USBIP Bind / Unbind ─────────────────────────────────────────────

  Future<bool> bindRemoteUsbDevice(String busId) async {
    if (!isConnected) throw Exception('Not connected to relay');
    final requestId = _uuid.v4();
    final completer = Completer<bool>();
    _usbBindCompleters[requestId] = completer;
    _send(jsonEncode({
      'type': 'usb_bind_request',
      'requestId': requestId,
      'busId': busId,
    }));
    return completer.future;
  }

  Future<bool> unbindRemoteUsbDevice(String busId) async {
    if (!isConnected) throw Exception('Not connected to relay');
    final requestId = _uuid.v4();
    final completer = Completer<bool>();
    _usbUnbindCompleters[requestId] = completer;
    _send(jsonEncode({
      'type': 'usb_unbind_request',
      'requestId': requestId,
      'busId': busId,
    }));
    return completer.future;
  }

  /// Send install request to the remote agent to install USBIP tools.
  Future<bool> installRemoteUsbip() async {
    if (!isConnected) throw Exception('Not connected to relay');
    final requestId = _uuid.v4();
    final completer = Completer<bool>();
    _installRemoteUsbipCompleters[requestId] = completer;
    _send(jsonEncode({
      'type': 'install_usbip_request',
      'requestId': requestId,
    }));
    return completer.future;
  }

  // ── Local Client USBIP Commands ────────────────────────────────────────────

  /// Find the usbip executable — check PATH first, then default install location.
  static Future<String> findLocalUsbipExecutable() async {
    if (!Platform.isWindows) return 'usbip';
    try {
      final res = await Process.run('where', ['usbip']);
      if (res.exitCode == 0 && res.stdout.toString().trim().isNotEmpty) {
        return 'usbip';
      }
    } catch (_) {}
    const defaultPath = 'C:\\Program Files\\usbipd-win\\usbip.exe';
    if (File(defaultPath).existsSync()) {
      return defaultPath;
    }
    return '';
  }

  /// Check if usbip client is installed on the local machine.
  Future<bool> isLocalUsbipInstalled() async {
    if (Platform.isLinux) {
      try {
        final res = await Process.run('which', ['usbip']);
        return res.exitCode == 0;
      } catch (_) {
        return false;
      }
    }
    final exe = await findLocalUsbipExecutable();
    return exe.isNotEmpty;
  }

  /// Install usbip client on the local machine (Windows via winget, Linux via apt).
  Future<bool> installLocalUsbip() async {
    if (Platform.isWindows) {
      final result = await Process.run('powershell', [
        '-Command',
        "Start-Process powershell -ArgumentList '-Command winget install OUST.Usbipd-Win --silent --accept-source-agreements --accept-package-agreements' -Verb RunAs"
      ]);
      return result.exitCode == 0;
    } else if (Platform.isLinux) {
      final result = await Process.run('sudo', ['apt-get', 'install', '-y', 'usbip']);
      return result.exitCode == 0;
    }
    return false;
  }

  Future<bool> attachLocalUsbDevice(String busId) async {
    try {
      final exe = await findLocalUsbipExecutable();
      final usbipPath = exe.isNotEmpty ? exe : 'usbip';
      final result = await Process.run(usbipPath, ['attach', '-r', '127.0.0.1', '-b', busId]);
      return result.exitCode == 0;
    } catch (_) {}
    return false;
  }

  Future<bool> detachLocalUsbDevice(String portIndex) async {
    try {
      final exe = await findLocalUsbipExecutable();
      final usbipPath = exe.isNotEmpty ? exe : 'usbip';
      final result = await Process.run(usbipPath, ['detach', '-p', portIndex]);
      return result.exitCode == 0;
    } catch (_) {}
    return false;
  }

  Future<List<Map<String, String>>> getLocalAttachedUsbDevices() async {
    final list = <Map<String, String>>[];
    try {
      final exe = await findLocalUsbipExecutable();
      final usbipPath = exe.isNotEmpty ? exe : 'usbip';
      final result = await Process.run(usbipPath, ['port']);
      if (result.exitCode == 0) {
        final lines = LineSplitter.split(result.stdout.toString());
        String? currentPort;
        for (final line in lines) {
          if (line.startsWith('Port ')) {
            final match = RegExp(r'^Port (\d+):').firstMatch(line);
            if (match != null) {
              currentPort = match.group(1);
            }
          } else if (line.contains('127.0.0.1') && currentPort != null) {
            // e.g. "127.0.0.1 (1-1)"
            final match = RegExp(r'\(([^)]+)\)').firstMatch(line);
            if (match != null) {
              list.add({
                'port': currentPort,
                'busId': match.group(1)!,
              });
            }
            currentPort = null;
          }
        }
      }
    } catch (_) {}
    return list;
  }

  @override
  void dispose() {
    if (Platform.isAndroid) {
      FlutterForegroundTask.removeTaskDataCallback(_onReceiveTaskData);
    }
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
