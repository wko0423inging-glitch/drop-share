import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

typedef ProgressCallback = void Function(double progress);
typedef ReceiveProgressCallback = void Function(
    String fileName, int received, int total);
typedef BatchProgressCallback = void Function(
    int fileIndex, int fileTotal, String fileName, int bytesTransferred, int fileSize);

class TransferRequest {
  final String senderName;
  final String fileName; // '__BATCH__' for batch announcements
  final int fileSize;    // totalSize for batch, fileSize for single
  final String ip;
  final int transferPort;
  final int batchCount;  // 1 = single file, N > 1 = batch

  bool get isBatch => batchCount > 1;

  TransferRequest({
    required this.senderName,
    required this.fileName,
    required this.fileSize,
    required this.ip,
    required this.transferPort,
    this.batchCount = 1,
  });
}

class LocalTransferService {
  static const int _transferPort = 47848;
  static const int _requestPort = 47849;

  ServerSocket? _transferServer;
  ServerSocket? _requestServer;
  bool _cancelSend = false;
  bool get wasCancelled => _cancelSend;

  // Tracks IPs with pending batch auto-accept: IP → remaining file count
  final _batchAutoAccept = <String, int>{};

  Future<void> startListening(
    String deviceName,
    Future<bool> Function(TransferRequest) onRequest,
    ReceiveProgressCallback onProgress,
    void Function(String filePath, int fileSize) onComplete,
  ) async {
    _requestServer =
        await ServerSocket.bind(InternetAddress.anyIPv4, _requestPort);
    _requestServer!.listen((socket) async {
      final senderIp = socket.remoteAddress.address;
      final buffer = <int>[];
      await for (final chunk in socket) {
        buffer.addAll(chunk);
        if (buffer.contains(10)) break;
      }
      final newline = buffer.indexOf(10);
      if (newline < 0) {
        socket.write('DENY\n');
        await socket.close();
        return;
      }
      final line = String.fromCharCodes(buffer.sublist(0, newline));
      final parts = line.split('|');

      bool accepted = false;

      if (parts.length >= 5 && parts[1] == '__BATCH__') {
        // Batch announcement: senderName|__BATCH__|count|totalSize|transferPort
        final count = int.tryParse(parts[2]) ?? 0;
        final totalSize = int.tryParse(parts[3]) ?? 0;
        final port = int.tryParse(parts[4]) ?? _transferPort;
        final req = TransferRequest(
          senderName: parts[0],
          fileName: '__BATCH__',
          fileSize: totalSize,
          ip: senderIp,
          transferPort: port,
          batchCount: count,
        );
        accepted = await onRequest(req);
        socket.write(accepted ? 'ACCEPT\n' : 'DENY\n');
        await socket.flush();
        await socket.close();
        if (accepted) _batchAutoAccept[senderIp] = count;
        return;
      }

      if (parts.length < 4) {
        socket.write('DENY\n');
        await socket.close();
        return;
      }

      final req = TransferRequest(
        senderName: parts[0],
        fileName: parts[1],
        fileSize: int.tryParse(parts[2]) ?? 0,
        ip: senderIp,
        transferPort: int.tryParse(parts[3]) ?? _transferPort,
      );

      if (_batchAutoAccept.containsKey(senderIp) &&
          _batchAutoAccept[senderIp]! > 0) {
        accepted = true;
        final remaining = _batchAutoAccept[senderIp]! - 1;
        if (remaining == 0) {
          _batchAutoAccept.remove(senderIp);
        } else {
          _batchAutoAccept[senderIp] = remaining;
        }
      } else {
        accepted = await onRequest(req);
      }

      socket.write(accepted ? 'ACCEPT\n' : 'DENY\n');
      await socket.flush();
      await socket.close();
    });

    _transferServer =
        await ServerSocket.bind(InternetAddress.anyIPv4, _transferPort);
    _transferServer!.listen((socket) async {
      try {
        final dir = await getDownloadsDirectoryOrFallback();
        final headerBuf = <int>[];
        String? fileName;
        int fileSize = 0;
        int received = 0;
        IOSink? sink;
        var lastReport = DateTime(0);

        Future<void> reportProgress() async {
          final now = DateTime.now();
          if (now.difference(lastReport).inMilliseconds >= 50) {
            lastReport = now;
            onProgress(fileName!, received, fileSize);
            await Future.delayed(Duration.zero);
          }
        }

        await for (final chunk in socket) {
          if (sink == null) {
            headerBuf.addAll(chunk);
            final nl = headerBuf.indexOf(10);
            if (nl < 0) continue;
            final header = String.fromCharCodes(headerBuf.sublist(0, nl));
            final p = header.split('|');
            if (p.length < 2) {
              await socket.close();
              return;
            }
            fileName = p[0];
            fileSize = int.tryParse(p[1]) ?? 0;
            final file = File('${dir.path}/$fileName');
            sink = file.openWrite();
            final body = headerBuf.sublist(nl + 1);
            if (body.isNotEmpty) {
              sink.add(body);
              received += body.length;
              await reportProgress();
            }
            headerBuf.clear();
          } else {
            sink.add(chunk);
            received += chunk.length;
            await reportProgress();
          }
        }
        await sink?.close();
        onComplete('${dir.path}/$fileName', fileSize);
      } catch (_) {
        // connection reset by sender is expected on cancel
      }
    });
  }

