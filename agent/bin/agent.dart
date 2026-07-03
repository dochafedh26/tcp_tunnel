import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:logging/logging.dart';
import 'package:tcp_tunnel_agent/agent_service.dart';
import 'package:tcp_tunnel_agent/updater.dart';
import 'package:uuid/uuid.dart';

void main(List<String> arguments) async {
  // ── Logging setup ─────────────────────────────────────────────────────────
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    final time = record.time.toIso8601String();
    final level = record.level.name.padRight(7);
    // ignore: avoid_print
    print('[$time] [$level] ${record.loggerName}: ${record.message}');
    if (record.error != null) {
      // ignore: avoid_print
      print('  ↳ ${record.error}');
    }
  });

  // Clean up any old executable leftover from a previous Windows Service update swap
  try {
    final oldExe = File('${Platform.resolvedExecutable}.old');
    if (oldExe.existsSync()) {
      oldExe.deleteSync();
    }
  } catch (_) {}

  // ── Argument parsing ──────────────────────────────────────────────────────
  final parser = ArgParser()
    ..addOption(
      'relay',
      abbr: 'r',
      help: 'Relay server WebSocket URL (ws:// or wss://)',
      defaultsTo: 'wss://relayserver.medevsync.com',
    )
    ..addOption(
      'token',
      abbr: 't',
      help: 'Authentication token — must match relay server AUTH_TOKEN',
      defaultsTo: 'changeme',
    )
    ..addOption(
      'github-token',
      abbr: 'g',
      help: 'GitHub Personal Access Token for checking updates from private repository',
      defaultsTo: '',
    )
    ..addOption(
      'shared-dir',
      abbr: 's',
      help: 'Directory exposed to remote file explorer requests',
      defaultsTo: '',
    )
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help')
    ..addFlag('install-service', negatable: false, help: 'Install and start the agent as a Windows Service')
    ..addFlag('uninstall-service', negatable: false, help: 'Stop and uninstall the Windows Service');

  // ── Silent Double-Click Windows Service Auto-Installer ──────────────────
  if (Platform.isWindows && arguments.isEmpty) {
    final currentExe = Platform.resolvedExecutable.toLowerCase();
    final targetExe = r'c:\tcp_tunnel_agent\agent.exe'.toLowerCase();
    
    if (currentExe != targetExe) {
      await _handleSilentInstall();
      exit(0);
    }
  }

  ArgResults args;
  try {
    args = parser.parse(arguments);
  } catch (e) {
    stderr.writeln('Error: $e');
    stderr.writeln(parser.usage);
    exit(1);
  }

  if (args['install-service'] as bool) {
    await _handleServiceInstall(arguments);
    exit(0);
  }
  if (args['uninstall-service'] as bool) {
    await _handleServiceUninstall(arguments);
    exit(0);
  }

  if (args['help'] as bool) {
    stdout.writeln('TCP Tunnel Agent v${AgentUpdater.currentVersion}');
    stdout.writeln('═══════════════════════════════════════════════════');
    stdout.writeln('Runs on your WORK machine. Connects OUT to the relay');
    stdout.writeln('server (port 443/wss) and forwards TCP');
    stdout.writeln('traffic to internal work resources on behalf of the');
    stdout.writeln('Flutter client app running at home.');
    stdout.writeln('');
    stdout.writeln('Usage: dart run bin/agent.dart [options]');
    stdout.writeln('       dart compile exe bin/agent.dart -o agent.exe');
    stdout.writeln('');
    stdout.writeln(parser.usage);
    exit(0);
  }

  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final configFile = File('$exeDir/agent_settings.json');
  Map<String, dynamic> configJson = {};
  if (configFile.existsSync()) {
    try {
      final content = configFile.readAsStringSync();
      configJson = jsonDecode(content) as Map<String, dynamic>;
    } catch (e) {
      stderr.writeln('Warning: Failed to read agent_settings.json: $e');
    }
  }

  final relayUrl = args['relay'] as String;
  var token = args['token'] as String;

  if (token == 'changeme') {
    if (configJson.containsKey('token')) {
      token = configJson['token'] as String;
    }

    if (token == 'changeme' || token.trim().isEmpty) {
      token = const Uuid().v4();
      configJson['token'] = token;
      try {
        configFile.writeAsStringSync(jsonEncode(configJson));
        stdout.writeln('Generated new persistent token in agent_settings.json');
      } catch (e) {
        stderr.writeln('Warning: Failed to save agent_settings.json: $e');
      }
    }
  }

  // Resolve GitHub Personal Access Token (PAT)
  final cliGithubToken = args['github-token'] as String;
  var githubToken = cliGithubToken.isNotEmpty
      ? cliGithubToken
      : (Platform.environment['GITHUB_TOKEN'] ?? Platform.environment['GH_TOKEN'] ?? '');

  if (githubToken.isEmpty && configJson.containsKey('github_token')) {
    githubToken = configJson['github_token'] as String;
  }

  if (githubToken.isEmpty) {
    githubToken = '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';
  }

  // Persist GitHub token if provided via CLI and it differs from saved settings
  if (cliGithubToken.isNotEmpty && cliGithubToken != configJson['github_token']) {
    configJson['github_token'] = cliGithubToken;
    try {
      configFile.writeAsStringSync(jsonEncode(configJson));
      stdout.writeln('Saved GitHub Personal Access Token to agent_settings.json');
    } catch (e) {
      stderr.writeln('Warning: Failed to save agent_settings.json: $e');
    }
  }

  final sharedDirArg = args['shared-dir'] as String;
  final sharedDir = sharedDirArg.isEmpty ? Directory.current.path : sharedDirArg;

  final hostname = Platform.localHostname;
  stdout.writeln('╔══════════════════════════════════════════════════════════════════╗');
  final title = '                    TCP Tunnel Agent  v${AgentUpdater.currentVersion}';
  stdout.writeln('║${title.padRight(66)}║');
  stdout.writeln('╚══════════════════════════════════════════════════════════════════╝');
  stdout.writeln('  Relay      : $relayUrl');
  stdout.writeln('  Agent Name : $hostname');
  stdout.writeln('  Auth Token : $token');
  stdout.writeln('  Shared Dir : $sharedDir');

  final maskedGithubToken = githubToken.isNotEmpty
      ? (githubToken.length > 8
          ? '${githubToken.substring(0, 4)}...${githubToken.substring(githubToken.length - 4)}'
          : '********')
      : 'Not set';
  stdout.writeln('  GitHub PAT : $maskedGithubToken');

  stdout.writeln('────────────────────────────────────────────────────────────────────');
  stdout.writeln('  👉 To connect from the Flutter app:');
  stdout.writeln('     1. Open Settings -> Add Machine Profile');
  stdout.writeln('     2. Enter Relay URL: $relayUrl');
  stdout.writeln('     3. Enter Auth Token: $token');
  stdout.writeln('     (Or select "$hostname" via "Discover Agents" in settings)');
  stdout.writeln('────────────────────────────────────────────────────────────────────');
  stdout.writeln('Press Ctrl+C to stop.');
  stdout.writeln('');

  // Check for updates before running the agent service
  await AgentUpdater.checkForUpdates(githubToken);

  // ── Start agent ───────────────────────────────────────────────────────────
  final agent = AgentService(
    relayUrl: relayUrl,
    token: token,
    sharedDir: sharedDir,
  );

  // Graceful shutdown on Ctrl+C
  ProcessSignal.sigint.watch().listen((_) async {
    stdout.writeln('\nShutting down agent...');
    agent.stop();
    await Future.delayed(const Duration(milliseconds: 300));
    exit(0);
  });

  await agent.start();
}

