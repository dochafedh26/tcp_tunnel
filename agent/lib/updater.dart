import 'dart:convert';
import 'dart:io';

class AgentUpdater {
  static const String currentVersion = '1.0.6';
  static const String repoOwner = 'dochafedh26';
  static const String repoName = 'tcp_tunnel';

  /// Checks for updates. If a new version exists, downloads and replaces the binary.
  static Future<void> checkForUpdates() async {
    final client = HttpClient();
    client.userAgent = 'TCP-Tunnel-Agent';

    try {
      final uri = Uri.parse('https://api.github.com/repos/$repoOwner/$repoName/releases/latest');
      final request = await client.getUrl(uri);
      final response = await request.close();

      if (response.statusCode != 200) {
        return;
      }

      final body = await response.transform(utf8.decoder).join();
      final Map<String, dynamic> json = jsonDecode(body);

      final String latestVersion = (json['tag_name'] as String).replaceFirst('v', '');

      if (_isNewerVersion(currentVersion, latestVersion)) {
        stdout.writeln('==================================================');
        stdout.writeln('A new update (v$latestVersion) is available!');
        final assets = json['assets'] as List<dynamic>;
        
        // Find the right asset based on Operating System
        String targetAssetName = Platform.isWindows ? 'agent-windows.exe' : 'agent-linux';
        final asset = assets.firstWhere(
          (a) => a['name'] == targetAssetName,
          orElse: () => null,
        );

        if (asset != null) {
          final String downloadUrl = asset['browser_download_url'];
          await _performBinarySwap(downloadUrl, client);
        } else {
          stdout.writeln('No suitable binary release found for this OS.');
        }
      } else {
        stdout.writeln('Agent is up to date (v$currentVersion).');
      }
    } catch (e) {
      stdout.writeln('Error checking for updates: $e');
    } finally {
      client.close();
    }
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

  static Future<void> _performBinarySwap(String downloadUrl, HttpClient client) async {
    stdout.writeln('Downloading update from $downloadUrl...');
    final currentExecutable = Platform.resolvedExecutable;
    
    // If running in development (via dart run), do not replace dart executable itself!
    if (currentExecutable.endsWith('dart') || currentExecutable.endsWith('dart.exe')) {
      stdout.writeln('Running in development mode (source code). Skipping auto-update binary swap.');
      return;
    }

    final tempFilePath = '$currentExecutable.tmp';

    // 1. Download asset to a temporary file
    final request = await client.getUrl(Uri.parse(downloadUrl));
    final response = await request.close();
    
    final tempFile = File(tempFilePath);
    final fileSink = tempFile.openWrite();
    await response.pipe(fileSink);
    await fileSink.close();

    stdout.writeln('Download completed. Swapping binaries...');

    if (Platform.isWindows) {
      // Windows locks running files. We write a small batch file, launch it detached, and exit.
      final updaterScriptPath = '${Directory.systemTemp.path}\\update_agent.bat';
      final batchScript = '''
@echo off
timeout /t 2 /nobreak > NUL
del "$currentExecutable"
move "$tempFilePath" "$currentExecutable"
start "" "$currentExecutable"
del "%~f0"
''';
      await File(updaterScriptPath).writeAsString(batchScript);
      await Process.start('cmd.exe', ['/c', updaterScriptPath], mode: ProcessStartMode.detached);
      stdout.writeln('Restarting agent...');
      exit(0);
    } else {
      // Unix/Linux: We can overwrite the running executable directly, set execute bits, and restart.
      await tempFile.rename(currentExecutable);
      await Process.run('chmod', ['+x', currentExecutable]);
      
      stdout.writeln('Update applied! Restarting...');
      await Process.start(currentExecutable, [], mode: ProcessStartMode.detached);
      exit(0);
    }
  }
}
