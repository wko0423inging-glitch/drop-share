import 'dart:async';
import 'dart:io';

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

  HttpServer? _server;
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
  }

  Future<void> startDiscovery() async {
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      _discoverDevices();
    });
    await _discoverDevices();
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
  }

  void dispose() {
    _cleanupTimer?.cancel();
    stopAdvertising();
    _devicesController.close();
  }
}
