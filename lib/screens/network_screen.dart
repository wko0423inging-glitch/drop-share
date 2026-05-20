import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:open_filex/open_filex.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../services/history_service.dart';
import '../services/relay_server.dart';
import '../services/signaling_client.dart';
import '../services/webrtc_transfer.dart';

class NetworkScreen extends StatefulWidget {
  const NetworkScreen({super.key});

  @override
  State<NetworkScreen> createState() => _NetworkScreenState();
}

enum _Phase {
  idle,         // choose host or join
  hosting,      // QR shown, waiting for peer
  joining,      // entering/scanning room code
  connecting,   // WebRTC handshake
  transferring, // transfer in progress
  done,         // completed
  error,        // connection failed
}

class _NetworkScreenState extends State<NetworkScreen> {
  _Phase _phase = _Phase.idle;
  String? _roomCode;
  String? _relayUrl;
  String? _statusText;
  double _progress = 0;
  String? _transferFileName;
  int _transferTotal = 0;
  int _transferReceived = 0;
  bool _isSending = false;
  int _batchIndex = 1;
  int _batchTotal = 1;
  String? _errorMessage;
  bool _isHostMode = false;

  final _history = HistoryService();

  RelayServer? _relay;
  SignalingClient? _sigClient;
  WebRTCTransferService? _webrtc;
  final _codeController = TextEditingController();

  @override
  void dispose() {
    _relay?.stop();
    _webrtc?.dispose();
    _codeController.dispose();
    super.dispose();
  }

