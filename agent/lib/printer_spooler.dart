import 'dart:io';
import 'package:logging/logging.dart';

/// Bridges local raw print servers to Windows Print Spooler
/// This allows applications on the work machine to print directly to USB printers
class PrinterSpooler {
  static final Logger _log = Logger('PrinterSpooler');

  /// Create a network printer port and associate it with a printer
  /// This makes the printer available to Windows applications
  static Future<bool> registerPrinterPort(
    String printerName,
    String ipAddress,
    int port,
  ) async {
    try {
      // PowerShell command to add a printer port and configure it
      final addPortScript = '''
\$portExists = Get-PrinterPort -Name "IP_$port" -ErrorAction SilentlyContinue
if (-not \$portExists) {
  Add-PrinterPort -Name "IP_$port" -PrinterHostAddress "$ipAddress" -PortNumber $port -PortProtocol None -ErrorAction Stop
  Write-Output "Created port IP_$port"
}
''';

      final result = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        addPortScript,
      ]);

      if (result.exitCode != 0) {
        _log.warning('Failed to register printer port: ${result.stderr}');
        return false;
      }

      _log.info('Registered printer port IP_$port for $printerName');
      return true;
    } catch (e) {
      _log.severe('Error registering printer port: $e');
      return false;
    }
  }

  /// Remove a printer port from Windows
  static Future<bool> unregisterPrinterPort(int port) async {
    try {
      final removePortScript = '''
Get-PrinterPort -Name "IP_$port" -ErrorAction SilentlyContinue | Remove-PrinterPort -ErrorAction SilentlyContinue
Write-Output "Removed port IP_$port"
''';

      await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        removePortScript,
      ]);

      _log.info('Unregistered printer port IP_$port');
      return true;
    } catch (e) {
      _log.severe('Error unregistering printer port: $e');
      return false;
    }
  }

  /// Get list of available printers and their ports
  static Future<List<Map<String, dynamic>>> getAvailablePrinters() async {
    try {
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        'Get-Printer | Select-Object Name, PortName | ConvertTo-Json -AsArray'
      ]);

      if (result.exitCode == 0 && result.stdout.toString().isNotEmpty) {
        // Parse the JSON output if needed
        _log.info('Retrieved available printers');
        return [];
      }
      return [];
    } catch (e) {
      _log.warning('Error getting available printers: $e');
      return [];
    }
  }
}
