import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

typedef ProgressCallback = void Function(double progress);

class TransferRequest {
  final String senderName;
  final String fileName;
  final int fileSize;
  final String ip;
  final int transferPort;

  TransferRequest({
    required this.senderName,
    required this.fileName,
    required this.fileSize,
    required this.ip,
    required this.transferPort,
  });
}

class LocalTransferService {
  static const int _transferPort = 47848;
  static const int _requestPort = 47849;

  ServerSocket? _transferServer;
  ServerSocket? _requestServer;

  Future<void> startListening(
    String deviceName,
    Future<bool> Function(TransferRequest) onRequest,
    void Function(String, double) onProgress,
    void Function(String) onComplete,
  ) async {
    _requestServer =
        await ServerSocket.bind(InternetAddress.anyIPv4, _requestPort);
    _requestServer!.listen((socket) async {
      final buffer = <int>[];
      await for (final chunk in socket) {
        buffer.addAll(chunk);
        if (buffer.contains(10)) break;
      }
      final line =
          String.fromCharCodes(buffer.sublist(0, buffer.indexOf(10)));
      final parts = line.split('|');
      if (parts.length < 4) {
        socket.write('DENY\n');
        await socket.close();
        return;
      }
      final request = TransferRequest(
        senderName: parts[0],
        fileName: parts[1],
        fileSize: int.tryParse(parts[2]) ?? 0,
        ip: socket.remoteAddress.address,
        transferPort: int.tryParse(parts[3]) ?? _transferPort,
      );
      final accepted = await onRequest(request);
      socket.write(accepted ? 'ACCEPT\n' : 'DENY\n');
      await socket.flush();
      await socket.close();
    });

    _transferServer =
        await ServerSocket.bind(InternetAddress.anyIPv4, _transferPort);
    _transferServer!.listen((socket) async {
      try {
        final headerBuf = <int>[];
        String? fileName;
        int fileSize = 0;
        int received = 0;
        IOSink? sink;
        String? filePath;

        await for (final chunk in socket) {
          if (sink == null) {
            headerBuf.addAll(chunk);
            final nl = headerBuf.indexOf(10);
            if (nl < 0) continue;
            final header =
                String.fromCharCodes(headerBuf.sublist(0, nl));
            final p = header.split('|');
            fileName = p[0];
            fileSize = int.tryParse(p.length > 1 ? p[1] : '0') ?? 0;

            // ファイルの拡張子で保存先を判定
            final isImage = _isImageFile(fileName);
            final dir = isImage
                ? await getPhotosDirectoryOrFallback()
                : await getFilesDirectoryOrFallback();

            filePath = '${dir.path}/$fileName';
            final file = File(filePath);
            sink = file.openWrite();
            final body = headerBuf.sublist(nl + 1);
            if (body.isNotEmpty) {
              sink.add(body);
              received += body.length;
            }
          } else {
            sink.add(chunk);
            received += chunk.length;
            if (fileSize > 0) {
              onProgress(fileName!, received / fileSize);
            }
          }
        }
        await sink?.close();
        onComplete(filePath ?? '');
      } catch (_) {}
    });
  }

  Future<bool> sendFile(
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
      reqSocket
          .write('$deviceName|$fileName|$fileSize|$_transferPort\n');
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

      final transferSocket = await Socket.connect(
          targetIp, _transferPort,
          timeout: const Duration(seconds: 5));
      transferSocket.write('$fileName|$fileSize\n');
      await transferSocket.flush();

      int sent = 0;
      await for (final chunk in file.openRead()) {
        transferSocket.add(chunk);
        sent += chunk.length;
        onProgress(sent / fileSize);
      }

      await transferSocket.flush();
      await transferSocket.close();
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

bool _isImageFile(String fileName) {
  final imageExtensions = ['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'raw'];
  final ext = fileName.split('.').last.toLowerCase();
  return imageExtensions.contains(ext);
}

Future<Directory> getPhotosDirectoryOrFallback() async {
  try {
    if (Platform.isAndroid) {
      return Directory('/storage/emulated/0/DCIM/Camera');
    }
    // iOS: Documents以下のPhotosディレクトリ
    final docsDir = await getApplicationDocumentsDirectory();
    final photosDir = Directory('${docsDir.path}/Photos');
    if (!await photosDir.exists()) {
      await photosDir.create(recursive: true);
    }
    return photosDir;
  } catch (_) {
    return getTemporaryDirectory();
  }
}

Future<Directory> getFilesDirectoryOrFallback() async {
  try {
    if (Platform.isAndroid) {
      return Directory('/storage/emulated/0/Download');
    }
    // iOS: Documents
    return await getApplicationDocumentsDirectory();
  } catch (_) {
    return getTemporaryDirectory();
  }
}

Future<Directory> getDownloadsDirectoryOrFallback() async {
  try {
    if (Platform.isAndroid) {
      return Directory('/storage/emulated/0/Download');
    }
    return await getApplicationDocumentsDirectory();
  } catch (_) {
    return getTemporaryDirectory();
  }
}
