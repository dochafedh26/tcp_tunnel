import 'dart:convert';
import 'dart:io';

class AgentUpdater {
  static const String currentVersion = '1.0.60';
  static const String repoOwner = 'dochafedh26';
  static const String repoName = 'tcp_tunnel';

  /// Checks for updates. If a new version exists, downloads and replaces the binary.
  static Future<void> checkForUpdates([String? githubToken]) async {
    final client = HttpClient();
    client.userAgent = 'TCP-Tunnel-Agent';

    final githubToken = Platform.environment['GITHUB_TOKEN'] ?? Platform.environment['GITHUB_PAT'];

    try {
      final uri = Uri.parse('https://api.github.com/repos/$repoOwner/$repoName/releases/latest');
      final request = await client.getUrl(uri);
      if (githubToken != null && githubToken.isNotEmpty) {
        request.headers.add('Authorization', 'token $githubToken');
      }
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
        final asset = assets.firstWhere(
          (a) {
            final String name = a['name'] as String? ?? '';
            if (Platform.isWindows) {
              return name == 'agent-windows.exe' || (name.startsWith('agent_windows_') && name.endsWith('.exe'));
            } else {
              return name == 'agent-linux' || (name.startsWith('agent_linux_') && !name.endsWith('.exe'));
            }
          },
          orElse: () => null,
        );

        if (asset != null) {
          final String downloadUrl = asset['browser_download_url'];
          final int? assetId = asset['id'] as int?;
          await _performBinarySwap(downloadUrl, assetId, githubToken, client);
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

  static Future<void> _performBinarySwap(String downloadUrl, int? assetId, String? githubToken, HttpClient client) async {
    final currentExecutable = Platform.resolvedExecutable;
    
    // If running in development (via dart run), do not replace dart executable itself!
    if (currentExecutable.endsWith('dart') || currentExecutable.endsWith('dart.exe')) {
      stdout.writeln('Running in development mode (source code). Skipping auto-update binary swap.');
      return;
    }

    final tempFilePath = '$currentExecutable.tmp';

    Uri downloadUri;
    Map<String, String> headers = {};
    
    if (githubToken != null && githubToken.isNotEmpty && assetId != null) {
      downloadUri = Uri.parse('https://api.github.com/repos/$repoOwner/$repoName/releases/assets/$assetId');
      headers['Authorization'] = 'token $githubToken';
      headers['Accept'] = 'application/octet-stream';
      stdout.writeln('Downloading update from private GitHub asset...');
    } else {
      downloadUri = Uri.parse(downloadUrl);
      stdout.writeln('Downloading update from $downloadUrl...');
    }

    // Download asset to a temporary file, handling redirects manually to avoid forwarding token to S3
    var redirectCount = 0;
    var currentUri = downloadUri;
    HttpClientResponse? response;
    
    while (true) {
      final request = await client.getUrl(currentUri);
      request.followRedirects = false; // Handle manually
      
      if (currentUri.host == 'api.github.com') {
        headers.forEach((key, value) {
          request.headers.add(key, value);
        });
      }
      
      response = await request.close();
      
      if (response.statusCode >= 300 && response.statusCode < 400) {
        final location = response.headers.value('location');
        if (location != null && redirectCount < 5) {
          redirectCount++;
          currentUri = Uri.parse(location);
          continue;
        }
      }
      break;
    }

    if (response.statusCode != 200) {
      throw Exception('Failed to download update, status code: ${response.statusCode}');
    }
    
    final tempFile = File(tempFilePath);
    final fileSink = tempFile.openWrite();
    await response.pipe(fileSink);
    await fileSink.close();

    stdout.writeln('Download completed. Swapping binaries...');

    if (Platform.isWindows) {
      final winswExe = Platform.environment['WINSW_EXECUTABLE'];
      if (winswExe != null && winswExe.isNotEmpty) {
        try {
          stdout.writeln('Running as Windows Service under WinSW. Preparing self-restart...');
          final oldExePath = '$currentExecutable.old';
          final oldExe = File(oldExePath);
          if (oldExe.existsSync()) {
            try {
              oldExe.deleteSync();
            } catch (_) {}
          }
          
          // Rename current running executable (allowed on Windows)
          await File(currentExecutable).rename(oldExePath);
          
          // Rename temp download to original path
          await tempFile.rename(currentExecutable);
          
          stdout.writeln('Swapped binaries. Triggering service restart...');
          await Process.start(winswExe, ['restart!'], mode: ProcessStartMode.detached);
          exit(0);
        } catch (e) {
          stderr.writeln('Error during service update swap: $e. Falling back to batch script.');
        }
      }

      // Windows console mode fallback: write a small batch file, launch it detached, and exit.
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
