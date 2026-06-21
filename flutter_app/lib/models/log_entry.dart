/// A single log entry displayed in the Logs screen.
class LogEntry {
  final DateTime timestamp;
  final LogLevel level;
  final String message;

  const LogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
  });
}

enum LogLevel { info, warning, error, success, debug }
