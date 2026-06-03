import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import '../services/discovery.dart';
import '../services/local_transfer.dart';
import '../widgets/device_card.dart';

class HomeScreen extends StatefulWidget {
  final Function(ThemeMode)? onThemeModeChanged;

  const HomeScreen({super.key, this.onThemeModeChanged});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _discovery = DiscoveryService();
  final _transfer = LocalTransferService();
  List<DiscoveredDevice> _devices = [];
  bool _isScanning = false;
  String? _statusMessage;
  double? _transferProgress;
  late String _deviceName;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _deviceName = await _loadDeviceName();
    await _requestPermissions();
    await _discovery.startAdvertising(_deviceName);
    _discovery.devicesStream.listen((devices) {
      if (mounted) setState(() => _devices = devices);
    });
    await _startTransferListener();
    _listenForSharedFiles();
    _scan();
  }

  void _listenForSharedFiles() {
    ReceiveSharingIntent.instance.getMediaStream().listen((List<SharedMediaFile> value) {
      if (value.isNotEmpty && _devices.isNotEmpty) {
        _showDeviceSelectionDialog(value);
      }
    }, onError: (err) {
      debugPrint('Error listening to shared files: $err');
    });
  }

  void _showDeviceSelectionDialog(List<SharedMediaFile> files) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        title: const Text('送信するデバイスを選択',
            style: TextStyle(color: Colors.white)),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _devices.length,
            itemBuilder: (context, index) {
              final device = _devices[index];
              return ListTile(
                title: Text(device.name,
                    style: const TextStyle(color: Colors.white)),
                subtitle: Text(device.platform,
                    style: TextStyle(color: Colors.white.withOpacity(0.5))),
                onTap: () {
                  Navigator.pop(ctx);
                  for (final file in files) {
                    _sendFileTo(device, file.path);
                  }
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('キャンセル',
                style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  Future<String> _loadDeviceName() async {
    // TODO: SharedPreferencesで保存したデバイス名を読み込む
    // 実装後に共有プリファレンスから読み込み、ない場合はデフォルトを使用
    return Platform.localHostname;
  }

  void _showEditDeviceNameDialog() {
    final controller = TextEditingController(text: _deviceName);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        title: const Text('デバイス名を編集',
            style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            filled: true,
            fillColor: const Color(0xFF2C2C2E),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            hintText: 'デバイス名を入力',
            hintStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('キャンセル',
                style: TextStyle(color: Colors.red)),
          ),
          TextButton(
            onPressed: () async {
              final newName = controller.text.trim();
              if (newName.isNotEmpty) {
                setState(() => _deviceName = newName);
                // TODO: SharedPreferencesに保存
                await _discovery.startAdvertising(newName);
                if (mounted) {
                  Navigator.pop(ctx);
                  _showSnackBar('デバイス名を更新しました');
                }
              }
            },
            child: const Text('保存',
                style: TextStyle(color: Color(0xFF007AFF))),
          ),
        ],
      ),
    );
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      await [
        Permission.storage,
        Permission.nearbyWifiDevices,
      ].request();
    }
  }

  Future<void> _startTransferListener() async {
    await _transfer.startListening(
      _deviceName,
      (request) async {
        final accepted = await _showReceiveDialog(request);
        return accepted ?? false;
      },
      (fileName, progress) {
        if (mounted) {
          setState(() {
            _statusMessage = '$fileNameを受信中...';
            _transferProgress = progress;
          });
        }
      },
      (path) {
        if (mounted) {
          setState(() {
            _statusMessage = null;
            _transferProgress = null;
          });
          _showSnackBar('受信完了: ${path.split('/').last}');
        }
      },
    );
  }

  Future<bool?> _showReceiveDialog(TransferRequest request) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('ファイルを受け取りますか？',
            style: TextStyle(color: Colors.white)),
        content: Text(
          '${request.senderName} から\n${request.fileName}\n(${_formatSize(request.fileSize)})',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('断る', style: TextStyle(color: Colors.red)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('受け取る',
                style: TextStyle(color: Color(0xFF007AFF))),
          ),
        ],
      ),
    );
  }

  Future<void> _scan() async {
    setState(() => _isScanning = true);
    await _discovery.startDiscovery();
    if (mounted) setState(() => _isScanning = false);
  }

  Future<void> _sendFileTo(DiscoveredDevice device, [String? filePath]) async {
    filePath ??= (await FilePicker.platform.pickFiles())?.files.first.path;
    if (filePath == null) return;

    setState(() {
      _statusMessage = '${device.name} に送信中...';
      _transferProgress = 0;
    });

    final success = await _transfer.sendFile(
      device.ip,
      _deviceName,
      filePath,
      (progress) {
        if (mounted) setState(() => _transferProgress = progress);
      },
    );

    if (mounted) {
      setState(() {
        _statusMessage = null;
        _transferProgress = null;
      });
      _showSnackBar(success ? '送信完了' : '送信に失敗しました');
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFF1C1C1E),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)}KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)}GB';
  }

  @override
  void dispose() {
    _discovery.dispose();
    _transfer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text(
          'DropShare',
          style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 20),
        ),
        actions: [
          IconButton(
            icon: _isScanning
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Color(0xFF007AFF)),
                  )
                : const Icon(Icons.refresh, color: Color(0xFF007AFF)),
            onPressed: _isScanning ? null : _scan,
          ),
          PopupMenuButton<ThemeMode>(
            icon: const Icon(Icons.brightness_4, color: Color(0xFF007AFF)),
            onSelected: (ThemeMode mode) {
              widget.onThemeModeChanged?.call(mode);
            },
            itemBuilder: (BuildContext context) => [
              const PopupMenuItem<ThemeMode>(
                value: ThemeMode.light,
                child: Text('ライトモード'),
              ),
              const PopupMenuItem<ThemeMode>(
                value: ThemeMode.dark,
                child: Text('ダークモード'),
              ),
              const PopupMenuItem<ThemeMode>(
                value: ThemeMode.system,
                child: Text('システム設定に従う'),
              ),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _scan,
        backgroundColor: const Color(0xFF1C1C1E),
        color: const Color(0xFF007AFF),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_transferProgress != null)
              LinearProgressIndicator(
                value: _transferProgress,
                backgroundColor: const Color(0xFF1C1C1E),
                color: const Color(0xFF007AFF),
              ),
          if (_statusMessage != null)
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(_statusMessage!,
                  style:
                      const TextStyle(color: Colors.white70, fontSize: 13)),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              _devices.isEmpty
                  ? _isScanning
                      ? 'デバイスを検索中...'
                      : '近くにデバイスが見つかりません'
                  : '近くのデバイス (${_devices.length}台)',
              style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 13,
                  fontWeight: FontWeight.w500),
            ),
          ),
          if (_devices.isEmpty && !_isScanning)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.wifi_find,
                        size: 64,
                        color: Colors.white.withOpacity(0.2)),
                    const SizedBox(height: 16),
                    Text(
                      '同じWiFiに接続されている\nデバイスが表示されます',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.4),
                          fontSize: 14),
                    ),
                  ],
                ),
              ),
            )
          else
            SizedBox(
              height: 130,
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                scrollDirection: Axis.horizontal,
                itemCount: _devices.length,
                itemBuilder: (ctx, i) => DeviceCard(
                  device: _devices[i],
                  onTap: () => _sendFileTo(_devices[i]),
                ),
              ),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'このデバイス',
              style: TextStyle(
                  color: Colors.white54,
                  fontSize: 13,
                  fontWeight: FontWeight.w500),
            ),
          ),
          GestureDetector(
            onTap: _showEditDeviceNameDialog,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF1C1C1E),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.devices,
                      color: Color(0xFF007AFF), size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _deviceName,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 15),
                        ),
                        Text(
                          'ファイルを受け取れる状態です',
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.5),
                              fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: Color(0xFF34C759),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.edit,
                      color: Colors.white.withOpacity(0.5), size: 20),
                ],
              ),
            ),
          ),
        ],
      ),
        ),
      ),
    );
  }
}
