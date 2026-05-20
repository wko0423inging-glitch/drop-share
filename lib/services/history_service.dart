import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

enum TransferDirection { sent, received }
enum TransferType { lan, webrtc }
enum TransferStatus { completed, cancelled, failed }

class TransferRecord {
  final String id;
  final DateTime timestamp;
  final String fileName;
  final int fileSize;
  final TransferDirection direction;
  final TransferType type;
  final TransferStatus status;
  final String? peerName;

  TransferRecord({
    required this.id,
    required this.timestamp,
    required this.fileName,
    required this.fileSize,
    required this.direction,
    required this.type,
    required this.status,
    this.peerName,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'timestamp': timestamp.toIso8601String(),
        'fileName': fileName,
        'fileSize': fileSize,
        'direction': direction.name,
        'type': type.name,
        'status': status.name,
        'peerName': peerName,
      };

  factory TransferRecord.fromJson(Map<String, dynamic> j) => TransferRecord(
        id: j['id'] as String,
        timestamp: DateTime.parse(j['timestamp'] as String),
        fileName: j['fileName'] as String,
        fileSize: j['fileSize'] as int,
        direction: TransferDirection.values
            .firstWhere((e) => e.name == j['direction']),
        type: TransferType.values.firstWhere((e) => e.name == j['type']),
        status:
            TransferStatus.values.firstWhere((e) => e.name == j['status']),
        peerName: j['peerName'] as String?,
      );
}

class HistoryService {
  static const _fileName = 'transfer_history.json';
  static const _maxRecords = 200;

  Future<File> _getFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<List<TransferRecord>> load() async {
    try {
      final file = await _getFile();
      if (!await file.exists()) return [];
      final list = jsonDecode(await file.readAsString()) as List;
      return list
          .map((e) => TransferRecord.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> add(TransferRecord record) async {
    final records = await load();
    records.insert(0, record);
    if (records.length > _maxRecords) {
      records.removeRange(_maxRecords, records.length);
    }
    final file = await _getFile();
    await file
        .writeAsString(jsonEncode(records.map((r) => r.toJson()).toList()));
  }

  Future<void> clear() async {
    final file = await _getFile();
    if (await file.exists()) await file.delete();
  }
}
