import 'package:flutter/material.dart';

enum TerminalLineType { command, stdout, stderr, info }

class TerminalLine {
  final String text;
  final TerminalLineType type;
  final String? cwd;

  TerminalLine({required this.text, required this.type, this.cwd});
}

class TerminalSession {
  final String id;
  String name;
  final List<TerminalLine> history = [];
  String currentCwd;
  bool executing = false;
  String inputBuffer = '';

  TerminalSession({
    required this.id,
    required this.name,
    this.currentCwd = '.',
  }) {
    history.add(TerminalLine(
      text: 'TCP Tunnel Remote Shell\nType any system command and press Enter to execute on the agent machine.',
      type: TerminalLineType.info,
    ));
  }
}

class TerminalService extends ChangeNotifier {
  final List<TerminalSession> _sessions = [];
  int _activeSessionIndex = 0;
  int _sessionCounter = 0;

  TerminalService() {
    createNewSession();
  }

  List<TerminalSession> get sessions => _sessions;
  int get activeSessionIndex => _activeSessionIndex;

  TerminalSession? get activeSession {
    if (_sessions.isEmpty) return null;
    if (_activeSessionIndex < 0 || _activeSessionIndex >= _sessions.length) {
      _activeSessionIndex = 0;
    }
    return _sessions[_activeSessionIndex];
  }

  void createNewSession({String? initialCwd}) {
    _sessionCounter++;
    final session = TerminalSession(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: 'Terminal $_sessionCounter',
      currentCwd: initialCwd ?? '.',
    );
    _sessions.add(session);
    _activeSessionIndex = _sessions.length - 1;
    notifyListeners();
  }

  void selectSession(int index) {
    if (index >= 0 && index < _sessions.length) {
      _activeSessionIndex = index;
      notifyListeners();
    }
  }

  void closeSession(int index) {
    if (_sessions.length <= 1) {
      // Don't close the last session, just clear it
      clearSession(0);
      return;
    }

    _sessions.removeAt(index);
    if (_activeSessionIndex >= _sessions.length) {
      _activeSessionIndex = _sessions.length - 1;
    }
    notifyListeners();
  }

  void clearSession(int index) {
    if (index >= 0 && index < _sessions.length) {
      _sessions[index].history.clear();
      _sessions[index].history.add(TerminalLine(
        text: 'Console cleared.',
        type: TerminalLineType.info,
      ));
      notifyListeners();
    }
  }

  void addLine(String sessionId, TerminalLine line) {
    final session = _sessions.firstWhere((s) => s.id == sessionId, orElse: () => _sessions.first);
    session.history.add(line);
    notifyListeners();
  }

  void setExecuting(String sessionId, bool executing) {
    final session = _sessions.firstWhere((s) => s.id == sessionId, orElse: () => _sessions.first);
    session.executing = executing;
    notifyListeners();
  }

  void setCwd(String sessionId, String cwd) {
    final session = _sessions.firstWhere((s) => s.id == sessionId, orElse: () => _sessions.first);
    session.currentCwd = cwd;
    notifyListeners();
  }
}