Future<void> _handleServiceInstall(List<String> arguments) async {
  if (!Platform.isWindows) {
    stderr.writeln('Error: Windows Service installation is only supported on Windows.');
    exit(1);
  }

  // 1. Check for Admin privileges
  final checkAdmin = await Process.run('powershell', ['-Command', 'net session']);
  if (checkAdmin.exitCode != 0) {
    stdout.writeln('Requesting Administrator privileges to install service...');
    final executable = Platform.resolvedExecutable;
    
    final argsList = List<String>.from(arguments);
    if (!argsList.contains('--install-service')) {
      argsList.add('--install-service');
    }
    final escapedArgs = argsList.map((a) => '"$a"').join(', ');
    
    final result = await Process.run('powershell', [
      '-Command',
      'Start-Process -FilePath "$executable" -ArgumentList $escapedArgs -Verb RunAs'
    ]);
    if (result.exitCode != 0) {
      stderr.writeln('Failed to request elevation: ${result.stderr}');
      exit(1);
    }
    exit(0);
  }

  // 2. Locate WinSW-x64.exe
  final exeFile = File(Platform.resolvedExecutable);
  final exeDir = exeFile.parent.path;
  var winswSrc = File('$exeDir/WinSW-x64.exe');
  if (!winswSrc.existsSync()) {
    winswSrc = File('WinSW-x64.exe');
  }
  
  if (!winswSrc.existsSync()) {
    stderr.writeln('Error: WinSW-x64.exe wrapper not found in executable directory or current directory.');
    exit(1);
  }

  // 3. Copy WinSW-x64.exe to tcp_tunnel_agent_service.exe
  final serviceExe = File('$exeDir/tcp_tunnel_agent_service.exe');
  try {
    if (serviceExe.existsSync()) {
      await Process.run(serviceExe.path, ['stop']);
      await Process.run(serviceExe.path, ['uninstall']);
    }
    await winswSrc.copy(serviceExe.path);
  } catch (e) {
    stderr.writeln('Error copying service wrapper: $e');
    exit(1);
  }

  // 4. Generate XML Configuration
  final serviceArgs = arguments.where((arg) => arg != '--install-service' && arg != '-i').toList();
  var targetExecutable = Platform.resolvedExecutable;
  var targetArgs = serviceArgs;
  
  if (targetExecutable.endsWith('dart.exe') || targetExecutable.endsWith('dart')) {
    final scriptPath = Platform.script.toFilePath();
    targetArgs = [scriptPath, ...targetArgs];
  }

  final xmlContent = '''<service>
  <id>tcp-tunnel-agent</id>
  <name>TCP Tunnel Agent</name>
  <description>Relays TCP connections through the remote WebSocket tunnel</description>
  <executable>$targetExecutable</executable>
  <arguments>${targetArgs.map((a) => '"$a"').join(' ')}</arguments>
  <log mode="roll-by-size">
    <sizeThreshold>10240</sizeThreshold> <!-- 10 MB -->
    <keepFiles>5</keepFiles>
  </log>
  <onfailure action="restart" delay="10 sec"/>
</service>''';

  final serviceXml = File('$exeDir/tcp_tunnel_agent_service.xml');
  try {
    await serviceXml.writeAsString(xmlContent);
  } catch (e) {
    stderr.writeln('Error writing service configuration: $e');
    exit(1);
  }

  // 5. Register and start the service
  stdout.writeln('Installing TCP Tunnel Agent service...');
  final installResult = await Process.run(serviceExe.path, ['install']);
  if (installResult.exitCode != 0) {
    stderr.writeln('Failed to install service: ${installResult.stderr}\n${installResult.stdout}');
    exit(1);
  }

  stdout.writeln('Starting TCP Tunnel Agent service...');
  final startResult = await Process.run(serviceExe.path, ['start']);
  if (startResult.exitCode != 0) {
    stderr.writeln('Failed to start service: ${startResult.stderr}\n${startResult.stdout}');
    exit(1);
  }

  stdout.writeln('====================================================');
  stdout.writeln('Success: TCP Tunnel Agent service installed and started!');
  stdout.writeln('The service will auto-start if the machine restarts.');
  stdout.writeln('====================================================');
}

