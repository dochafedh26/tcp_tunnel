import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;

class PathAccessException implements Exception {
  final String message;
  PathAccessException(this.message);
  @override
  String toString() => 'PathAccessException: $message';
}

/// Helper that manages local files and directories safely inside a designated root folder.
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

  /// Resolves the absolute path and ensures it's within the rootPath.
  String _safeResolve(String requestedPath) {
    // Treat empty path as root
    if (requestedPath.trim().isEmpty) {
      return rootPath;
    }

    // Normalize path separators and remove redundant parts
    String fullPath = p.normalize(requestedPath);
    if (!p.isAbsolute(fullPath)) {
      fullPath = p.normalize(p.join(rootPath, requestedPath));
    }

    final canonicalPath = p.canonicalize(fullPath);

    // Ensure resolved path starts with the canonical root path
    if (!p.isWithin(rootPath, canonicalPath) && canonicalPath != rootPath) {
      throw PathAccessException('Access denied: Path lies outside the shared root directory.');
    }

    return canonicalPath;
  }

  /// Lists contents of a directory, returning name, relative path, isDir, size, and modified time.
  List<Map<String, dynamic>> listDirectory(String requestedPath) {
    final safePath = _safeResolve(requestedPath);
    final dir = Directory(safePath);
    if (!dir.existsSync()) {
      throw PathAccessException('Directory does not exist: $requestedPath');
    }

    final items = <Map<String, dynamic>>[];
    for (final entity in dir.listSync()) {
      final stat = entity.statSync();
      final relPath = p.relative(entity.path, from: rootPath);
      items.add({
        'name': p.basename(entity.path),
        'path': relPath.replaceAll('\\', '/'),
        'isDir': entity is Directory,
        'size': stat.size,
        'modified': stat.modified.millisecondsSinceEpoch,
      });
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

    // Safety check: do not delete the root directory itself!
    if (safePath == rootPath) {
      throw PathAccessException('Cannot delete the root directory.');
    }

    if (FileSystemEntity.isDirectorySync(safePath)) {
      Directory(safePath).deleteSync(recursive: true);
    } else if (FileSystemEntity.isFileSync(safePath)) {
      File(safePath).deleteSync();
    } else {
      throw PathAccessException('Target does not exist.');
    }
  }
}
