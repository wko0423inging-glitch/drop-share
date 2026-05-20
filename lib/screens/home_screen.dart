import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/discovery_service.dart';
import '../services/history_service.dart';
import '../services/local_transfer.dart';
import '../services/settings_service.dart';
import '../utils/file_type_helper.dart';
import '../widgets/device_card.dart';
import 'history_screen.dart';
import 'network_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _sharingChannel = MethodChannel('drop_share/sharing');

  final _discovery = DiscoveryService();
  final _transfer = LocalTransferService();
  final _history = HistoryService();
  final _settings = SettingsService();

  List<DiscoveredDevice> _devices = [];
  String _status = '受信待機中';
  String _deviceName = 'このデバイス';
  _TransferState? _txState;

  // Files pending from Android share intent
  List<String> _pendingSharedPaths = [];

  // Last accepted sender name (for history recording on receive)
  String? _lastSenderName;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final hostname = Platform.localHostname;
    final custom = await _settings.getDeviceName();
    _deviceName = custom ?? hostname;

    await [
      Permission.storage,
      Permission.nearbyWifiDevices,
    ].request();

    // Android share intent channel
    if (Platform.isAndroid) {
      _sharingChannel.setMethodCallHandler((call) async {
        if (call.method == 'onSharedFiles') {
          final files = List<String>.from(call.arguments as List);
          if (mounted && files.isNotEmpty) {
            setState(() => _pendingSharedPaths = files);
          }
        }
      });
      try {
        final initial = await _sharingChannel
            .invokeListMethod<String>('getInitialSharedFiles');
        if (initial != null && initial.isNotEmpty && mounted) {
          setState(() => _pendingSharedPaths = initial);
        }
      } catch (_) {}
    }

    await _transfer.startListening(
      _deviceName,
      _onIncomingRequest,
      (fileName, received, total) {
        if (mounted) {
          setState(() {
            _txState ??= _TransferState(
              fileName: fileName,
              total: total,
              start: DateTime.now(),
              isSending: false,
            );
            _txState = _txState!.copyWith(received: received);
            _status = '受信中';
          });
        }
      },
      (filePath, fileSize) {
        final name = filePath.split('/').last;
        if (mounted) {
          final elapsed = _txState?.elapsedSeconds ?? 1;
          final speed = fileSize / elapsed;
          setState(() {
            _txState = null;
            _status = '受信待機中';
          });
          _history
              .add(TransferRecord(
                id: '${DateTime.now().millisecondsSinceEpoch}',
                timestamp: DateTime.now(),
                fileName: name,
                fileSize: fileSize,
                direction: TransferDirection.received,
                type: TransferType.lan,
                status: TransferStatus.completed,
                peerName: _lastSenderName,
              ))
              .ignore();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(children: [
                const Icon(Icons.check_circle, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(name,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      Text('${_fmtSize(fileSize)} · ${_fmtSpeed(speed)}',
                          style: const TextStyle(
                              fontSize: 12, color: Colors.white70)),
                    ],
                  ),
                ),
              ]),
              action: SnackBarAction(
                label: '開く',
                textColor: Colors.white,
                onPressed: () => OpenFilex.open(filePath),
              ),
              backgroundColor: const Color(0xFF34C759),
              duration: const Duration(seconds: 4),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          );
        }
      },
    );

    await _discovery.startAdvertising(_deviceName);
    await _discovery.startDiscovery();
    _discovery.devicesStream.listen((devices) {
      if (mounted) setState(() => _devices = devices);
    });
  }

  Future<bool> _onIncomingRequest(TransferRequest req) async {
    if (!mounted) return false;
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          req.isBatch ? 'ファイル一括受信リクエスト' : 'ファイル受信リクエスト',
          style: const TextStyle(color: Colors.white, fontSize: 17),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(req.senderName,
                style: const TextStyle(
                    color: Color(0xFF007AFF),
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            if (req.isBatch)
              Text('${req.batchCount}件のファイル',
                  style:
                      const TextStyle(color: Colors.white, fontSize: 15))
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(
                    FileTypeHelper.iconForFileName(req.fileName),
                    color: FileTypeHelper.colorForFileName(req.fileName),
                    size: 22,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(req.fileName,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 15),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            const SizedBox(height: 4),
            Text(_fmtSize(req.fileSize),
                style:
                    const TextStyle(color: Colors.white54, fontSize: 13)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('拒否', style: TextStyle(color: Colors.red)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('受信',
                style: TextStyle(
                    color: Color(0xFF007AFF),
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (accepted == true) _lastSenderName = req.senderName;
    return accepted ?? false;
  }

  Future<void> _editDeviceName() async {
    final controller = TextEditingController(text: _deviceName);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        insetPadding: const EdgeInsets.fromLTRB(24, 24, 24, 120),
        title: const Text('デバイス名を変更',
            style: TextStyle(color: Colors.white, fontSize: 17)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          onSubmitted: (v) {
            FocusScope.of(ctx).unfocus();
            Navigator.pop(ctx, v.trim());
          },
          decoration: InputDecoration(
            hintText: 'デバイス名',
            hintStyle: const TextStyle(color: Colors.white38),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFF3C3C3E))),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFF007AFF))),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              FocusScope.of(ctx).unfocus();
              Navigator.pop(ctx);
            },
            child: const Text('キャンセル',
                style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () {
              final text = controller.text.trim();
              FocusScope.of(ctx).unfocus();
              Navigator.pop(ctx, text);
            },
            child: const Text('保存',
                style: TextStyle(
                    color: Color(0xFF007AFF), fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    // Delay dispose to allow dialog exit animation to finish using the controller
    Future.delayed(const Duration(milliseconds: 400), controller.dispose);
    if (newName == null || newName.isEmpty || newName == _deviceName) return;
    await _settings.setDeviceName(newName);
    await _discovery.stopAdvertising();
    if (mounted) setState(() => _deviceName = newName);
    await _discovery.startAdvertising(newName);
  }

  void _cancelTransfer() {
    _transfer.cancelSend();
    if (mounted) setState(() { _txState = null; _status = '受信待機中'; });
  }

  /// Entry point when user taps a device card.
  Future<void> _sendFileTo(DiscoveredDevice device) async {
    List<String> paths;

    if (_pendingSharedPaths.isNotEmpty) {
      paths = List.from(_pendingSharedPaths);
      setState(() => _pendingSharedPaths = []);
    } else {
      final result =
          await FilePicker.platform.pickFiles(allowMultiple: true);
      if (result == null || result.files.isEmpty) return;
      paths =
          result.files.map((f) => f.path).whereType<String>().toList();
      if (paths.isEmpty) return;
    }

    await _sendPathsTo(device, paths);
  }

  Future<void> _sendPathsTo(
      DiscoveredDevice device, List<String> paths) async {
    // Resolve first file info for initial state
    final firstFile = File(paths.first);
    final firstSize = await firstFile.length();
    final firstName = firstFile.uri.pathSegments.last;

    setState(() {
      _txState = _TransferState(
        fileName: firstName,
        total: firstSize,
        start: DateTime.now(),
        isSending: true,
        batchIndex: 1,
        batchTotal: paths.length,
      );
      _status = '送信中';
    });

    final start = DateTime.now();
    bool success;

    if (paths.length == 1) {
      success = await _transfer.sendFile(
        device.ip,
        _deviceName,
        paths[0],
        (p) {
          if (mounted) {
            setState(() => _txState =
                _txState?.copyWith(received: (p * firstSize).round()));
          }
        },
      );

      if (mounted) {
        final elapsed = DateTime.now().difference(start).inMilliseconds / 1000;
        final speed = firstSize / (elapsed > 0 ? elapsed : 1);
        setState(() { _txState = null; _status = '受信待機中'; });
        _recordSentHistory([firstName], [firstSize], device.name,
            success ? TransferStatus.completed : TransferStatus.failed);
        _showSendSnackbar(
            success: success,
            names: [firstName],
            totalSize: firstSize,
            speed: speed);
      }
    } else {
      // Batch send
      final fileNames = <String>[];
      final fileSizes = <int>[];

      success = await _transfer.sendFiles(
        device.ip,
        _deviceName,
        paths,
        (fileIdx, fileTotal, fileName, bytesTransferred, fileSize) {
          if (mounted) {
            setState(() {
              _txState = _TransferState(
                fileName: fileName,
                total: fileSize,
                received: bytesTransferred,
                start: _txState?.start ?? DateTime.now(),
                isSending: true,
                batchIndex: fileIdx,
                batchTotal: fileTotal,
              );
            });
          }
          // Capture for history
          if (fileIdx - 1 == fileNames.length) {
            fileNames.add(fileName);
            fileSizes.add(fileSize);
          }
        },
      );

      if (mounted) {
        final elapsed = DateTime.now().difference(start).inMilliseconds / 1000;
        int total = fileSizes.fold(0, (a, b) => a + b);
        final speed = total / (elapsed > 0 ? elapsed : 1);
        setState(() { _txState = null; _status = '受信待機中'; });
        _recordSentHistory(fileNames, fileSizes, device.name,
            success ? TransferStatus.completed :
            _transfer.wasCancelled ? TransferStatus.cancelled : TransferStatus.failed);
        _showSendSnackbar(
            success: success,
            names: fileNames,
            totalSize: total,
            speed: speed);
      }
    }
  }

  void _recordSentHistory(List<String> names, List<int> sizes,
      String peerName, TransferStatus status) {
    final now = DateTime.now();
    for (int i = 0; i < names.length; i++) {
      _history
          .add(TransferRecord(
            id: '${now.millisecondsSinceEpoch}_$i',
            timestamp: now,
            fileName: names[i],
            fileSize: i < sizes.length ? sizes[i] : 0,
            direction: TransferDirection.sent,
            type: TransferType.lan,
            status: status,
            peerName: peerName,
          ))
          .ignore();
    }
  }

  void _showSendSnackbar({
    required bool success,
    required List<String> names,
    required int totalSize,
    required double speed,
  }) {
    if (!mounted) return;
    final label = names.length == 1
        ? '${names[0]} を送信しました'
        : '${names.length}件のファイルを送信しました';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(children: [
          Icon(success ? Icons.upload_rounded : Icons.error_outline,
              color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: success
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(label,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      Text('${_fmtSize(totalSize)} · ${_fmtSpeed(speed)}',
                          style: const TextStyle(
                              fontSize: 12, color: Colors.white70)),
                    ],
                  )
                : Text('送信失敗'),
          ),
        ]),
        backgroundColor: success ? const Color(0xFF007AFF) : Colors.red,
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _fmtSpeed(double bytesPerSec) {
    if (bytesPerSec < 1024 * 1024) {
      return '${(bytesPerSec / 1024).toStringAsFixed(0)} KB/s';
    }
    return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  @override
  void dispose() {
    _discovery.dispose();
    _transfer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tx = _txState;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 16, 4),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('DropShare',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 34,
                            fontWeight: FontWeight.bold,
                            letterSpacing: -0.5)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.history, color: Colors.white54),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const HistoryScreen()),
                    ),
                    tooltip: '転送履歴',
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 16, 12),
              child: GestureDetector(
                onTap: _editDeviceName,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_deviceName,
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 13)),
                    const SizedBox(width: 4),
                    const Icon(Icons.edit, color: Colors.white24, size: 13),
                  ],
                ),
              ),
            ),

            // Share intent banner
            if (_pendingSharedPaths.isNotEmpty)
              _buildShareBanner(),

            // Nearby devices label
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text('近くのデバイス',
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 13)),
            ),

            // Device list
            SizedBox(
              height: 120,
              child: _devices.isEmpty
                  ? Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white24),
                          ),
                          const SizedBox(width: 10),
                          Text('デバイスを検索中...',
                              style: TextStyle(
                                  color: Colors.white
                                      .withValues(alpha: 0.3),
                                  fontSize: 14)),
                        ],
                      ),
                    )
                  : ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding:
                          const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _devices.length,
                      itemBuilder: (ctx, i) => Padding(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 8),
                        child: DeviceCard(
                          device: _devices[i],
                          onTap: tx == null
                              ? () => _sendFileTo(_devices[i])
                              : null,
                        ),
                      ),
                    ),
            ),

            const Divider(color: Color(0xFF2C2C2E), height: 1),

            Expanded(
              child:
                  tx != null ? _buildProgressView(tx) : _buildIdleView(),
            ),

            // Internet transfer button
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF007AFF),
                    side: const BorderSide(color: Color(0xFF2C2C2E)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const NetworkScreen()),
                  ),
                  icon: const Icon(Icons.language, size: 18),
                  label:
                      const Text('インターネット経由で転送 (WebRTC)'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildShareBanner() {
    final count = _pendingSharedPaths.length;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF007AFF).withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: const Color(0xFF007AFF).withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.share, color: Color(0xFF007AFF), size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '$count件のファイルを共有中 — 送信先を選択してください',
              style: const TextStyle(
                  color: Color(0xFF007AFF), fontSize: 13),
            ),
          ),
          GestureDetector(
            onTap: () =>
                setState(() => _pendingSharedPaths = []),
            child: const Icon(Icons.close,
                color: Color(0xFF007AFF), size: 18),
          ),
        ],
      ),
    );
  }

  Widget _buildIdleView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C1E),
              borderRadius: BorderRadius.circular(36),
            ),
            child: const Icon(Icons.wifi_tethering,
                color: Color(0xFF007AFF), size: 36),
          ),
          const SizedBox(height: 16),
          Text(_status,
              style: const TextStyle(
                  color: Colors.white70, fontSize: 15)),
          const SizedBox(height: 6),
          if (_devices.isNotEmpty)
            Text(
              _pendingSharedPaths.isNotEmpty
                  ? '送信先デバイスをタップ'
                  : 'デバイスをタップしてファイルを送信',
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.3),
                  fontSize: 12),
            ),
        ],
      ),
    );
  }

  Widget _buildProgressView(_TransferState tx) {
    final pct = tx.total > 0 ? tx.received / tx.total : 0.0;
    final elapsed = tx.elapsedSeconds;
    final speed = elapsed > 0 ? tx.received / elapsed : 0.0;
    final remaining =
        speed > 0 ? (tx.total - tx.received) / speed : 0.0;
    final accentColor = tx.isSending
        ? const Color(0xFF007AFF)
        : const Color(0xFF34C759);

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 100,
              height: 100,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CircularProgressIndicator(
                    value: pct,
                    strokeWidth: 7,
                    color: accentColor,
                    backgroundColor: const Color(0xFF2C2C2E),
                    strokeCap: StrokeCap.round,
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('${(pct * 100).toInt()}%',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.bold)),
                      if (tx.batchTotal > 1)
                        Text('${tx.batchIndex}/${tx.batchTotal}',
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 11)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Text(tx.fileName,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w500),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Text(tx.isSending ? '↑ 送信中' : '↓ 受信中',
                style: TextStyle(color: accentColor, fontSize: 13)),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: pct,
                minHeight: 6,
                color: accentColor,
                backgroundColor: const Color(0xFF2C2C2E),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${_fmtSize(tx.received)} / ${_fmtSize(tx.total)}',
                  style: const TextStyle(
                      color: Colors.white54, fontSize: 12),
                ),
                Text(
                  speed > 0
                      ? '${_fmtSpeed(speed)}'
                          '${remaining > 1 ? ' · 残り${remaining.toInt()}秒' : ''}'
                      : '...',
                  style: const TextStyle(
                      color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
            if (tx.isSending) ...[
              const SizedBox(height: 20),
              TextButton(
                onPressed: _cancelTransfer,
                child: const Text('キャンセル',
                    style:
                        TextStyle(color: Colors.red, fontSize: 14)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TransferState {
  final String fileName;
  final int received;
  final int total;
  final DateTime start;
  final bool isSending;
  final int batchIndex;
  final int batchTotal;

  const _TransferState({
    required this.fileName,
    required this.total,
    required this.start,
    required this.isSending,
    this.received = 0,
    this.batchIndex = 1,
    this.batchTotal = 1,
  });

  double get elapsedSeconds =>
      DateTime.now().difference(start).inMilliseconds / 1000.0;

  _TransferState copyWith({int? received, int? batchIndex}) =>
      _TransferState(
        fileName: fileName,
        received: received ?? this.received,
        total: total,
        start: start,
        isSending: isSending,
        batchIndex: batchIndex ?? this.batchIndex,
        batchTotal: batchTotal,
      );
}