Future<void> _handleServiceUninstall(List<String> arguments) async {
  if (!Platform.isWindows) {
    stderr.writeln('Error: Windows Service operations are only supported on Windows.');
    exit(1);
  }

  // 1. Check for Admin privileges
  final checkAdmin = await Process.run('powershell', ['-Command', 'net session']);
  if (checkAdmin.exitCode != 0) {
    stdout.writeln('Requesting Administrator privileges to uninstall service...');
    final executable = Platform.resolvedExecutable;
    
    final argsList = List<String>.from(arguments);
    if (!argsList.contains('--uninstall-service')) {
      argsList.add('--uninstall-service');
    }
    final escapedArgs = argsList.map((a) => '"$a"').join(', ');
    
    final result = await Process.run('powershell', [
      '-Command',
      'Start-Process -FilePath "$executable" -ArgumentList $escapedArgs -Verb RunAs'
    ]);
    if (result.exitCode != 0) {
      stderr.writeln('Failed to request elevation: ${result.stderr}');
      exit(1);
    }
    exit(0);
  }

  final exeFile = File(Platform.resolvedExecutable);
  final exeDir = exeFile.parent.path;
  final serviceExe = File('$exeDir/tcp_tunnel_agent_service.exe');
  final serviceXml = File('$exeDir/tcp_tunnel_agent_service.xml');

  if (!serviceExe.existsSync()) {
    stderr.writeln('Error: tcp_tunnel_agent_service.exe not found. Is the service installed?');
    exit(1);
  }

  stdout.writeln('Stopping TCP Tunnel Agent service...');
  await Process.run(serviceExe.path, ['stop']);

  stdout.writeln('Uninstalling TCP Tunnel Agent service...');
  final uninstallResult = await Process.run(serviceExe.path, ['uninstall']);
  if (uninstallResult.exitCode != 0) {
    stderr.writeln('Warning: Failed to uninstall service entry: ${uninstallResult.stderr}');
  }

  // Clean up files
  try {
    if (serviceExe.existsSync()) await serviceExe.delete();
    if (serviceXml.existsSync()) await serviceXml.delete();
    stdout.writeln('Service files cleaned up successfully.');
  } catch (e) {
    stderr.writeln('Warning: Failed to delete service files: $e');
  }

  stdout.writeln('====================================================');
  stdout.writeln('Success: TCP Tunnel Agent service uninstalled.');
  stdout.writeln('====================================================');
}