  void cancelSend() => _cancelSend = true;

  Future<bool> sendFile(
    String targetIp,
    String deviceName,
    String filePath,
    ProgressCallback onProgress,
  ) async {
    _cancelSend = false;
    return _sendSingleFile(targetIp, deviceName, filePath, onProgress);
  }

  Future<bool> sendFiles(
    String targetIp,
    String deviceName,
    List<String> filePaths,
    BatchProgressCallback onProgress,
  ) async {
    _cancelSend = false;

    if (filePaths.length == 1) {
      final file = File(filePaths[0]);
      final fileSize = await file.length();
      final fileName = file.uri.pathSegments.last;
      return _sendSingleFile(targetIp, deviceName, filePaths[0],
          (p) => onProgress(1, 1, fileName, (p * fileSize).round(), fileSize));
    }

    // Pre-compute names and sizes
    final fileNames = <String>[];
    final fileSizes = <int>[];
    int totalSize = 0;
    for (final path in filePaths) {
      final f = File(path);
      final sz = await f.length();
      fileNames.add(f.uri.pathSegments.last);
      fileSizes.add(sz);
      totalSize += sz;
    }

    try {
      // Batch announcement
      final reqSock = await Socket.connect(targetIp, _requestPort,
          timeout: const Duration(seconds: 5));
      reqSock.write(
          '$deviceName|__BATCH__|${filePaths.length}|$totalSize|$_transferPort\n');
      await reqSock.flush();

      final respBuf = <int>[];
      await for (final chunk in reqSock) {
        respBuf.addAll(chunk);
        if (respBuf.contains(10)) break;
      }
      await reqSock.close();

      if (!String.fromCharCodes(respBuf).trim().startsWith('ACCEPT')) {
        return false;
      }

      // Send each file
      for (int i = 0; i < filePaths.length; i++) {
        if (_cancelSend) return false;

        final fileName = fileNames[i];
        final fileSize = fileSizes[i];

        // Individual request (auto-accepted by receiver)
        final req2 = await Socket.connect(targetIp, _requestPort,
            timeout: const Duration(seconds: 5));
        req2.write('$deviceName|$fileName|$fileSize|$_transferPort\n');
        await req2.flush();
        final resp2Buf = <int>[];
        await for (final chunk in req2) {
          resp2Buf.addAll(chunk);
          if (resp2Buf.contains(10)) break;
        }
        await req2.close();
        if (!String.fromCharCodes(resp2Buf).trim().startsWith('ACCEPT')) {
          return false;
        }

        // Transfer
        final txSock = await Socket.connect(targetIp, _transferPort,
            timeout: const Duration(seconds: 5));
        txSock.write('$fileName|$fileSize\n');
        await txSock.flush();

        int sent = 0;
        var lastReport = DateTime(0);
        await for (final chunk in File(filePaths[i]).openRead()) {
          if (_cancelSend) {
            txSock.destroy();
            return false;
          }
          txSock.add(chunk);
          sent += chunk.length;
          final now = DateTime.now();
          if (now.difference(lastReport).inMilliseconds >= 50) {
            lastReport = now;
            onProgress(i + 1, filePaths.length, fileName, sent, fileSize);
            await Future.delayed(Duration.zero);
          }
        }
        onProgress(i + 1, filePaths.length, fileName, fileSize, fileSize);
        await txSock.flush();
        await txSock.close();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _sendSingleFile(
    String targetIp,
    String deviceName,
    String filePath,
    ProgressCallback onProgress,
  ) async {
    final file = File(filePath);
    if (!await file.exists()) return false;

    final fileName = file.uri.pathSegments.last;
    final fileSize = await file.length();

    try {
      final reqSocket = await Socket.connect(targetIp, _requestPort,
          timeout: const Duration(seconds: 5));
      reqSocket.write('$deviceName|$fileName|$fileSize|$_transferPort\n');
      await reqSocket.flush();

      final respBuf = <int>[];
      await for (final chunk in reqSocket) {
        respBuf.addAll(chunk);
        if (respBuf.contains(10)) break;
      }
      await reqSocket.close();

      if (!String.fromCharCodes(respBuf).trim().startsWith('ACCEPT')) {
        return false;
      }

      final txSocket = await Socket.connect(targetIp, _transferPort,
          timeout: const Duration(seconds: 5));
      txSocket.write('$fileName|$fileSize\n');
      await txSocket.flush();

      int sent = 0;
      var lastSendReport = DateTime(0);
      await for (final chunk in file.openRead()) {
        if (_cancelSend) {
          txSocket.destroy();
          return false;
        }
        txSocket.add(chunk);
        sent += chunk.length;
        final now = DateTime.now();
        if (now.difference(lastSendReport).inMilliseconds >= 50) {
          lastSendReport = now;
          onProgress(sent / fileSize);
          await Future.delayed(Duration.zero);
        }
      }
      onProgress(1.0);
      await txSocket.flush();
      await txSocket.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  void dispose() {
    _transferServer?.close();
    _requestServer?.close();
  }
}

Future<Directory> getDownloadsDirectoryOrFallback() async {
  try {
    if (Platform.isAndroid) {
      final ext = await getExternalStorageDirectory();
      if (ext != null) return ext;
    }
    return await getApplicationDocumentsDirectory();
  } catch (_) {
    return getTemporaryDirectory();
  }
}
