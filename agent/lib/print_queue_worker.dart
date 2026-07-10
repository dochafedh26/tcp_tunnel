import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:logging/logging.dart';

class PrintQueueWorker {
  final String apiBaseUrl;
  final String token;
  final Logger _log = Logger('PrintQueueWorker');
  bool _running = false;
  Timer? _timer;

  PrintQueueWorker({required this.apiBaseUrl, required this.token});

  void start() {
    _running = true;
    _log.info('Starting print queue worker pointing to $apiBaseUrl');
    _poll();
  }

  void stop() {
    _running = false;
    _timer?.cancel();
  }

  Future<void> _poll() async {
    if (!_running) return;

    HttpClient? client;
    try {
      client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);
      
      final url = Uri.parse('$apiBaseUrl/api/print/pending');
      final request = await client.getUrl(url);
      request.headers.set('Authorization', 'Bearer $token');
      
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      
      if (response.statusCode == 200) {
        final List<dynamic> jobs = jsonDecode(body);
        for (final job in jobs) {
          await _processJob(job);
        }
      } else if (response.statusCode == 401) {
        _log.warning('Unauthorized polling print queue. Check your print-token.');
      } else {
        _log.warning('Failed to poll print queue: ${response.statusCode} - $body');
      }
    } catch (e, st) {
      _log.severe('Error polling print queue', e, st);
    } finally {
      client?.close();
      if (_running) {
        _timer = Timer(const Duration(seconds: 5), _poll);
      }
    }
  }

  Future<void> _processJob(Map<String, dynamic> job) async {
    final jobId = job['id'];
    final docName = job['document_name'] ?? 'document.pdf';
    final pdfBase64 = job['pdf_base64'];

    if (pdfBase64 == null) {
      await _updateStatus(jobId, 'failed', 'Missing PDF data');
      return;
    }

    _log.info('Processing print job $jobId: $docName');

    File? tempFile;
    try {
      // 1. Decode PDF
      final pdfBytes = base64Decode(pdfBase64);

      // 2. Save to temporary file
      final tempDir = Directory.systemTemp.createTempSync('medinfect_print_');
      tempFile = File('${tempDir.path}${Platform.pathSeparator}$docName');
      await tempFile.writeAsBytes(pdfBytes);

      // 3. Print the file silently using Edge
      _log.info('Launching Edge to print $docName silently...');
      final paths = [
        r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
        r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
      ];
      String edgePath = 'msedge.exe';
      for (final p in paths) {
        if (File(p).existsSync()) {
          edgePath = p;
          break;
        }
      }
      final result = await Process.run(
        edgePath,
        ['--headless', '--print-to-printer', tempFile.path],
      );

      if (result.exitCode == 0) {
        _log.info('Successfully printed job $jobId');
        await _updateStatus(jobId, 'completed');
      } else {
        final err = 'Edge print failed with exit code ${result.exitCode}: ${result.stderr}';
        _log.severe(err);
        await _updateStatus(jobId, 'failed', err);
      }
    } catch (e, st) {
      final err = 'Error printing job $jobId: $e';
      _log.severe(err, e, st);
      await _updateStatus(jobId, 'failed', err);
    } finally {
      // Clean up temp file
      try {
        if (tempFile != null && tempFile.existsSync()) {
          tempFile.parent.deleteSync(recursive: true);
        }
      } catch (_) {}
    }
  }

  Future<void> _updateStatus(int jobId, String status, [String? errorMessage]) async {
    HttpClient? client;
    try {
      client = HttpClient();
      final url = Uri.parse('$apiBaseUrl/api/print/status');
      final request = await client.postUrl(url);
      request.headers.set('Content-Type', 'application/json');
      request.headers.set('Authorization', 'Bearer $token');
      
      final payload = jsonEncode({
        'id': jobId,
        'status': status,
        'error_message': errorMessage,
      });
      request.write(payload);
      
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      
      if (response.statusCode != 200) {
        _log.severe('Failed to update print job $jobId status: ${response.statusCode} - $body');
      }
    } catch (e) {
      _log.severe('Error updating print job $jobId status: $e');
    } finally {
      client?.close();
    }
  }
}
