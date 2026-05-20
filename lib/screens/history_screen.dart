import 'package:flutter/material.dart';
import '../services/history_service.dart';
import '../utils/file_type_helper.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final _service = HistoryService();
  List<TransferRecord> _records = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final records = await _service.load();
    if (mounted) {
      setState(() {
        _records = records;
        _loading = false;
      });
    }
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('履歴を削除',
            style: TextStyle(color: Colors.white, fontSize: 17)),
        content: const Text('全ての転送履歴を削除しますか？',
            style: TextStyle(color: Colors.white70, fontSize: 14)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル',
                style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('削除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _service.clear();
    if (mounted) setState(() => _records = []);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('転送履歴',
            style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          if (_records.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: _confirmClear,
              tooltip: '全て削除',
            ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF007AFF)))
          : _records.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.history, color: Colors.white24, size: 56),
                      SizedBox(height: 16),
                      Text('転送履歴はありません',
                          style: TextStyle(
                              color: Colors.white38, fontSize: 15)),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  color: const Color(0xFF007AFF),
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _records.length,
                    separatorBuilder: (_, idx) =>
                        const Divider(color: Color(0xFF2C2C2E), height: 1),
                    itemBuilder: (_, i) => _buildTile(_records[i]),
                  ),
                ),
    );
  }

  Widget _buildTile(TransferRecord r) {
    final isSent = r.direction == TransferDirection.sent;
    final Color statusColor;
    switch (r.status) {
      case TransferStatus.completed:
        statusColor = isSent ? const Color(0xFF007AFF) : const Color(0xFF34C759);
      case TransferStatus.failed:
        statusColor = Colors.red;
      case TransferStatus.cancelled:
        statusColor = Colors.orange;
    }

    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: SizedBox(
        width: 44,
        height: 44,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFF1C1C1E),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                FileTypeHelper.iconForFileName(r.fileName),
                color: FileTypeHelper.colorForFileName(r.fileName),
                size: 22,
              ),
            ),
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                width: 17,
                height: 17,
                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.black, width: 1.5),
                ),
                child: Icon(
                  isSent ? Icons.upload_rounded : Icons.download_rounded,
                  color: Colors.white,
                  size: 9,
                ),
              ),
            ),
          ],
        ),
      ),
      title: Text(
        r.fileName,
        style: const TextStyle(
            color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Text(
          [
            _fmtSize(r.fileSize),
            if (r.peerName != null) r.peerName!,
            r.type == TransferType.lan ? 'LAN' : 'WebRTC',
            _fmtDate(r.timestamp),
          ].join(' · '),
          style: const TextStyle(color: Colors.white38, fontSize: 11),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      trailing: _statusIcon(r.status),
    );
  }

  Widget _statusIcon(TransferStatus s) {
    switch (s) {
      case TransferStatus.completed:
        return const Icon(Icons.check_circle, color: Color(0xFF34C759), size: 18);
      case TransferStatus.failed:
        return const Icon(Icons.error_outline, color: Colors.red, size: 18);
      case TransferStatus.cancelled:
        return const Icon(Icons.cancel_outlined, color: Colors.orange, size: 18);
    }
  }

  String _fmtSize(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _fmtDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) {
      return '${dt.hour.toString().padLeft(2, '0')}:'
          '${dt.minute.toString().padLeft(2, '0')}';
    }
    if (diff.inDays < 7) {
      const days = ['月', '火', '水', '木', '金', '土', '日'];
      return days[dt.weekday - 1];
    }
    return '${dt.month}/${dt.day}';
  }
}
