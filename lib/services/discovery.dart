import 'dart:async';
import 'dart:io';
import 'package:bonsoir/bonsoir.dart';

class DiscoveredDevice {
  final String name;
  final String ip;
  final int port;
  final String platform;

  DiscoveredDevice({
    required this.name,
    required this.ip,
    required this.port,
    required this.platform,
  });
}

class DiscoveryService {
  static const int _port = 47847;
  static const String _serviceType = '_dropshare._tcp';

  HttpServer? _server;
  BonsoirService? _bonsoirService;
  BonsoirDiscovery? _bonsoirDiscovery;
  final _devicesController =
      StreamController<List<DiscoveredDevice>>.broadcast();
  final List<DiscoveredDevice> _devices = [];
  Timer? _cleanupTimer;
  String? _ownIp;

  Stream<List<DiscoveredDevice>> get devicesStream =>
      _devicesController.stream;

  Future<void> startAdvertising(String deviceName) async {
    await stopAdvertising();
    _server = await HttpServer.bind(InternetAddress.anyIPv4, _port);
    _server!.listen((req) async {
      if (req.uri.path == '/info') {
        req.response
          ..headers.contentType = ContentType.json
          ..write(
              '{"name":"$deviceName","platform":"${Platform.operatingSystem}"}')
          ..close();
      } else {
        req.response.statusCode = 404;
        await req.response.close();
      }
    });

    // Bonsoirでサービスを公開
    try {
      _bonsoirService = BonsoirService(
        name: deviceName,
        type: _serviceType,
        port: _port,
        attributes: {
          'platform': Platform.operatingSystem,
        },
      );
      await _bonsoirService!.ready;
      print('[Bonjour] Service advertised: $deviceName');
    } catch (e) {
      print('[Bonjour] Failed to advertise service: $e');
    }
  }

  Future<void> startDiscovery() async {
    // Bonsoirディスカバリーを開始
    try {
      _bonsoirDiscovery = BonsoirDiscovery(type: _serviceType);
      _bonsoirDiscovery!.eventStream!.listen((event) {
        _handleBonsoirEvent(event);
      });
      await _bonsoirDiscovery!.ready;
      print('[Bonjour] Discovery started');
    } catch (e) {
      print('[Bonjour] Failed to start discovery: $e');
    }

    // フォールバック: 従来のIPスキャンも15秒ごとに実行
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      _discoverDevices();
    });
    await _discoverDevices();
  }

  void _handleBonsoirEvent(dynamic event) {
    try {
      // serviceFoundイベント
      if (event.runtimeType.toString().contains('ServiceFound')) {
        final service = event.service;
        final name = service.name ?? service.host ?? 'Unknown';
        final ip = service.ip ?? '';
        final platform = service.attributes?['platform'] ?? 'unknown';

        // 自分自身を除外
        if (ip == _ownIp) return;

        final device = DiscoveredDevice(
          name: name,
          ip: ip,
          port: service.port ?? _port,
          platform: platform,
        );

        // デバイスが既に存在するかチェック
        final exists = _devices.any((d) => d.ip == device.ip);
        if (!exists) {
          _devices.add(device);
          if (!_devicesController.isClosed) {
            _devicesController.add(List.from(_devices));
          }
          print('[Bonjour] Device found: $name ($ip)');
        }
      }
      // serviceLostイベント
      else if (event.runtimeType.toString().contains('ServiceLost')) {
        final service = event.service;
        final ip = service.ip ?? '';
        _devices.removeWhere((d) => d.ip == ip);
        if (!_devicesController.isClosed) {
          _devicesController.add(List.from(_devices));
        }
        print('[Bonjour] Device lost: $ip');
      }
      // resolutionFailedイベント
      else if (event.runtimeType.toString().contains('ResolutionFailed')) {
        print('[Bonjour] Resolution failed for service');
      }
    } catch (e) {
      print('[Bonjour] Error handling event: $e');
    }
  }

  Future<void> _discoverDevices() async {
    try {
      final interfaces =
          await NetworkInterface.list(type: InternetAddressType.IPv4);
      final subnet = _getSubnet(interfaces);
      if (subnet == null) return;

      // 自分のIPアドレスを取得
      _ownIp = _getOwnIp(interfaces);

      final newDevices = <DiscoveredDevice>[];

      await Future.wait(
        List.generate(254, (i) async {
          final ip = '$subnet.${i + 1}';

          // 自分自身のIPアドレスを除外
          if (ip == _ownIp) return;

          try {
            final socket = await Socket.connect(ip, _port,
                timeout: const Duration(milliseconds: 300));
            socket.destroy();

            final client = HttpClient();
            client.connectionTimeout = const Duration(milliseconds: 500);
            final request = await client.get(ip, _port, '/info');
            final response = await request.close();
            final body = await response
                .transform(const SystemEncoding().decoder)
                .join();
            client.close();

            final name = _parseJson(body, 'name') ?? ip;
            final platform = _parseJson(body, 'platform') ?? 'unknown';

            newDevices.add(DiscoveredDevice(
              name: name,
              ip: ip,
              port: _port,
              platform: platform,
            ));
          } catch (_) {}
        }),
      );

      _devices.clear();
      _devices.addAll(newDevices);
      if (!_devicesController.isClosed) {
        _devicesController.add(List.from(_devices));
      }
    } catch (_) {}
  }

  String? _getSubnet(List<NetworkInterface> interfaces) {
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        if (!addr.isLoopback &&
            addr.type == InternetAddressType.IPv4) {
          final parts = addr.address.split('.');
          if (parts.length == 4) {
            return '${parts[0]}.${parts[1]}.${parts[2]}';
          }
        }
      }
    }
    return null;
  }

  String? _getOwnIp(List<NetworkInterface> interfaces) {
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        if (!addr.isLoopback &&
            addr.type == InternetAddressType.IPv4) {
          return addr.address;
        }
      }
    }
    return null;
  }

  String? _parseJson(String json, String key) {
    final pattern = RegExp('"$key":"([^"]*)"');
    final match = pattern.firstMatch(json);
    return match?.group(1);
  }

  Future<void> stopAdvertising() async {
    await _server?.close(force: true);
    _server = null;
    _bonsoirService = null;
  }

  Future<void> stopDiscovery() async {
    _bonsoirDiscovery = null;
  }

  void dispose() {
    _cleanupTimer?.cancel();
    stopAdvertising();
    stopDiscovery();
    _devicesController.close();
  }
}
