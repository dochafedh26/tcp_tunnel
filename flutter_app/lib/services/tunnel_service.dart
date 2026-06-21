import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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
    _log(LogLevel.info, 'Connecting to relay at $relayUrl...');

    try {
      _ws = IOWebSocketChannel.connect(Uri.parse(relayUrl));

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
  }

  Future<void> _cleanup() async {
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

  @override
  void dispose() {
    _cleanup();
    super.dispose();
  }
}
