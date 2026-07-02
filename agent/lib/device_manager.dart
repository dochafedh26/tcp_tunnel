import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Manages USB devices, printers, and document printing on the Agent machine.
class DeviceManager {
  DeviceManager._();

  /// Query all connected USB devices and removable storage drives.
  static Future<List<Map<String, dynamic>>> getUsbDevices() async {
    final list = <Map<String, dynamic>>[];
    try {
      if (Platform.isWindows) {
        // Query WMI for connected USB PNP Devices
        final result = await Process.run('powershell', [
          '-Command',
          'Get-CimInstance Win32_PnPEntity | Where-Object { \$_.DeviceID -like "USB*" } | Select-Object Name, Description, DeviceID, Status | ConvertTo-Json'
        ]);
        if (result.exitCode == 0 && result.stdout.toString().trim().isNotEmpty) {
          final decoded = jsonDecode(result.stdout.toString());
          if (decoded is List) {
            for (final item in decoded) {
              list.add({
                'name': item['Name'] ?? item['Description'] ?? 'Unknown USB Device',
                'id': item['DeviceID'] ?? '',
                'status': item['Status'] ?? 'Unknown',
                'class': 'USB',
              });
            }
          } else if (decoded is Map) {
            list.add({
              'name': decoded['Name'] ?? decoded['Description'] ?? 'Unknown USB Device',
              'id': decoded['DeviceID'] ?? '',
              'status': decoded['Status'] ?? 'Unknown',
              'class': 'USB',
            });
          }
        }

        // Also query USB Removable Storage Drives to see if we can expose their mount points
        final storageResult = await Process.run('powershell', [
          '-Command',
          'Get-CimInstance Win32_LogicalDisk | Where-Object { \$_.DriveType -eq 2 } | Select-Object DeviceID, VolumeName | ConvertTo-Json'
        ]);
        if (storageResult.exitCode == 0 && storageResult.stdout.toString().trim().isNotEmpty) {
          final decodedStorage = jsonDecode(storageResult.stdout.toString());
          void addStorageItem(Map<dynamic, dynamic> item) {
            final driveLetter = item['DeviceID'] as String?;
            final volumeName = item['VolumeName'] as String? ?? 'Removable Drive';
            if (driveLetter != null) {
              list.add({
                'name': '$volumeName ($driveLetter)',
                'id': driveLetter,
                'status': 'OK',
                'class': 'Storage',
                'driveLetter': driveLetter,
              });
            }
          }
          if (decodedStorage is List) {
            for (final item in decodedStorage) {
              if (item is Map) addStorageItem(item);
            }
          } else if (decodedStorage is Map) {
            addStorageItem(decodedStorage);
          }
        }
      } else if (Platform.isLinux) {
        // Parse lsusb
        final result = await Process.run('lsusb', []);
        if (result.exitCode == 0) {
          final lines = LineSplitter.split(result.stdout.toString());
          for (final line in lines) {
            if (line.trim().isEmpty) continue;
            list.add({
              'name': line,
              'id': line.split('ID ').length > 1 ? line.split('ID ')[1] : line,
              'status': 'OK',
              'class': 'USB',
            });
          }
        }
        
        // Query mounted USB storage drives on Linux
        final mountResult = await Process.run('df', ['-h']);
        if (mountResult.exitCode == 0) {
          final lines = LineSplitter.split(mountResult.stdout.toString());
          for (final line in lines) {
            if (line.contains('/media/')) {
              final parts = line.split(RegExp(r'\s+'));
              if (parts.length >= 6) {
                final mountPath = parts[5];
                final driveName = mountPath.split('/').last;
                list.add({
                  'name': '$driveName ($mountPath)',
                  'id': mountPath,
                  'status': 'OK',
                  'class': 'Storage',
                  'driveLetter': mountPath,
                });
              }
            }
          }
        }
      }
    } catch (_) {}
    return list;
  }

  /// Query all system printers on the Agent.
  static Future<List<Map<String, dynamic>>> getPrinters() async {
    final list = <Map<String, dynamic>>[];
    try {
      if (Platform.isWindows) {
        final result = await Process.run('powershell', [
          '-Command',
          'Get-CimInstance Win32_Printer | Select-Object Name, Default, PrinterStatus | ConvertTo-Json'
        ]);
        if (result.exitCode == 0 && result.stdout.toString().trim().isNotEmpty) {
          final decoded = jsonDecode(result.stdout.toString());
          void addPrinterItem(Map<dynamic, dynamic> item) {
            list.add({
              'name': item['Name'] ?? 'Unknown Printer',
              'status': item['PrinterStatus'] == 3 ? 'Idle' : 'Offline',
              'isDefault': item['Default'] ?? false,
              'type': 'Local',
            });
          }
          if (decoded is List) {
            for (final item in decoded) {
              if (item is Map) addPrinterItem(item);
            }
          } else if (decoded is Map) {
            addPrinterItem(decoded);
          }
        }
      } else if (Platform.isLinux) {
        final result = await Process.run('lpstat', ['-p', '-d']);
        if (result.exitCode == 0) {
          final lines = LineSplitter.split(result.stdout.toString());
          String? defaultPrinter;
          for (final line in lines) {
            if (line.startsWith('system default destination:')) {
              defaultPrinter = line.split(': ').last.trim();
            }
          }
          for (final line in lines) {
            if (line.startsWith('printer ')) {
              final parts = line.split(' ');
              if (parts.length >= 2) {
                final name = parts[1];
                list.add({
                  'name': name,
                  'status': line.contains('is idle') ? 'Idle' : 'Offline',
                  'isDefault': name == defaultPrinter,
                  'type': 'Local',
                });
              }
            }
          }
        }
      }
    } catch (_) {}
    return list;
  }

  /// Print a local file to a selected printer.
  static Future<bool> printFile(String filePath, String printerName) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return false;

      if (Platform.isWindows) {
        final ext = filePath.split('.').last.toLowerCase();
        if (ext == 'pdf' || ext == 'html' || ext == 'htm') {
          // Print silently via Microsoft Edge
          final result = await Process.run('powershell', [
            '-Command',
            'Start-Process "msedge.exe" -ArgumentList "--print-to-printer", "--print-to-printer-name=\\"$printerName\\"", "\\"$filePath\\"" -Wait -NoNewWindow'
          ]);
          return result.exitCode == 0;
        } else if (ext == 'txt' || ext == 'log') {
          // Print text file directly to spooler
          final result = await Process.run('powershell', [
            '-Command',
            'Get-Content -Path "$filePath" | Out-Printer -Name "$printerName"'
          ]);
          return result.exitCode == 0;
        } else {
          // Generic PrintTo verb
          final result = await Process.run('powershell', [
            '-Command',
            'Start-Process -FilePath "$filePath" -Verb PrintTo -ArgumentList "$printerName" -Wait -NoNewWindow'
          ]);
          return result.exitCode == 0;
        }
      } else if (Platform.isLinux) {
        final result = await Process.run('lp', ['-d', printerName, filePath]);
        return result.exitCode == 0;
      }
    } catch (_) {}
    return false;
  }
}
