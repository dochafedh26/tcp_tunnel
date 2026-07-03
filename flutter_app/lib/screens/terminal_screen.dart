import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/tunnel_service.dart';
import '../services/terminal_service.dart';

class TerminalScreen extends StatefulWidget {
  final String? initialCwd;

  const TerminalScreen({super.key, this.initialCwd});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();

  TerminalSession? _lastSession;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final service = context.read<TerminalService>();
      if (widget.initialCwd != null && service.activeSession != null) {
        service.setCwd(service.activeSession!.id, widget.initialCwd!);
      }
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _executeCommand() async {
    final cmd = _inputController.text.trim();
    if (cmd.isEmpty) return;

    final service = context.read<TunnelService>();
    final terminalService = context.read<TerminalService>();
    final session = terminalService.activeSession;
    if (session == null) return;

    final sessionId = session.id;

    _inputController.clear();
    session.inputBuffer = '';

    terminalService.addLine(sessionId, TerminalLine(
      text: cmd,
      type: TerminalLineType.command,
      cwd: session.currentCwd,
    ));
    terminalService.setExecuting(sessionId, true);
    
    // Defer scrolling so history gets rendered first
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

    try {
      // Specially intercept "cd" command to change working directory client-side!
      if (cmd.startsWith('cd ') || cmd == 'cd') {
        final pathArg = cmd.length > 3 ? cmd.substring(3).trim() : '';
        if (pathArg.isEmpty) {
          terminalService.addLine(sessionId, TerminalLine(text: session.currentCwd, type: TerminalLineType.stdout));
          terminalService.setExecuting(sessionId, false);
        } else {
          final testPath = pathArg;
          try {
            await service.fetchRemoteFiles(testPath);
            terminalService.setCwd(sessionId, testPath);
            terminalService.addLine(sessionId, TerminalLine(text: 'Directory changed to: $testPath', type: TerminalLineType.info));
            terminalService.setExecuting(sessionId, false);
          } catch (e) {
            // Check if relative path or drive
            var resolvedPath = session.currentCwd;
            if (session.currentCwd.contains('\\')) {
              resolvedPath = '${session.currentCwd}\\$testPath';
            } else {
              resolvedPath = '${session.currentCwd}/$testPath';
            }
            
            try {
              await service.fetchRemoteFiles(resolvedPath);
              terminalService.setCwd(sessionId, resolvedPath);
              terminalService.addLine(sessionId, TerminalLine(text: 'Directory changed to: $resolvedPath', type: TerminalLineType.info));
              terminalService.setExecuting(sessionId, false);
            } catch (_) {
              terminalService.addLine(sessionId, TerminalLine(text: 'Error: Directory not found: $testPath', type: TerminalLineType.stderr));
              terminalService.setExecuting(sessionId, false);
            }
          }
        }
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
        _focusNode.requestFocus();
        return;
      }

      final result = await service.executeRemoteCommand(cmd, session.currentCwd);
      final stdoutText = result['stdout'] as String? ?? '';
      final stderrText = result['stderr'] as String? ?? '';
      final exitCode = result['exitCode'] as int? ?? 0;

      if (stdoutText.isNotEmpty) {
        terminalService.addLine(sessionId, TerminalLine(text: stdoutText, type: TerminalLineType.stdout));
      }
      if (stderrText.isNotEmpty) {
        terminalService.addLine(sessionId, TerminalLine(text: stderrText, type: TerminalLineType.stderr));
      }
      if (exitCode != 0) {
        terminalService.addLine(sessionId, TerminalLine(text: 'Process exited with code $exitCode', type: TerminalLineType.stderr));
      }
      terminalService.setExecuting(sessionId, false);
    } catch (e) {
      terminalService.addLine(sessionId, TerminalLine(
        text: e.toString().replaceAll('Exception: ', ''),
        type: TerminalLineType.stderr,
      ));
      terminalService.setExecuting(sessionId, false);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    _focusNode.requestFocus();
  }

  Widget _buildTabBar(TerminalService service) {
    return Container(
      height: 40,
      color: const Color(0xFF0F1320),
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: service.sessions.length,
              itemBuilder: (context, index) {
                final session = service.sessions[index];
                final isActive = index == service.activeSessionIndex;
                return GestureDetector(
                  onTap: () => service.selectSession(index),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      color: isActive ? const Color(0xFF05070D) : const Color(0xFF0F1320),
                      border: Border(
                        bottom: BorderSide(
                          color: isActive ? const Color(0xFF00BFA5) : Colors.transparent,
                          width: 2,
                        ),
                        right: const BorderSide(color: Color(0xFF1E2638), width: 1),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.terminal_rounded,
                          size: 14,
                          color: isActive ? const Color(0xFF00BFA5) : const Color(0xFF8892A4),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          session.name,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                            color: isActive ? Colors.white : const Color(0xFF8892A4),
                          ),
                        ),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: () {
                            service.closeSession(index);
                          },
                          child: Icon(
                            Icons.close_rounded,
                            size: 14,
                            color: isActive ? const Color(0xFF00BFA5) : const Color(0xFF4A5568),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add_rounded, color: Color(0xFF00BFA5), size: 20),
            tooltip: 'New Terminal',
            onPressed: () => service.createNewSession(),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final terminalService = context.watch<TerminalService>();
    final session = terminalService.activeSession;

    if (session == null) {
      return const Scaffold(
        body: Center(child: Text('No active terminal sessions')),
      );
    }

    if (session != _lastSession) {
      if (_lastSession != null) {
        _lastSession!.inputBuffer = _inputController.text;
      }
      _inputController.text = session.inputBuffer;
      _lastSession = session;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom();
        _focusNode.requestFocus();
      });
    }

    return Scaffold(
      backgroundColor: const Color(0xFF070A13),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F1320),
        elevation: 0,
        title: const Row(
          children: [
            Icon(Icons.terminal_rounded, color: Color(0xFF00BFA5), size: 20),
            SizedBox(width: 10),
            Text('Remote Terminal', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined, color: Color(0xFF8892A4)),
            tooltip: 'Clear Console',
            onPressed: () {
              terminalService.clearSession(terminalService.activeSessionIndex);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          _buildTabBar(terminalService),
          Expanded(
            child: GestureDetector(
              onTap: () => _focusNode.requestFocus(),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12.0),
                decoration: const BoxDecoration(
                  color: Color(0xFF05070D),
                ),
                child: SingleChildScrollView(
                  controller: _scrollController,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ...session.history.map((line) => _buildTerminalLine(line)),
                      if (session.executing)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8.0),
                          child: Row(
                            children: [
                              const SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Color(0xFF00BFA5),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                'Running...',
                                style: TextStyle(
                                  fontFamily: 'Courier',
                                  fontSize: 13,
                                  color: const Color(0xFF00BFA5).withValues(alpha: 0.7),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Container(
            decoration: const BoxDecoration(
              color: Color(0xFF0F1320),
              border: Border(top: BorderSide(color: Color(0xFF1E2638), width: 1)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
            child: Row(
              children: [
                Text(
                  session.currentCwd.isEmpty ? '> ' : '${session.currentCwd.split(RegExp(r'[\\/]')).lastOrNull ?? session.currentCwd}> ',
                  style: const TextStyle(
                    fontFamily: 'Courier',
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF00BFA5),
                    fontSize: 14,
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: _inputController,
                    focusNode: _focusNode,
                    onChanged: (val) {
                      session.inputBuffer = val;
                    },
                    onSubmitted: (_) => _executeCommand(),
                    enabled: !session.executing,
                    style: const TextStyle(
                      fontFamily: 'Courier',
                      color: Colors.white,
                      fontSize: 14,
                    ),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                      hintText: 'Enter command...',
                      hintStyle: TextStyle(
                        fontFamily: 'Courier',
                        color: Color(0xFF4A5568),
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send_rounded, color: Color(0xFF00BFA5), size: 20),
                  onPressed: session.executing ? null : _executeCommand,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTerminalLine(TerminalLine line) {
    switch (line.type) {
      case TerminalLineType.command:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4.0),
          child: RichText(
            text: TextSpan(
              style: const TextStyle(fontFamily: 'Courier', fontSize: 13),
              children: [
                TextSpan(
                  text: '${line.cwd ?? ''}> ',
                  style: const TextStyle(color: Color(0xFF00E5FF), fontWeight: FontWeight.bold),
                ),
                TextSpan(
                  text: line.text,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        );
      case TerminalLineType.stdout:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2.0),
          child: SelectableText(
            line.text,
            style: const TextStyle(
              fontFamily: 'Courier',
              color: Color(0xFFE2E8F0),
              fontSize: 13,
              height: 1.2,
            ),
          ),
        );
      case TerminalLineType.stderr:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2.0),
          child: SelectableText(
            line.text,
            style: const TextStyle(
              fontFamily: 'Courier',
              color: Colors.redAccent,
              fontSize: 13,
              height: 1.2,
            ),
          ),
        );
      case TerminalLineType.info:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6.0),
          child: Text(
            line.text,
            style: const TextStyle(
              fontFamily: 'Courier',
              color: Color(0xFF00BFA5),
              fontSize: 13,
              height: 1.3,
            ),
          ),
        );
    }
  }
}
