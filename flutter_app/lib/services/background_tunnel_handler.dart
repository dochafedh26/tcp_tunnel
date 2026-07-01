import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

@pragma('vm:entry-point')
void startBackgroundTunnelCallback() {
  FlutterForegroundTask.setTaskHandler(BackgroundTunnelTaskHandler());
}

class BackgroundTunnelTaskHandler extends TaskHandler {
  WebSocketChannel? _ws;
  StreamSubscription? _wsSub;
  bool _peerConnected = false;
  
  String? _relayUrl;
  String? _token;
  List<dynamic> _tunnelsData = [];
  bool _shouldReconnect = false;
  Timer? _reconnectTimer;
  
  final Map<String, ServerSocket> _servers = {};
  final Map<String, Socket> _localSockets = {};
  final Set<String> _pendingChannels = {};
  
  int _bytesIn = 0;
  int _bytesOut = 0;
  
  static const _uuid = Uuid();
  static const int _dataFrameType = 0x01;
  static const int _headerLength = 37;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _log('info', 'Background tunnel service handler initialized');
  }

  @override
  void onReceiveData(Object data) {
    if (data is Map<String, dynamic>) {
      final action = data['action'] as String?;
      switch (action) {
        case 'connect':
          _relayUrl = data['relayUrl'] as String?;
          _token = data['token'] as String?;
          _tunnelsData = data['tunnels'] as List<dynamic>? ?? [];
          _shouldReconnect = true;
          _connect();
        case 'disconnect':
          _disconnect();
        case 'updateTunnels':
          _tunnelsData = data['tunnels'] as List<dynamic>? ?? [];
          if (_ws != null) {
            _syncTunnelListeners();
          }
        case 'send_text':
          final text = data['text'] as String?;
          if (text != null) {
            _send(text);
          }
      }
    }
  }

  Future<void> _connect() async {
    if (_relayUrl == null || _token == null) return;
    
    await _cleanup();
    _setState('connecting');
    
    var normalizedUrl = _relayUrl!.trim();
    if (!normalizedUrl.startsWith('ws://') && !normalizedUrl.startsWith('wss://')) {
      if (normalizedUrl.startsWith('http://') || normalizedUrl.startsWith('https://')) {
        normalizedUrl = normalizedUrl.replaceFirst('http', 'ws');
      } else {
        normalizedUrl = 'wss://$normalizedUrl';
      }
    }
    
    _log('info', 'Connecting to relay at $normalizedUrl...');
    
    try {
      _ws = IOWebSocketChannel.connect(
        Uri.parse(normalizedUrl),
        pingInterval: const Duration(seconds: 20),
      );
      
      _send(jsonEncode({'type': 'auth', 'token': _token, 'role': 'client'}));
      _log('info', 'Auth message sent');
      
      _wsSub = _ws!.stream.listen(
        _handleMessage,
        onError: (Object err) {
          _log('error', 'WebSocket error: $err');
          _onDisconnected(err.toString());
        },
        onDone: () {
          _log('warning', 'Relay connection closed');
          _onDisconnected(null);
        },
        cancelOnError: true,
      );
    } catch (e) {
      _log('error', 'Failed to connect: $e');
      _setState('error', error: e.toString());
      _onDisconnected(e.toString());
    }
  }

  void _handleMessage(dynamic data) {
    try {
      if (data is String) {
        _handleTextMessage(data);
      } else {
        final bytes = data is Uint8List ? data : Uint8List.fromList(data as List<int>);
        if (bytes.isNotEmpty && bytes[0] == _dataFrameType && bytes.length >= _headerLength) {
          _handleDataFrame(bytes);
        }
      }
    } catch (e) {
      _log('error', 'Error in message handler: $e');
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
        _log('success', 'Authenticated with relay ✓');
        _setState('connected');
        _syncTunnelListeners();
        
      case 'auth_error':
        _log('error', 'Authentication failed: ${msg['message']}');
        _setState('error', error: msg['message'] as String?);
        
      case 'peer_connected':
        _peerConnected = true;
        _log('success', 'Work agent is online — tunnel fully active ✓');
        _notifyStats();
        
      case 'peer_disconnected':
        _peerConnected = false;
        _log('warning', 'Work agent disconnected');
        _notifyStats();
        
      case 'opened':
        final channelId = msg['channelId'] as String;
        _pendingChannels.remove(channelId);
        
      case 'close':
        final channelId = msg['channelId'] as String;
        _closeLocalSocket(channelId);
        
      case 'error':
        final channelId = msg['channelId'] as String;
        _log('error', 'Channel error: ${msg['message']}');
        _closeLocalSocket(channelId);
        
      case 'ping':
        _send(jsonEncode({'type': 'pong'}));
        
      // Forward all file explorer messages back to the main UI isolate to resolve its completers
      case 'file_list_response':
      case 'file_download_chunk':
      case 'file_upload_response':
      case 'file_error':
        try {
          FlutterForegroundTask.sendDataToMain({
            'type': 'file_explorer_response',
            'data': msg,
          });
        } catch (_) {}
    }
  }

  void _handleDataFrame(Uint8List frame) {
    final channelId = ascii.decode(frame.sublist(1, _headerLength));
    final payload = frame.sublist(_headerLength);
    final socket = _localSockets[channelId];
    if (socket != null) {
      socket.add(payload);
      _bytesIn += payload.length;
      _notifyStats();
    }
  }

  void _syncTunnelListeners() {
    // Stop servers that are no longer in the tunnels list or are disabled
    final activeIds = _tunnelsData.map((t) => t['id'] as String).toSet();
    _servers.keys.toList().forEach((id) {
      if (!activeIds.contains(id)) {
        _servers.remove(id)?.close();
      }
    });

    for (final tunnel in _tunnelsData) {
      final id = tunnel['id'] as String;
      final enabled = tunnel['enabled'] as bool? ?? true;
      final name = tunnel['name'] as String? ?? 'Tunnel';
      final localPort = tunnel['localPort'] as int;
      final remoteHost = tunnel['remoteHost'] as String;
      final remotePort = tunnel['remotePort'] as int;

      if (!enabled) {
        _servers.remove(id)?.close();
        continue;
      }

      if (_servers.containsKey(id)) continue;

      _startTunnelListener(id, name, localPort, remoteHost, remotePort);
    }
  }

  Future<void> _startTunnelListener(
    String id,
    String name,
    int localPort,
    String remoteHost,
    int remotePort,
  ) async {
    try {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, localPort);
      _servers[id] = server;
      _log('info', 'Listening on localhost:$localPort → $remoteHost:$remotePort [$name]');

      server.listen((Socket socket) {
        final channelId = _uuid.v4();
        _localSockets[channelId] = socket;
        _log('debug', 'New local connection on $name, channelId=$channelId');

        _send(jsonEncode({
          'type': 'open',
          'channelId': channelId,
          'host': remoteHost,
          'port': remotePort,
        }));
        _pendingChannels.add(channelId);

        socket.listen(
          (Uint8List data) {
            _sendDataFrame(channelId, data);
            _bytesOut += data.length;
            _notifyStats();
          },
          onDone: () {
            _send(jsonEncode({'type': 'close', 'channelId': channelId}));
            _localSockets.remove(channelId);
            _notifyStats();
          },
          onError: (_) {
            _send(jsonEncode({'type': 'close', 'channelId': channelId}));
            _localSockets.remove(channelId)?.destroy();
            _notifyStats();
          },
          cancelOnError: true,
        );
      });
      _notifyStats();
    } catch (e) {
      _log('error', 'Cannot bind port $localPort: $e');
    }
  }

  void _closeLocalSocket(String channelId) {
    _localSockets.remove(channelId)?.destroy();
    _notifyStats();
  }

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

  void _onDisconnected(String? reason) {
    _cleanup();
    _setState('disconnected');
    _peerConnected = false;
    _notifyStats();

    if (_shouldReconnect && _relayUrl != null && _token != null) {
      _log('info', 'Auto-reconnecting in 5 seconds...');
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(const Duration(seconds: 5), () {
        if (_shouldReconnect) {
          _connect();
        }
      });
    }
  }

  Future<void> _cleanup() async {
    _reconnectTimer?.cancel();
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

  Future<void> _disconnect() async {
    _shouldReconnect = false;
    await _cleanup();
    _setState('disconnected');
    _log('info', 'Disconnected');
  }

  void _setState(String state, {String? error}) {
    try {
      FlutterForegroundTask.sendDataToMain({
        'type': 'state',
        'value': state,
        'error': error,
      });
    } catch (_) {}
  }

  void _log(String level, String message) {
    try {
      FlutterForegroundTask.sendDataToMain({
        'type': 'log',
        'level': level,
        'message': message,
      });
    } catch (_) {}
  }

  void _notifyStats() {
    try {
      FlutterForegroundTask.sendDataToMain({
        'type': 'stats',
        'bytesIn': _bytesIn,
        'bytesOut': _bytesOut,
        'activeChannels': _localSockets.length,
        'peerConnected': _peerConnected,
      });
    } catch (_) {}
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // No-op
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    await _cleanup();
  }
}
