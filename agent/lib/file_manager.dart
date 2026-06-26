import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;

class PathAccessException implements Exception {
  final String message;
  PathAccessException(this.message);
  @override
  String toString() => 'PathAccessException: $message';
}

/// Helper that manages local files and directories across the entire filesystem (AnyDesk-style).
class FileManager {
  final String rootPath;

  // Active file write handles for uploads
  final Map<String, RandomAccessFile> _activeWrites = {};

  FileManager(String root) : rootPath = p.canonicalize(p.absolute(root)) {
    // Ensure the root folder exists
    final dir = Directory(rootPath);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
  }

  /// Resolves the absolute path across drives and directories.
  String _safeResolve(String requestedPath) {
    if (requestedPath.trim().isEmpty) {
      return rootPath;
    }

    var fullPath = p.normalize(requestedPath);
    
    // On Windows, append trailing slash if the user requested a raw drive letter (e.g. "D:")
    if (Platform.isWindows && RegExp(r'^[a-zA-Z]:$').hasMatch(fullPath)) {
      fullPath += '/';
    }

    return p.canonicalize(fullPath);
  }

  /// Lists contents of a directory. Returns drive letters if requestedPath is empty on Windows.
  List<Map<String, dynamic>> listDirectory(String requestedPath) {
    if (requestedPath.trim().isEmpty) {
      if (Platform.isWindows) {
        final drives = <Map<String, dynamic>>[];
        for (var charCode = 65; charCode <= 90; charCode++) {
          final driveLetter = String.fromCharCode(charCode);
          try {
            final dir = Directory('$driveLetter:\\');
            if (dir.existsSync()) {
              drives.add({
                'name': 'Local Disk ($driveLetter:)',
                'path': '$driveLetter:/',
                'isDir': true,
                'size': 0,
                'modified': DateTime.now().millisecondsSinceEpoch,
              });
            }
          } catch (_) {}
        }
        return drives;
      } else {
        // Linux/macOS start at root
        requestedPath = '/';
      }
    }

    final safePath = _safeResolve(requestedPath);
    final dir = Directory(safePath);
    if (!dir.existsSync()) {
      throw PathAccessException('Directory does not exist: $requestedPath');
    }

    final items = <Map<String, dynamic>>[];
    try {
      for (final entity in dir.listSync()) {
        try {
          final stat = entity.statSync();
          items.add({
            'name': p.basename(entity.path),
            'path': entity.path.replaceAll('\\', '/'),
            'isDir': entity is Directory,
            'size': stat.size,
            'modified': stat.modified.millisecondsSinceEpoch,
          });
        } catch (_) {
          // Skip files/directories we don't have read/stat permissions for (e.g., System Volume Information)
        }
      }
    } catch (e) {
      throw PathAccessException('Failed to list directory: $e');
    }

    // Sort: directories first, then alphabetically
    items.sort((a, b) {
      if (a['isDir'] as bool != b['isDir'] as bool) {
        return (a['isDir'] as bool) ? -1 : 1;
      }
      return (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase());
    });

    return items;
  }

  /// Read a file in chunks and stream it
  Stream<List<int>> readFile(String requestedPath, {int chunkSize = 64 * 1024}) async* {
    final safePath = _safeResolve(requestedPath);
    final file = File(safePath);
    if (!file.existsSync()) {
      throw PathAccessException('File does not exist: $requestedPath');
    }

    final openFile = await file.open();
    try {
      final fileLength = await openFile.length();
      int bytesRead = 0;
      while (bytesRead < fileLength) {
        final remaining = fileLength - bytesRead;
        final toRead = remaining < chunkSize ? remaining : chunkSize;
        final buffer = await openFile.read(toRead);
        bytesRead += toRead;
        yield buffer;
      }
    } finally {
      await openFile.close();
    }
  }

  /// Write a chunk of a file during an upload
  Future<void> writeFileChunk(String requestId, String requestedPath, List<int> chunk, bool isLast) async {
    final safePath = _safeResolve(requestedPath);

    RandomAccessFile? raf = _activeWrites[requestId];
    if (raf == null) {
      final file = File(safePath);
      // Ensure parent directory exists
      final parentDir = Directory(p.dirname(safePath));
      if (!parentDir.existsSync()) {
        await parentDir.create(recursive: true);
      }
      raf = await file.open(mode: FileMode.write);
      _activeWrites[requestId] = raf;
    }

    await raf.writeFrom(chunk);

    if (isLast) {
      await raf.close();
      _activeWrites.remove(requestId);
    }
  }

  /// Cancels an active file write and closes the handle
  void cancelWrite(String requestId) {
    final raf = _activeWrites.remove(requestId);
    if (raf != null) {
      raf.close().catchError((_) => null);
    }
  }

  /// Creates a directory
  void createDirectory(String requestedPath) {
    final safePath = _safeResolve(requestedPath);
    final dir = Directory(safePath);
    if (dir.existsSync()) {
      throw PathAccessException('Directory already exists.');
    }
    dir.createSync(recursive: true);
  }

  /// Deletes a file or directory
  void deleteEntity(String requestedPath) {
    final safePath = _safeResolve(requestedPath);

    if (FileSystemEntity.isDirectorySync(safePath)) {
      Directory(safePath).deleteSync(recursive: true);
    } else if (FileSystemEntity.isFileSync(safePath)) {
      File(safePath).deleteSync();
    } else {
      throw PathAccessException('Target does not exist.');
    }
  }
}
