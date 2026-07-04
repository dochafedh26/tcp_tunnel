import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:open_file/open_file.dart';

class UpdaterService {
  static const String currentVersion = '1.0.56';
  static const String repoOwner = 'dochafedh26';
  static const String repoName = 'tcp_tunnel';

  /// Queries the latest GitHub release metadata.
  /// Returns the JSON data if an update is available, or null otherwise.
  static Future<Map<String, dynamic>?> checkLatestRelease([String? githubToken]) async {
    try {
      final headers = {'User-Agent': 'TCP-Tunnel-App'};
      if (githubToken != null && githubToken.isNotEmpty) {
        headers['Authorization'] = 'token $githubToken';
      }
      final response = await http.get(
        Uri.parse('https://api.github.com/repos/$repoOwner/$repoName/releases/latest'),
        headers: headers,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final String latestVersion = (data['tag_name'] as String).replaceFirst('v', '');
        
        if (_isNewerVersion(currentVersion, latestVersion)) {
          return data;
        }
      }
    } catch (e) {
      // Quietly log or ignore check failures (e.g. offline)
      debugPrint('Update check failed: $e');
    }
    return null;
  }

  static bool _isNewerVersion(String current, String latest) {
    try {
      List<int> currParts = current.split('.').map(int.parse).toList();
      List<int> lateParts = latest.split('.').map(int.parse).toList();
      for (int i = 0; i < 3; i++) {
        if (lateParts[i] > currParts[i]) return true;
        if (lateParts[i] < currParts[i]) return false;
      }
    } catch (_) {}
    return false;
  }

  /// Downloads the APK and triggers the Android Installer
  static Future<void> downloadAndInstallApk(
    String url, 
    Function(double) onProgress,
    Function(String) onError,
    Function() onDone,
  ) async {
    if (!Platform.isAndroid) {
      onError('Auto-updating is only supported on Android. For other platforms, download the release manually.');
      return;
    }

    try {
      final response = await http.Client().send(http.Request('GET', Uri.parse(url)));
      final int totalBytes = response.contentLength ?? 0;
      int downloadedBytes = 0;

      final directory = await getTemporaryDirectory();
      final apkPath = '${directory.path}/tcp_tunnel_update.apk';
      final file = File(apkPath);
      
      // Delete old temp file if exists
      if (await file.exists()) {
        await file.delete();
      }
      
      final sink = file.openWrite();

      await response.stream.listen(
        (chunk) {
          sink.add(chunk);
          downloadedBytes += chunk.length;
          if (totalBytes > 0) {
            onProgress(downloadedBytes / totalBytes);
          }
        },
        onDone: () async {
          await sink.close();
          onDone();
          final result = await OpenFile.open(apkPath, type: 'application/vnd.android.package-archive');
          if (result.type != ResultType.done) {
            onError('Could not open installer: ${result.message}');
          }
        },
        onError: (e) async {
          await sink.close();
          onError('Error during download: $e');
        },
        cancelOnError: true,
      ).asFuture();
    } catch (e) {
      onError('Download failed: $e');
    }
  }
}
