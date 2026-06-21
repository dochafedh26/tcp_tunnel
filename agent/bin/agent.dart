import 'dart:io';

import 'package:args/args.dart';
import 'package:logging/logging.dart';
import 'package:tcp_tunnel_agent/agent_service.dart';

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
      defaultsTo: 'ws://localhost:8080',
    )
    ..addOption(
      'token',
      abbr: 't',
      help: 'Authentication token — must match relay server AUTH_TOKEN',
      defaultsTo: 'changeme',
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
    stdout.writeln('TCP Tunnel Agent v1.0.0');
    stdout.writeln('═══════════════════════════════════════════════════');
    stdout.writeln('Runs on your WORK machine. Connects OUT to the relay');
    stdout.writeln('server (port 443/wss or 8080/ws) and forwards TCP');
    stdout.writeln('traffic to internal work resources on behalf of the');
    stdout.writeln('Flutter client app running at home.');
    stdout.writeln('');
    stdout.writeln('Usage: dart run bin/agent.dart [options]');
    stdout.writeln('       dart compile exe bin/agent.dart -o agent.exe');
    stdout.writeln('');
    stdout.writeln(parser.usage);
    exit(0);
  }

  final relayUrl = args['relay'] as String;
  final token = args['token'] as String;

  // ── Banner ────────────────────────────────────────────────────────────────
  stdout.writeln('╔══════════════════════════════════════════╗');
  stdout.writeln('║       TCP Tunnel Agent  v1.0.0           ║');
  stdout.writeln('╚══════════════════════════════════════════╝');
  stdout.writeln('  Relay  : $relayUrl');
  stdout.writeln('  Token  : ${token.length > 3 ? "${token.substring(0, 3)}***" : "***"}');
  stdout.writeln('');
  stdout.writeln('Press Ctrl+C to stop.');
  stdout.writeln('');

  // ── Start agent ───────────────────────────────────────────────────────────
  final agent = AgentService(relayUrl: relayUrl, token: token);

  // Graceful shutdown on Ctrl+C
  ProcessSignal.sigint.watch().listen((_) async {
    stdout.writeln('\nShutting down agent...');
    agent.stop();
    await Future.delayed(const Duration(milliseconds: 300));
    exit(0);
  });

  await agent.start();
}
