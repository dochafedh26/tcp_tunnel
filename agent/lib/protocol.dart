import 'dart:convert';
import 'dart:typed_data';

/// Wire protocol shared between the Flutter client app and the Dart agent.
///
/// ## Binary data frame layout
/// ```
/// [0x01 (1 byte)] [channelId ASCII UUID (36 bytes)] [TCP payload (N bytes)]
/// ```
/// Total header = 37 bytes.
///
/// ## Control messages (JSON text frames)
/// See [authMessage], [openedMessage], [closeMessage], [errorMessage].
class Protocol {
  Protocol._();

  static const int dataFrameType = 0x01;
  static const int channelIdLength = 36; // UUID v4 ASCII length
  static const int headerLength = 37; // 1 + 36

  // ── Control message builders ──────────────────────────────────────────────

  static String authMessage(String token, String role, {String? name}) =>
      jsonEncode({
        'type': 'auth',
        'token': token,
        'role': role,
        if (name != null) 'name': name,
      });

  static String openMessage(String channelId, String host, int port) =>
      jsonEncode({'type': 'open', 'channelId': channelId, 'host': host, 'port': port});

  static String openedMessage(String channelId) =>
      jsonEncode({'type': 'opened', 'channelId': channelId});

  static String closeMessage(String channelId) =>
      jsonEncode({'type': 'close', 'channelId': channelId});

  static String errorMessage(String channelId, String message) =>
      jsonEncode({'type': 'error', 'channelId': channelId, 'message': message});

  static String pingMessage() => jsonEncode({'type': 'ping'});
  static String pongMessage() => jsonEncode({'type': 'pong'});

  static String fileListResponse(String requestId, String path, bool success, List<Map<String, dynamic>> items, {String? error}) =>
      jsonEncode({
        'type': 'file_list_response',
        'requestId': requestId,
        'path': path,
        'success': success,
        'items': items,
        'error': error,
      });

  static String fileDownloadChunk(String requestId, int chunkIndex, String base64Data, bool isLast) =>
      jsonEncode({
        'type': 'file_download_chunk',
        'requestId': requestId,
        'chunkIndex': chunkIndex,
        'data': base64Data,
        'isLast': isLast,
      });

  static String fileUploadResponse(String requestId, bool success, {String? error}) =>
      jsonEncode({
        'type': 'file_upload_response',
        'requestId': requestId,
        'success': success,
        'error': error,
      });

  static String fileError(String requestId, String message) =>
      jsonEncode({'type': 'file_error', 'requestId': requestId, 'message': message});

  static String deviceListResponse(String requestId, bool success, List<Map<String, dynamic>> usbDevices, List<Map<String, dynamic>> printers, {String? error}) =>
      jsonEncode({
        'type': 'device_list_response',
        'requestId': requestId,
        'success': success,
        'usbDevices': usbDevices,
        'printers': printers,
        'error': error,
      });

  static String printJobResponse(String requestId, bool success, {String? error}) =>
      jsonEncode({
        'type': 'print_job_response',
        'requestId': requestId,
        'success': success,
        'error': error,
      });

  static String terminalCommandResponse(String requestId, bool success, int exitCode, String stdout, String stderr, {String? error}) =>
      jsonEncode({
        'type': 'terminal_command_response',
        'requestId': requestId,
        'success': success,
        'exitCode': exitCode,
        'stdout': stdout,
        'stderr': stderr,
        'error': error,
      });

  static String deviceListResponseV2(
    String requestId,
    bool success,
    List<Map<String, dynamic>> usbDevices,
    List<Map<String, dynamic>> printers,
    List<Map<String, dynamic>> comPorts, {
    bool usbipdMissing = false,
    Map<String, dynamic>? rdpStatus,
    String? error,
  }) =>
      jsonEncode({
        'type': 'device_list_response',
        'requestId': requestId,
        'success': success,
        'usbDevices': usbDevices,
        'printers': printers,
        'comPorts': comPorts,
        'usbipdMissing': usbipdMissing,
        if (rdpStatus != null) 'rdpStatus': rdpStatus,
        'error': error,
      });

  static String usbEjectResponse(String requestId, bool success, {String? error}) =>
      jsonEncode({
        'type': 'usb_eject_response',
        'requestId': requestId,
        'success': success,
        'error': error,
      });

  static String usbShareResponse(String requestId, bool success, String shareName, {String? error}) =>
      jsonEncode({
        'type': 'usb_share_response',
        'requestId': requestId,
        'success': success,
        'shareName': shareName,
        'error': error,
      });

  static String usbUnshareResponse(String requestId, bool success, {String? error}) =>
      jsonEncode({
        'type': 'usb_unshare_response',
        'requestId': requestId,
        'success': success,
        'error': error,
      });

  static String usbBindResponse(String requestId, bool success, {String? error}) =>
      jsonEncode({
        'type': 'usb_bind_response',
        'requestId': requestId,
        'success': success,
        'error': error,
      });

  static String usbUnbindResponse(String requestId, bool success, {String? error}) =>
      jsonEncode({
        'type': 'usb_unbind_response',
        'requestId': requestId,
        'success': success,
        'error': error,
      });

  static String rdpSessionsResponse(String requestId, bool success, List<Map<String, dynamic>> sessions, {String? error}) =>
      jsonEncode({
        'type': 'rdp_sessions_response',
        'requestId': requestId,
        'success': success,
        'sessions': sessions,
        'error': error,
      });

  static String rdpWrapperStatusResponse(String requestId, bool installed) =>
      jsonEncode({
        'type': 'rdp_wrapper_status_response',
        'requestId': requestId,
        'installed': installed,
      });

  static String rdpWrapperInstallResponse(String requestId, bool success, {String? error}) =>
      jsonEncode({
        'type': 'rdp_wrapper_install_response',
        'requestId': requestId,
        'success': success,
        'error': error,
      });

  // ── Binary frame codec ────────────────────────────────────────────────────

  /// Encode a [data] payload into a binary data frame for [channelId].
  static Uint8List encodeDataFrame(String channelId, List<int> data) {
    final channelBytes = ascii.encode(channelId); // always 36 bytes for UUID v4
    assert(channelBytes.length == channelIdLength,
        'channelId must be a 36-char UUID, got ${channelBytes.length} chars');
    final frame = Uint8List(headerLength + data.length);
    frame[0] = dataFrameType;
    frame.setRange(1, headerLength, channelBytes);
    frame.setRange(headerLength, frame.length, data);
    return frame;
  }

  /// Decode a binary data frame into its channelId and payload.
  static ({String channelId, Uint8List data}) decodeDataFrame(List<int> frame) {
    final channelId = ascii.decode(frame.sublist(1, headerLength));
    final data = Uint8List.fromList(frame.sublist(headerLength));
    return (channelId: channelId, data: data);
  }

  /// Returns true if [data] is a binary data frame (starts with [dataFrameType]).
  static bool isDataFrame(dynamic data) {
    if (data is List<int>) {
      return data.length >= headerLength && data[0] == dataFrameType;
    }
    return false;
  }
}
