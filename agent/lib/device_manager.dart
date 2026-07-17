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
          'Get-CimInstance Win32_LogicalDisk | Where-Object { \$_.DriveType -eq 2 } | Select-Object DeviceID, VolumeName, Size, FreeSpace, FileSystem | ConvertTo-Json'
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
                'size': item['Size'] ?? 0,
                'freeSpace': item['FreeSpace'] ?? 0,
                'fileSystem': item['FileSystem'] ?? '',
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

        // Query usbipd list to match busId and bind status for USBIP on Windows
        try {
          final usbipdExe = await _findUsbipdExecutable();
          if (usbipdExe.isNotEmpty) {
            final usbipResult = await Process.run(usbipdExe, ['list']);
            if (usbipResult.exitCode == 0) {
              final lines = LineSplitter.split(usbipResult.stdout.toString());
              bool startParsing = false;
              for (final line in lines) {
                if (line.contains('BUSID')) {
                  startParsing = true;
                  continue;
                }
                if (!startParsing || line.trim().isEmpty) continue;
                
                final match = RegExp(r'^([^\s]+)\s+([^\s]+)\s+(.+?)\s{2,}([^\s].*)$').firstMatch(line.trim());
                if (match != null) {
                  final busId = match.group(1)!;
                  final vidPid = match.group(2)!;
                  final deviceName = match.group(3)!;
                  final state = match.group(4)!;
                  
                  list.add({
                    'name': deviceName,
                    'id': busId,
                    'status': state.contains('Shared') || state.contains('shared') ? 'Shared' : 'Not Shared',
                    'class': 'USBIP',
                    'busId': busId,
                    'vidPid': vidPid,
                    'usbipState': state,
                  });
                }
              }
            }
          }
        } catch (_) {}
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

        // Query usbip list on Linux
        try {
          final usbipResult = await Process.run('usbip', ['list', '-l']);
          if (usbipResult.exitCode == 0) {
            final lines = LineSplitter.split(usbipResult.stdout.toString());
            String? currentBusId;
            for (final line in lines) {
              if (line.startsWith(' - busid')) {
                final parts = line.split('busid ');
                if (parts.length > 1) {
                  currentBusId = parts[1].split(' (').first.trim();
                }
              } else if (line.startsWith('    ') && currentBusId != null) {
                final deviceName = line.trim();
                list.add({
                  'name': deviceName,
                  'id': currentBusId,
                  'status': 'OK',
                  'class': 'USBIP',
                  'busId': currentBusId,
                });
                currentBusId = null;
              }
            }
          }
        } catch (_) {}
      }
    } catch (_) {}
    return list;
  }

  /// Query all system printers on the Agent.
  static Future<List<Map<String, dynamic>>> getPrinters() async {
    final list = <Map<String, dynamic>>[];
    try {
      if (Platform.isWindows) {
        final Set<String> printerNames = {};
        final Map<String, bool> defaultMap = {};

        // 1. Query Win32_Printer (local user printers)
        final resultWmi = await Process.run('powershell', [
          '-Command',
          'Get-CimInstance Win32_Printer | Select-Object Name, Default | ConvertTo-Json'
        ]);
        if (resultWmi.exitCode == 0 && resultWmi.stdout.toString().trim().isNotEmpty) {
          try {
            final decoded = jsonDecode(resultWmi.stdout.toString());
            void processItem(Map<dynamic, dynamic> item) {
              final name = item['Name'] as String?;
              if (name != null && name.isNotEmpty) {
                printerNames.add(name);
                if (item['Default'] == true) {
                  defaultMap[name] = true;
                }
              }
            }
            if (decoded is List) {
              for (final item in decoded) {
                if (item is Map) processItem(item);
              }
            } else if (decoded is Map) {
              processItem(decoded);
            }
          } catch (_) {}
        }

        // 2. Query HKLM registry (machine-wide system and USB printers)
        final resultReg = await Process.run('powershell', [
          '-Command',
          'Get-ItemProperty -Path "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Print\\Printers\\*" | Select-Object PSChildName | ConvertTo-Json'
        ]);
        if (resultReg.exitCode == 0 && resultReg.stdout.toString().trim().isNotEmpty) {
          try {
            final decoded = jsonDecode(resultReg.stdout.toString());
            void processRegItem(Map<dynamic, dynamic> item) {
              final name = item['PSChildName'] as String?;
              if (name != null && name.isNotEmpty) {
                printerNames.add(name);
              }
            }
            if (decoded is List) {
              for (final item in decoded) {
                if (item is Map) processRegItem(item);
              }
            } else if (decoded is Map) {
              processRegItem(decoded);
            }
          } catch (_) {}
        }

        // 3. Fallback default if none set
        if (defaultMap.isEmpty && printerNames.isNotEmpty) {
          defaultMap[printerNames.first] = true;
        }

        for (final name in printerNames) {
          list.add({
            'name': name,
            'status': 'Idle',
            'isDefault': defaultMap[name] ?? false,
            'type': 'Local',
          });
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

  static String _getEdgePath() {
    final paths = [
      r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
      r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
    ];
    for (final p in paths) {
      if (File(p).existsSync()) {
        return p;
      }
    }
    return 'msedge.exe';
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
          final edgePath = _getEdgePath();
          final result = await Process.run(edgePath, [
            '--headless',
            '--print-to-printer',
            '--printer-name=$printerName',
            filePath,
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
          // Send raw print bytes directly to the printer using Win32 spooler API
          final csharpCode = r'''
using System;
using System.Runtime.InteropServices;
public class RawPrinter {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Ansi)]
    public class DOCINFOA {
        [MarshalAs(UnmanagedType.LPStr)] public string pDocName;
        [MarshalAs(UnmanagedType.LPStr)] public string pOutputFile;
        [MarshalAs(UnmanagedType.LPStr)] public string pDatatype;
    }
    [DllImport("winspool.Drv", EntryPoint="OpenPrinterA", SetLastError=true, CharSet=CharSet.Ansi, ExactSpelling=true, CallingConvention=CallingConvention.StdCall)]
    public static extern bool OpenPrinter([MarshalAs(UnmanagedType.LPStr)] string szPrinter, out IntPtr hPrinter, IntPtr pd);
    [DllImport("winspool.Drv", EntryPoint="ClosePrinter", SetLastError=true, ExactSpelling=true, CallingConvention=CallingConvention.StdCall)]
    public static extern bool ClosePrinter(IntPtr hPrinter);
    [DllImport("winspool.Drv", EntryPoint="StartDocPrinterA", SetLastError=true, CharSet=CharSet.Ansi, ExactSpelling=true, CallingConvention=CallingConvention.StdCall)]
    public static extern uint StartDocPrinter(IntPtr hPrinter, int level, [In, MarshalAs(UnmanagedType.LPStruct)] DOCINFOA di);
    [DllImport("winspool.Drv", EntryPoint="EndDocPrinter", SetLastError=true, ExactSpelling=true, CallingConvention=CallingConvention.StdCall)]
    public static extern bool EndDocPrinter(IntPtr hPrinter);
    [DllImport("winspool.Drv", EntryPoint="StartPagePrinter", SetLastError=true, ExactSpelling=true, CallingConvention=CallingConvention.StdCall)]
    public static extern bool StartPagePrinter(IntPtr hPrinter);
    [DllImport("winspool.Drv", EntryPoint="EndPagePrinter", SetLastError=true, ExactSpelling=true, CallingConvention=CallingConvention.StdCall)]
    public static extern bool EndPagePrinter(IntPtr hPrinter);
    [DllImport("winspool.Drv", EntryPoint="WritePrinter", SetLastError=true, ExactSpelling=true, CallingConvention=CallingConvention.StdCall)]
    public static extern bool WritePrinter(IntPtr hPrinter, IntPtr pBytes, int dwCount, out int dwWritten);
    
    public static bool SendFileToPrinter(string szPrinterName, string szFileName) {
        IntPtr hPrinter = new IntPtr(0);
        DOCINFOA di = new DOCINFOA();
        di.pDocName = "RAW Print Job";
        di.pDatatype = "RAW";
        if (OpenPrinter(szPrinterName, out hPrinter, IntPtr.Zero)) {
            if (StartDocPrinter(hPrinter, 1, di) != 0) {
                if (StartPagePrinter(hPrinter)) {
                    byte[] bytes = System.IO.File.ReadAllBytes(szFileName);
                    IntPtr pUnmanagedBytes = Marshal.AllocCoTaskMem(bytes.Length);
                    Marshal.Copy(bytes, 0, pUnmanagedBytes, bytes.Length);
                    int dwWritten = 0;
                    bool success = WritePrinter(hPrinter, pUnmanagedBytes, bytes.Length, out dwWritten);
                    Marshal.FreeCoTaskMem(pUnmanagedBytes);
                    EndPagePrinter(hPrinter);
                    EndDocPrinter(hPrinter);
                    ClosePrinter(hPrinter);
                    return success;
                }
                EndDocPrinter(hPrinter);
            }
            ClosePrinter(hPrinter);
        }
        return false;
    }
}
''';
          final psCommand = 'Add-Type -TypeDefinition @"\n$csharpCode\n"@; [RawPrinter]::SendFileToPrinter("$printerName", "$filePath")';
          final List<int> utf16Bytes = [];
          for (int i = 0; i < psCommand.length; i++) {
            final codeUnit = psCommand.codeUnitAt(i);
            utf16Bytes.add(codeUnit & 0xFF);
            utf16Bytes.add((codeUnit >> 8) & 0xFF);
          }
          final encodedCommand = base64Encode(utf16Bytes);
          final result = await Process.run('powershell', ['-EncodedCommand', encodedCommand]);
          return result.exitCode == 0 && result.stdout.toString().trim().toLowerCase() == 'true';
        }
      } else if (Platform.isLinux) {
        final result = await Process.run('lp', ['-d', printerName, filePath]);
        return result.exitCode == 0;
      }
    } catch (_) {}
    return false;
  }

  /// Query all serial/COM ports on the Agent machine.
  static Future<List<Map<String, dynamic>>> getSerialPorts() async {
    final list = <Map<String, dynamic>>[];
    try {
      if (Platform.isWindows) {
        final result = await Process.run('powershell', [
          '-Command',
          'Get-CimInstance Win32_SerialPort | Select-Object Name, DeviceID, Description, Status | ConvertTo-Json'
        ]);
        if (result.exitCode == 0 && result.stdout.toString().trim().isNotEmpty) {
          try {
            final decoded = jsonDecode(result.stdout.toString());
            void addItem(Map<dynamic, dynamic> item) {
              list.add({
                'name': item['Name'] ?? item['Description'] ?? 'Unknown COM Port',
                'id': item['DeviceID'] ?? '',
                'description': item['Description'] ?? '',
                'status': item['Status'] ?? 'Unknown',
              });
            }
            if (decoded is List) {
              for (final item in decoded) {
                if (item is Map) addItem(item);
              }
            } else if (decoded is Map) {
              addItem(decoded);
            }
          } catch (_) {}
        }
      } else if (Platform.isLinux) {
        final lsResult = await Process.run('bash', ['-c', 'ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null']);
        if (lsResult.exitCode == 0) {
          final ports = LineSplitter.split(lsResult.stdout.toString()).where((l) => l.trim().isNotEmpty);
          for (final port in ports) {
            list.add({
              'name': port.split('/').last,
              'id': port,
              'description': 'USB Serial Device',
              'status': 'OK',
            });
          }
        }
      }
    } catch (_) {}
    return list;
  }

  /// Safely eject a USB drive by its drive letter (Windows) or mount path (Linux).
  static Future<bool> ejectUsbDrive(String driveLetterOrPath) async {
    try {
      if (Platform.isWindows) {
        final psCommand = '''
\$driveToEject = "${driveLetterOrPath.replaceAll('\\', '').replaceAll(':', '')}"
\$disk = Get-CimInstance -Query "SELECT * FROM Win32_Volume WHERE DriveLetter='\$driveToEject:'" -ErrorAction SilentlyContinue
if (\$disk) {
  \$disk | Invoke-CimMethod -MethodName "DismountVolume" | Out-Null
  Write-Output "OK"
} else {
  \$shell = New-Object -ComObject Shell.Application
  \$ns = \$shell.Namespace(17)
  foreach (\$item in \$ns.Items()) {
    if (\$item.Path -like "\$driveToEject*") {
      \$item.InvokeVerbEx("Eject")
      Write-Output "OK"
      return
    }
  }
  Write-Output "FAIL"
}
''';
        final result = await Process.run('powershell', ['-Command', psCommand]);
        return result.exitCode == 0 && result.stdout.toString().trim() == 'OK';
      } else if (Platform.isLinux) {
        final result = await Process.run('umount', [driveLetterOrPath]);
        return result.exitCode == 0;
      }
    } catch (_) {}
    return false;
  }

  /// Share a USB drive/path as a Windows network share accessible over SMB.
  static Future<bool> shareUsbDrive(String drivePath, String shareName) async {
    try {
      if (Platform.isWindows) {
        await Process.run('powershell', ['-Command', 'Remove-SmbShare -Name "$shareName" -Force -ErrorAction SilentlyContinue']);
        final result = await Process.run('powershell', [
          '-Command',
          'New-SmbShare -Name "$shareName" -Path "$drivePath" -FullAccess "Everyone" -ErrorAction Stop; Write-Output "OK"'
        ]);
        return result.exitCode == 0 && result.stdout.toString().contains('OK');
      }
    } catch (_) {}
    return false;
  }

  /// Remove a Windows network share.
  static Future<bool> removeUsbShare(String shareName) async {
    try {
      if (Platform.isWindows) {
        final result = await Process.run('powershell', [
          '-Command',
          'Remove-SmbShare -Name "$shareName" -Force -ErrorAction Stop; Write-Output "OK"'
        ]);
        return result.exitCode == 0 && result.stdout.toString().contains('OK');
      }
    } catch (_) {}
    return false;
  }

  /// Bind a USB device for USBIP forwarding.
  static Future<bool> bindUsbDevice(String busId) async {
    try {
      if (Platform.isWindows) {
        final exe = await _findUsbipdExecutable();
        final usbipdPath = exe.isNotEmpty ? exe : 'usbipd';
        final result = await Process.run(usbipdPath, ['bind', '--busid', busId, '--force']);
        return result.exitCode == 0;
      } else if (Platform.isLinux) {
        final result = await Process.run('usbip', ['bind', '-b', busId]);
        return result.exitCode == 0;
      }
    } catch (_) {}
    return false;
  }

  /// Unbind a USB device from USBIP forwarding.
  static Future<bool> unbindUsbDevice(String busId) async {
    try {
      if (Platform.isWindows) {
        final exe = await _findUsbipdExecutable();
        final usbipdPath = exe.isNotEmpty ? exe : 'usbipd';
        final result = await Process.run(usbipdPath, ['unbind', '--busid', busId]);
        return result.exitCode == 0;
      } else if (Platform.isLinux) {
        final result = await Process.run('usbip', ['unbind', '-b', busId]);
        return result.exitCode == 0;
      }
    } catch (_) {}
    return false;
  }

  static Future<String> _findUsbipdExecutable() async {
    if (!Platform.isWindows) return 'usbipd';
    try {
      final res = await Process.run('where', ['usbipd']);
      if (res.exitCode == 0 && res.stdout.toString().trim().isNotEmpty) {
        return 'usbipd';
      }
    } catch (_) {}
    final defaultPath = 'C:\\Program Files\\usbipd-win\\usbipd.exe';
    if (File(defaultPath).existsSync()) {
      return defaultPath;
    }
    return '';
  }

  static Future<bool> isUsbipdInstalled() async {
    if (Platform.isLinux) {
      try {
        final res = await Process.run('which', ['usbip']);
        return res.exitCode == 0;
      } catch (_) {
        return false;
      }
    }
    final exe = await _findUsbipdExecutable();
    return exe.isNotEmpty;
  }

  /// Query RDP configuration status on Windows
  static Future<Map<String, dynamic>> getRdpStatus() async {
    if (!Platform.isWindows) {
      return {'supported': false, 'enabled': false, 'running': false};
    }
    try {
      final result = await Process.run('powershell', [
        '-Command',
        'try { \$deny = (Get-ItemProperty -Path "HKLM:\\System\\CurrentControlSet\\Control\\Terminal Server" -Name "fDenyTSConnections" -ErrorAction Stop).fDenyTSConnections; \$running = (Get-Service -Name "TermService" -ErrorAction Stop).Status -eq "Running"; \$singleSession = (Get-ItemProperty -Path "HKLM:\\System\\CurrentControlSet\\Control\\Terminal Server" -Name "fSingleSessionPerUser" -ErrorAction SilentlyContinue).fSingleSessionPerUser; \$concurrent = \$singleSession -eq 0; @{Supported=\$true; Enabled=(\$deny -eq 0); Running=\$running; ConcurrentSessions=\$concurrent} | ConvertTo-Json } catch { @{Supported=\$true; Enabled=\$false; Running=\$false; ConcurrentSessions=\$false; Error=\$_.Exception.Message} | ConvertTo-Json }'
      ]);
      if (result.exitCode == 0 && result.stdout.toString().trim().isNotEmpty) {
        final decoded = jsonDecode(result.stdout.toString());
        return {
          'supported': true,
          'enabled': decoded['Enabled'] == true,
          'running': decoded['Running'] == true,
          'concurrentSessions': decoded['ConcurrentSessions'] == true,
        };
      }
    } catch (_) {}
    return {'supported': true, 'enabled': false, 'running': false, 'concurrentSessions': false};
  }

  /// Automatically configure RDP on Windows (Enable RDP, start service, configure firewall, enable concurrent sessions)
  static Future<bool> configureRdp() async {
    if (!Platform.isWindows) return false;
    try {
      final script = r'''
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -name "fDenyTSConnections" -value 0 -ErrorAction Stop
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -name "fSingleSessionPerUser" -value 0 -ErrorAction SilentlyContinue
Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction Stop
Set-Service -Name "TermService" -StartupType Automatic -Status Running -ErrorAction Stop
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Lsa' -name "LimitBlankPasswordUse" -value 0 -ErrorAction SilentlyContinue
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -name "UserAuthentication" -value 0 -ErrorAction SilentlyContinue
# Fix CredSSP Encryption Oracle Remediation (blocks RDP when NLA is disabled on the client)
New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters' -Force -ErrorAction SilentlyContinue | Out-Null
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters' -name "AllowEncryptionOracle" -value 2 -Type DWord -ErrorAction SilentlyContinue
''';
      final result = await Process.run('powershell', ['-Command', script]);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Check if RDP Wrapper is installed (enables unlimited concurrent sessions on non-Server Windows)
  static Future<bool> isRdpWrapperInstalled() async {
    if (!Platform.isWindows) return false;
    try {
      final result = await Process.run('powershell', [
        '-Command',
        r'if (Test-Path "$env:ProgramFiles\RDP Wrapper\rdpwrap.dll") { $true } else { $false }'
      ]);
      return result.exitCode == 0 && result.stdout.toString().trim() == 'True';
    } catch (_) {
      return false;
    }
  }

  /// Install RDP Wrapper to enable unlimited concurrent RDP sessions
  static Future<bool> installRdpWrapper() async {
    if (!Platform.isWindows) return false;
    try {
      // Download latest RDP Wrapper
      var result = await Process.run('powershell', [
        '-Command',
        r'Invoke-WebRequest -Uri "https://github.com/stascorp/rdpwrap/releases/download/v1.6.2/RDPWrap-v1.6.2.zip" -OutFile "$env:TEMP\rdpwrap.zip" -UseBasicParsing'
      ]);
      if (result.exitCode != 0) return false;

      // Extract
      result = await Process.run('powershell', [
        '-Command',
        r'Expand-Archive -Path "$env:TEMP\rdpwrap.zip" -DestinationPath "$env:TEMP\rdpwrap" -Force'
      ]);
      if (result.exitCode != 0) return false;

      // Install
      result = await Process.run('powershell', [
        '-Command',
        r'Start-Process -FilePath "$env:TEMP\rdpwrap\install.bat" -Verb RunAs -Wait'
      ]);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// List active RDP sessions on the remote machine
  static Future<List<Map<String, dynamic>>> getRdpSessions() async {
    if (!Platform.isWindows) return [];
    try {
      final result = await Process.run('powershell', [
        '-Command',
        r'query session | Select-Object -Skip 1 | ForEach-Object { $parts = $_ -split "\s+"; if ($parts.Length -ge 4) { [PSCustomObject]@{SessionName=$parts[0]; Username=$parts[1]; ID=$parts[2]; State=$parts[3]} } } | ConvertTo-Json'
      ]);
      if (result.exitCode == 0 && result.stdout.toString().trim().isNotEmpty) {
        final decoded = jsonDecode(result.stdout.toString());
        if (decoded is List) {
          return decoded.cast<Map<String, dynamic>>();
        } else if (decoded is Map) {
          return [decoded.cast<String, dynamic>()];
        }
      }
    } catch (_) {}
    return [];
  }
}