  String _generateCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rng = Random.secure();
    return List.generate(6, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  Future<String?> _getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> _startHost() async {
    setState(() { _phase = _Phase.hosting; _isHostMode = true; });
    try {
      _relay = RelayServer();
      await _relay!.start();

      final ip = await _getLocalIp();
      final code = _generateCode();
      final url = 'ws://${ip ?? 'localhost'}:${_relay!.port}';

      setState(() {
        _roomCode = code;
        _relayUrl = url;
        _statusText = 'ピアの接続を待機中...';
      });

      final sig = SignalingClient();
      _sigClient = sig;
      await sig.connect(url, code);

      await sig.messages
          .firstWhere((m) => m['type'] == 'peer_joined')
          .timeout(const Duration(minutes: 5));

      setState(() {
        _phase = _Phase.connecting;
        _statusText = 'WebRTC接続中...';
      });

      _webrtc = WebRTCTransferService(sig);
      _webrtc!.onReceiveProgress = _onReceiveProgress;
      _webrtc!.onReceiveComplete = _onReceiveComplete;
      _webrtc!.onReceiveCancelled = _onReceiveCancelled;
      await _webrtc!.init(isHost: true);

      setState(() {
        _phase = _Phase.transferring;
        _statusText = '接続完了 — ファイルを選んで送信';
      });
    } catch (e) {
      _handleError(e);
    }
  }

  Future<void> _joinRoom(String code, String url) async {
    setState(() {
      _phase = _Phase.connecting;
      _isHostMode = false;
      _statusText = 'シグナリングサーバーに接続中...';
    });
    try {
      final sig = SignalingClient();
      _sigClient = sig;
      await sig.connect(url, code.toUpperCase()).timeout(const Duration(seconds: 15));

      setState(() => _statusText = 'WebRTC接続中...');

      _webrtc = WebRTCTransferService(sig);
      _webrtc!.onReceiveProgress = _onReceiveProgress;
      _webrtc!.onReceiveComplete = _onReceiveComplete;
      _webrtc!.onReceiveCancelled = _onReceiveCancelled;
      await _webrtc!.init(isHost: false).timeout(const Duration(seconds: 30));

      setState(() {
        _phase = _Phase.transferring;
        _statusText = '接続完了 — ファイルを選んで送信';
      });
    } catch (e) {
      _handleError(e);
    }
  }

  void _onReceiveProgress(String fileName, int received, int total) {
    if (mounted) {
      setState(() {
        _isSending = false;
        _transferFileName = fileName;
        _transferReceived = received;
        _transferTotal = total;
        _progress = total > 0 ? received / total : 0;
        _statusText = '受信中';
      });
    }
  }

  void _onReceiveComplete(String fileName, String filePath) {
    if (mounted) {
      final fileSize = File(filePath).lengthSync();
      _history
          .add(TransferRecord(
            id: '${DateTime.now().millisecondsSinceEpoch}',
            timestamp: DateTime.now(),
            fileName: fileName,
            fileSize: fileSize,
            direction: TransferDirection.received,
            type: TransferType.webrtc,
            status: TransferStatus.completed,
            peerName: _roomCode,
          ))
          .ignore();
      setState(() {
        _progress = 0;
        _transferFileName = null;
        _batchIndex = 1;
        _batchTotal = 1;
        _statusText = '接続完了 — ファイルを選んで送信';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(children: [
            const Icon(Icons.check_circle, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text('$fileName を受信しました',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ]),
          action: SnackBarAction(
            label: '開く',
            textColor: Colors.white,
            onPressed: () => OpenFilex.open(filePath),
          ),
          backgroundColor: const Color(0xFF34C759),
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
    }
  }

  void _onReceiveCancelled() {
    if (mounted) {
      setState(() {
        _progress = 0;
        _transferFileName = null;
        _statusText = '接続完了 — ファイルを選んで送信';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('送信側がキャンセルしました'),
          backgroundColor: Colors.orange.shade800,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _pickAndSend() async {
    final result =
        await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null || result.files.isEmpty) return;
    final paths =
        result.files.map((f) => f.path).whereType<String>().toList();
    if (paths.isEmpty) return;

    final fileNames = <String>[];
    final fileSizes = <int>[];

    setState(() {
      _batchTotal = paths.length;
      _batchIndex = 1;
    });

    for (int i = 0; i < paths.length; i++) {
      final file = File(paths[i]);
      final fileName = file.uri.pathSegments.last;
      final fileSize = await file.length();
      fileNames.add(fileName);
      fileSizes.add(fileSize);

      if (mounted) {
        setState(() {
          _isSending = true;
          _batchIndex = i + 1;
          _transferFileName = fileName;
          _transferTotal = fileSize;
          _transferReceived = 0;
          _progress = 0;
          _statusText = '送信中';
        });
      }

      await _webrtc!.sendFile(
        fileName: fileName,
        fileSize: fileSize,
        fileStream: file.openRead(),
        onProgress: (p) {
          if (mounted) {
            setState(() {
              _progress = p;
              _transferReceived = (p * fileSize).round();
            });
          }
        },
      );

      if (_webrtc == null) break;

      _history
          .add(TransferRecord(
            id: '${DateTime.now().millisecondsSinceEpoch}_$i',
            timestamp: DateTime.now(),
            fileName: fileName,
            fileSize: fileSize,
            direction: TransferDirection.sent,
            type: TransferType.webrtc,
            status: TransferStatus.completed,
            peerName: _roomCode,
          ))
          .ignore();
    }

    if (mounted && _transferFileName != null) {
      setState(() {
        _progress = 0;
        _transferFileName = null;
        _batchIndex = 1;
        _batchTotal = 1;
        _statusText = '接続完了 — ファイルを選んで送信';
      });
    }
  }

  void _handleError(Object e) {
    _relay?.stop();
    _sigClient?.dispose();
    _webrtc?.dispose();
    _relay = null;
    _sigClient = null;
    _webrtc = null;
    if (mounted) {
      setState(() {
        _phase = _Phase.error;
        _errorMessage = _simplifyError(e);
      });
    }
  }

  String _simplifyError(Object e) {
    final msg = e.toString();
    if (msg.contains('TimeoutException')) return '接続がタイムアウトしました';
    if (msg.contains('Connection refused')) return '接続が拒否されました\nホストが起動しているか確認してください';
    if (msg.contains('WebSocket') || msg.contains('ws://')) return 'シグナリングサーバーへの接続に失敗しました';
    if (msg.contains('ICE') || msg.contains('RTCPeer')) return 'WebRTC P2P接続に失敗しました\nネットワーク環境を確認してください';
    return '接続エラーが発生しました';
  }

  void _cancelWebRTCTransfer() {
    _webrtc?.cancelSend();
    if (mounted) {
      setState(() {
        _isSending = false;
        _progress = 0;
        _transferFileName = null;
        _statusText = '接続完了 — ファイルを選んで送信';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('ネット転送',
            style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: SafeArea(
        child: switch (_phase) {
          _Phase.idle => _buildIdle(),
          _Phase.hosting => _buildHosting(),
          _Phase.joining => _buildJoining(),
          _Phase.connecting => _buildConnecting(),
          _Phase.transferring => _buildTransferring(),
          _Phase.done => _buildIdle(),
          _Phase.error => _buildError(),
        },
      ),
    );
  }

  Widget _buildIdle() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: const Color(0xFF1C1C1E),
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Icon(Icons.language,
                  color: Color(0xFF007AFF), size: 40),
            ),
            const SizedBox(height: 20),
            const Text('インターネット経由でファイルを転送',
                style: TextStyle(color: Colors.white, fontSize: 17,
                    fontWeight: FontWeight.w600),
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            const Text('同じLAN外でもWebRTC P2Pで直接転送',
                style: TextStyle(color: Colors.white54, fontSize: 13),
                textAlign: TextAlign.center),
            const SizedBox(height: 40),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF007AFF),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: _startHost,
                child: const Text('ホストとして開始 (QRコード表示)',
                    style: TextStyle(fontSize: 15)),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF007AFF),
                  side: const BorderSide(color: Color(0xFF007AFF)),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: () => setState(() => _phase = _Phase.joining),
                child: const Text('ルームコードで参加',
                    style: TextStyle(fontSize: 15)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHosting() {
    final qrData = _relayUrl != null && _roomCode != null
        ? '$_relayUrl|$_roomCode'
        : null;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('このQRコードを相手にスキャンさせてください',
                style: TextStyle(color: Colors.white70, fontSize: 14),
                textAlign: TextAlign.center),
            const SizedBox(height: 24),
            if (qrData != null)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: QrImageView(data: qrData, size: 220),
              )
            else
              const CircularProgressIndicator(color: Color(0xFF007AFF)),
            const SizedBox(height: 24),
            if (_roomCode != null) ...[
              const Text('またはルームコード:',
                  style: TextStyle(color: Colors.white54, fontSize: 13)),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: _roomCode!));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('コードをコピーしました'),
                    duration: Duration(seconds: 2),
                  ));
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1C1C1E),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _roomCode!,
                        style: const TextStyle(
                            color: Color(0xFF007AFF),
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 6),
                      ),
                      const SizedBox(width: 8),
                      const Icon(Icons.copy, color: Colors.white38, size: 18),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Color(0xFF007AFF))),
                const SizedBox(width: 10),
                Text(_statusText ?? 'ピアの接続を待機中...',
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 14)),
              ],
            ),
            const SizedBox(height: 24),
            TextButton(
              onPressed: () {
                _relay?.stop();
                _sigClient?.dispose();
                setState(() => _phase = _Phase.idle);
              },
              child:
                  const Text('キャンセル', style: TextStyle(color: Colors.red)),
            ),
          ],
      ),
    );
  }

  Future<void> _scanQrCode() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('カメラの許可が必要です')),
        );
      }
      return;
    }
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _QrScannerScreen(
          onScanned: (data) {
            Navigator.pop(context);
            _handleQrData(data);
          },
        ),
      ),
    );
  }

  void _handleQrData(String data) {
    final parts = data.split('|');
    if (parts.length < 2) return;
    final url = parts[0];
    final code = parts[1];
    if (url.startsWith('ws://') && code.length == 6) {
      _joinRoom(code, url);
    }
  }

  Widget _buildJoining() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('接続先のホストから共有された情報を入力してください',
              style: TextStyle(color: Colors.white70, fontSize: 14)),
          const SizedBox(height: 24),
          // QR scan button
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF007AFF),
                side: const BorderSide(color: Color(0xFF007AFF)),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: _scanQrCode,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('QRコードをスキャン', style: TextStyle(fontSize: 15)),
            ),
          ),
          const SizedBox(height: 24),
          Row(children: [
            const Expanded(child: Divider(color: Color(0xFF3C3C3E))),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text('または手動入力',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.3),
                      fontSize: 12)),
            ),
            const Expanded(child: Divider(color: Color(0xFF3C3C3E))),
          ]),
          const SizedBox(height: 24),
          TextField(
            controller: _codeController,
            style: const TextStyle(color: Colors.white, letterSpacing: 4,
                fontSize: 22, fontWeight: FontWeight.bold),
            textCapitalization: TextCapitalization.characters,
            maxLength: 6,
            decoration: InputDecoration(
              labelText: 'ルームコード',
              labelStyle: const TextStyle(color: Colors.white54),
              counterStyle: const TextStyle(color: Colors.white38),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFF3C3C3E))),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFF007AFF))),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: 'ホストアドレス (例: ws://192.168.1.x:PORT)',
              labelStyle: const TextStyle(color: Colors.white54, fontSize: 12),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFF3C3C3E))),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFF007AFF))),
            ),
            onChanged: (v) => _relayUrl = v,
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF007AFF),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: () {
                final code = _codeController.text.trim();
                final url = _relayUrl?.trim() ?? '';
                if (code.length == 6 && url.startsWith('ws://')) {
                  _joinRoom(code, url);
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('コードとアドレスを正しく入力してください')),
                  );
                }
              },
              child: const Text('接続', style: TextStyle(fontSize: 16)),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: TextButton(
              onPressed: () => setState(() => _phase = _Phase.idle),
              child: const Text('戻る', style: TextStyle(color: Colors.white54)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnecting() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(color: Color(0xFF007AFF)),
          const SizedBox(height: 24),
          Text(_statusText ?? '接続中...',
              style: const TextStyle(color: Colors.white70, fontSize: 15)),
        ],
      ),
    );
  }

  Widget _buildTransferring() {
    final hasTransfer = _transferFileName != null;
    final pct = _progress;
    final accentColor =
        _isSending ? const Color(0xFF007AFF) : const Color(0xFF34C759);

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hasTransfer) ...[
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
                        if (_batchTotal > 1)
                          Text('$_batchIndex/$_batchTotal',
                              style: const TextStyle(
                                  color: Colors.white54, fontSize: 11)),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Text(_transferFileName!,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w500),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 6),
              Text(_isSending ? '↑ 送信中' : '↓ 受信中',
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
              const SizedBox(height: 8),
              Text(
                '${_fmtSize(_transferReceived)} / ${_fmtSize(_transferTotal)}',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 32),
            ] else ...[
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1C1E),
                  borderRadius: BorderRadius.circular(36),
                ),
                child: const Icon(Icons.link,
                    color: Color(0xFF34C759), size: 36),
              ),
              const SizedBox(height: 16),
              const Text('接続済み',
                  style: TextStyle(
                      color: Color(0xFF34C759),
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              const Text('ファイルを選択して相手に送信できます',
                  style: TextStyle(color: Colors.white54, fontSize: 13)),
              const SizedBox(height: 32),
            ],
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF007AFF),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: hasTransfer ? null : _pickAndSend,
                icon: const Icon(Icons.upload_file),
                label: const Text('ファイルを送信', style: TextStyle(fontSize: 15)),
              ),
            ),

            // Cancel button (sender only, during active transfer)
            if (hasTransfer && _isSending) ...[
              const SizedBox(height: 12),
              TextButton(
                onPressed: _cancelWebRTCTransfer,
                child: const Text('キャンセル',
                    style: TextStyle(color: Colors.red, fontSize: 14)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Icon(Icons.wifi_off, color: Colors.red, size: 40),
            ),
            const SizedBox(height: 20),
            const Text('接続に失敗しました',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(_errorMessage ?? 'エラーが発生しました',
                style: const TextStyle(color: Colors.white54, fontSize: 13),
                textAlign: TextAlign.center),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF007AFF),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: () {
                  if (_isHostMode) {
                    _startHost();
                  } else {
                    setState(() => _phase = _Phase.joining);
                  }
                },
                child: Text(_isHostMode ? '再試行' : 'コード入力に戻る',
                    style: const TextStyle(fontSize: 15)),
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => setState(() => _phase = _Phase.idle),
              child: const Text('最初から',
                  style: TextStyle(color: Colors.white54)),
            ),
          ],
        ),
      ),
    );
  }

  String _fmtSize(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

class _QrScannerScreen extends StatefulWidget {
  final void Function(String data) onScanned;

  const _QrScannerScreen({required this.onScanned});

  @override
  State<_QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<_QrScannerScreen> {
  bool _handled = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('QRコードをスキャン'),
      ),
      body: Stack(
        children: [
          MobileScanner(
            onDetect: (capture) {
              if (_handled) return;
              final barcode = capture.barcodes.firstOrNull;
              final value = barcode?.rawValue;
              if (value != null && value.startsWith('ws://')) {
                _handled = true;
                widget.onScanned(value);
              }
            },
          ),
          // Overlay hint
          Align(
            alignment: const Alignment(0, 0.6),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Text(
                'ホストに表示されたQRコードにカメラを向けてください',
                style: TextStyle(color: Colors.white, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