Future<void> _handleSilentInstall() async {
  // 1. Check for Admin privileges
  final checkAdmin = await Process.run('powershell', ['-Command', 'net session']);
  if (checkAdmin.exitCode != 0) {
    stdout.writeln('Requesting Administrator privileges to silently install service...');
    final executable = Platform.resolvedExecutable;
    
    // Relaunch ourselves with elevation and no arguments
    final result = await Process.run('powershell', [
      '-Command',
      'Start-Process -FilePath "$executable" -Verb RunAs'
    ]);
    if (result.exitCode != 0) {
      stderr.writeln('Failed to request elevation: ${result.stderr}');
      exit(1);
    }
    exit(0);
  }

  // 2. We are admin. Create folder C:\tcp_tunnel_agent
  final targetDir = Directory(r'C:\tcp_tunnel_agent');
  if (!targetDir.existsSync()) {
    targetDir.createSync(recursive: true);
  }

  // 3. Locate or download WinSW-x64.exe
  final exeFile = File(Platform.resolvedExecutable);
  final exeDir = exeFile.parent.path;
  var winswSrc = File('$exeDir/WinSW-x64.exe');
  if (!winswSrc.existsSync()) {
    winswSrc = File('WinSW-x64.exe');
  }

  final targetAgentExe = File(r'C:\tcp_tunnel_agent\agent.exe');
  final targetWinSW = File(r'C:\tcp_tunnel_agent\WinSW-x64.exe');
  final targetServiceExe = File(r'C:\tcp_tunnel_agent\tcp_tunnel_agent_service.exe');

  if (targetServiceExe.existsSync()) {
    stdout.writeln('Stopping and uninstalling existing service to release file locks...');
    try {
      await Process.run(targetServiceExe.path, ['stop']);
      await Process.run(targetServiceExe.path, ['uninstall']);
      await Future.delayed(const Duration(milliseconds: 1000));
    } catch (e) {
      stderr.writeln('Warning: Failed to stop/uninstall existing service: $e');
    }
  }

  if (!winswSrc.existsSync()) {
    stdout.writeln('WinSW-x64.exe not found locally. Downloading from official releases...');
    try {
      final client = HttpClient();
      final request = await client.getUrl(Uri.parse(
        'https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe'
      ));
      final response = await request.close();
      if (response.statusCode == 200) {
        await response.pipe(targetWinSW.openWrite());
        await targetWinSW.copy(targetServiceExe.path);
        stdout.writeln('WinSW-x64.exe downloaded successfully.');
      } else {
        stderr.writeln('Failed to download WinSW-x64.exe: HTTP ${response.statusCode}');
        exit(1);
      }
    } catch (e) {
      stderr.writeln('Error downloading WinSW-x64.exe: $e');
      exit(1);
    }
  } else {
    try {
      await winswSrc.copy(targetWinSW.path);
      await winswSrc.copy(targetServiceExe.path);
    } catch (e) {
      stderr.writeln('Error copying WinSW files: $e');
      exit(1);
    }
  }

  // 4. Copy agent.exe and handle agent_settings.json / token persistence
  String token = '';
  try {
    await exeFile.copy(targetAgentExe.path);

    final localSettings = File('$exeDir/agent_settings.json');
    final targetSettings = File(r'C:\tcp_tunnel_agent\agent_settings.json');
    
    if (localSettings.existsSync()) {
      await localSettings.copy(targetSettings.path);
      try {
        final content = await targetSettings.readAsString();
        final config = jsonDecode(content) as Map<String, dynamic>;
        token = config['token'] as String? ?? '';
      } catch (_) {}
    } else if (!targetSettings.existsSync()) {
      token = const Uuid().v4();
      final configJson = {'token': token};
      await targetSettings.writeAsString(jsonEncode(configJson));
    } else {
      try {
        final content = await targetSettings.readAsString();
        final config = jsonDecode(content) as Map<String, dynamic>;
        token = config['token'] as String? ?? '';
      } catch (_) {}
    }
    
    if (token.isEmpty) {
      token = const Uuid().v4();
      final configJson = {'token': token};
      await targetSettings.writeAsString(jsonEncode(configJson));
    }
  } catch (e) {
    stderr.writeln('Error copying files or setting up token: $e');
    exit(1);
  }

  // 5. Generate Service XML Configuration
  final xmlContent = '''<service>
  <id>tcp-tunnel-agent</id>
  <name>TCP Tunnel Agent</name>
  <description>Relays TCP connections through the remote WebSocket tunnel</description>
  <executable>C:\\tcp_tunnel_agent\\agent.exe</executable>
  <arguments>--relay wss://relayserver.medevsync.com --token $token</arguments>
  <log mode="roll-by-size">
    <sizeThreshold>10240</sizeThreshold> <!-- 10 MB -->
    <keepFiles>5</keepFiles>
  </log>
  <onfailure action="restart" delay="10 sec"/>
</service>''';

  final serviceXml = File(r'C:\tcp_tunnel_agent\tcp_tunnel_agent_service.xml');
  try {
    await serviceXml.writeAsString(xmlContent);
  } catch (e) {
    stderr.writeln('Error writing service configuration: $e');
    exit(1);
  }

  // 6. Install and start the service
  stdout.writeln('Installing TCP Tunnel Agent service...');
  await Process.run(targetServiceExe.path, ['stop']);
  await Process.run(targetServiceExe.path, ['uninstall']);
  
  final installResult = await Process.run(targetServiceExe.path, ['install']);
  if (installResult.exitCode != 0) {
    stderr.writeln('Failed to install service: ${installResult.stderr}\n${installResult.stdout}');
    exit(1);
  }

  stdout.writeln('Starting TCP Tunnel Agent service...');
  final startResult = await Process.run(targetServiceExe.path, ['start']);
  if (startResult.exitCode != 0) {
    stderr.writeln('Failed to start service: ${startResult.stderr}\n${startResult.stdout}');
    exit(1);
  }

  stdout.writeln('====================================================');
  stdout.writeln('Success: TCP Tunnel Agent service installed and started!');
  stdout.writeln('Installed path: C:\\tcp_tunnel_agent');
  stdout.writeln('====================================================');

  // Copy token to clipboard and show popup dialog with the token!
  try {
    await Process.run('powershell', ['-Command', 'Set-Clipboard -Value "$token"']);
    final msg = 'TCP Tunnel Agent has been successfully installed and started as a Windows Service!\n\n'
        'Your Connection Token: $token\n\n'
        'This token has been copied to your clipboard. Paste it into the client application to connect.';
    await Process.run('powershell', [
      '-Command',
      'Add-Type -AssemblyName PresentationFramework; '
      '[System.Windows.MessageBox]::Show("$msg", "TCP Tunnel Agent Setup", "OK", "Information")'
    ]);
  } catch (_) {}
}
