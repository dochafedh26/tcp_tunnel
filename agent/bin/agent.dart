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

  // ── Argument parsing ──────────────────────────────────────────────────────
  final parser = ArgParser()
    ..addOption(
      'relay',
      abbr: 'r',
      help: 'Relay server WebSocket URL (ws:// or wss://)',
      defaultsTo: 'wss://tcptunnel-production.up.railway.app',
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
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help');

  ArgResults args;
  try {
    args = parser.parse(arguments);
  } catch (e) {
    stderr.writeln('Error: $e');
    stderr.writeln(parser.usage);
    exit(1);
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

  final configFile = File('agent_settings.json');
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
