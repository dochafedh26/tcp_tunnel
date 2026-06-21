import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'protocol.dart';

/// Manages the agent's WebSocket connection to the relay server and
/// forwards TCP traffic between the relay and local work resources.
class AgentService {
  final String relayUrl;
  final String token;

  final Logger _log = Logger('AgentService');

  WebSocketChannel? _channel;
  bool _running = false;

  /// Active TCP sockets keyed by channelId.
  final Map<String, Socket> _sockets = {};

  // ── Stats ─────────────────────────────────────────────────────────────────
  int bytesReceived = 0;
  int bytesSent = 0;
  int get activeChannels => _sockets.length;

  AgentService({required this.relayUrl, required this.token});

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Start the agent with automatic reconnection.
  Future<void> start() async {
    _running = true;
    while (_running) {
      try {
        await _connect();
      } catch (e, st) {
        _log.severe('Connection error', e, st);
      }
      if (_running) {
        _log.info('Reconnecting in 5 seconds...');
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
  }

  // ── Connection ────────────────────────────────────────────────────────────

  Future<void> _connect() async {
    _log.info('Connecting to relay at $relayUrl ...');
    _channel = IOWebSocketChannel.connect(Uri.parse(relayUrl));

    // Send auth immediately
    _channel!.sink.add(Protocol.authMessage(token, 'agent'));
    _log.info('Auth message sent');

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

      default:
        _log.fine('Unhandled message type: $type');
    }
  }

  void _handleDataFrame(List<int> frame) {
    try {
      final (:channelId, :data) = Protocol.decodeDataFrame(frame);
      final socket = _sockets[channelId];
      if (socket != null) {
        socket.add(data);
        bytesSent += data.length;
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
      _log.warning('Cannot connect to $host:$port — ${e.message}');
      _channel?.sink.add(Protocol.errorMessage(channelId, e.message));
    } catch (e) {
      _log.warning('Error opening channel $channelId: $e');
      _channel?.sink.add(Protocol.errorMessage(channelId, e.toString()));
    }
  }

  void _closeChannel(String channelId, {required bool notify}) {
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
  }
}
