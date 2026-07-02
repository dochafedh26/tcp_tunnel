import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/tunnel_service.dart';

class TerminalScreen extends StatefulWidget {
  final String initialCwd;

  const TerminalScreen({super.key, required this.initialCwd});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  final List<_TerminalLine> _history = [];
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();
  
  late String _currentCwd;
  bool _executing = false;

  @override
  void initState() {
    super.initState();
    _currentCwd = widget.initialCwd;
    _history.add(_TerminalLine(
      text: 'TCP Tunnel Remote Shell\nType any system command and press Enter to execute on the agent machine.',
      type: _LineType.info,
    ));
    WidgetsBinding.instance.addPostFrameCallback((_) {
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

    _inputController.clear();
    setState(() {
      _executing = true;
      _history.add(_TerminalLine(
        text: cmd,
        type: _LineType.command,
        cwd: _currentCwd,
      ));
    });
    
    // Defer scrolling so history gets rendered first
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

    try {
      final service = context.read<TunnelService>();
      
      // Specially intercept "cd" command to change working directory client-side!
      if (cmd.startsWith('cd ') || cmd == 'cd') {
        final pathArg = cmd.length > 3 ? cmd.substring(3).trim() : '';
        if (pathArg.isEmpty) {
          // cd with no args - just report current folder
          setState(() {
            _history.add(_TerminalLine(text: _currentCwd, type: _LineType.stdout));
            _executing = false;
          });
        } else {
          // Resolve remote path changes
          // Request file listing from the new directory to check if it exists
          final testPath = pathArg;
          try {
            await service.fetchRemoteFiles(testPath);
            setState(() {
              _currentCwd = testPath;
              _history.add(_TerminalLine(text: 'Directory changed to: $_currentCwd', type: _LineType.info));
              _executing = false;
            });
          } catch (e) {
            // Check if relative path or drive
            var resolvedPath = _currentCwd;
            if (_currentCwd.contains('\\')) {
              resolvedPath = '$_currentCwd\\$testPath';
            } else {
              resolvedPath = '$_currentCwd/$testPath';
            }
            
            try {
              await service.fetchRemoteFiles(resolvedPath);
              setState(() {
                _currentCwd = resolvedPath;
                _history.add(_TerminalLine(text: 'Directory changed to: $_currentCwd', type: _LineType.info));
                _executing = false;
              });
            } catch (_) {
              setState(() {
                _history.add(_TerminalLine(text: 'Error: Directory not found: $testPath', type: _LineType.stderr));
                _executing = false;
              });
            }
          }
        }
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
        _focusNode.requestFocus();
        return;
      }

      final result = await service.executeRemoteCommand(cmd, _currentCwd);
      final stdoutText = result['stdout'] as String? ?? '';
      final stderrText = result['stderr'] as String? ?? '';
      final exitCode = result['exitCode'] as int? ?? 0;

      setState(() {
        if (stdoutText.isNotEmpty) {
          _history.add(_TerminalLine(text: stdoutText, type: _LineType.stdout));
        }
        if (stderrText.isNotEmpty) {
          _history.add(_TerminalLine(text: stderrText, type: _LineType.stderr));
        }
        if (exitCode != 0) {
          _history.add(_TerminalLine(text: 'Process exited with code $exitCode', type: _LineType.stderr));
        }
        _executing = false;
      });
    } catch (e) {
      setState(() {
        _history.add(_TerminalLine(
          text: e.toString().replaceAll('Exception: ', ''),
          type: _LineType.stderr,
        ));
        _executing = false;
      });
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
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
              setState(() {
                _history.clear();
                _history.add(_TerminalLine(
                  text: 'Console cleared.',
                  type: _LineType.info,
                ));
              });
            },
          ),
        ],
      ),
      body: Column(
        children: [
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
                      ..._history.map((line) => _buildTerminalLine(line)),
                      if (_executing)
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
                  _currentCwd.isEmpty ? '> ' : '${_currentCwd.split(RegExp(r'[\\/]')).lastOrNull ?? _currentCwd}> ',
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
                    onSubmitted: (_) => _executeCommand(),
                    enabled: !_executing,
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
                  onPressed: _executing ? null : _executeCommand,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTerminalLine(_TerminalLine line) {
    switch (line.type) {
      case _LineType.command:
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
      case _LineType.stdout:
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
      case _LineType.stderr:
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
      case _LineType.info:
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

enum _LineType { command, stdout, stderr, info }

class _TerminalLine {
  final String text;
  final _LineType type;
  final String? cwd;

  _TerminalLine({required this.text, required this.type, this.cwd});
}
