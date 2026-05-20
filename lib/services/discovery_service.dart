import 'dart:async';
import 'package:bonsoir/bonsoir.dart';

class DiscoveredDevice {
  final String name;
  final String ip;
  final int port;

  DiscoveredDevice({required this.name, required this.ip, required this.port});
}

class DiscoveryService {
  static const String _serviceType = '_dropshare._tcp';
  static const int _requestPort = 47849;

  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;

  final StreamController<List<DiscoveredDevice>> _devicesController =
      StreamController<List<DiscoveredDevice>>.broadcast();
  final List<DiscoveredDevice> _devices = [];

  Stream<List<DiscoveredDevice>> get devicesStream => _devicesController.stream;
  List<DiscoveredDevice> get devices => List.unmodifiable(_devices);

  Future<void> startAdvertising(String deviceName) async {
    try {
      final service = BonsoirService(
        name: deviceName,
        type: _serviceType,
        port: _requestPort,
      );
      _broadcast = BonsoirBroadcast(service: service);
      await _broadcast!.ready;
      await _broadcast!.start();
    } catch (e) {
      // ignore: avoid_print
      print('Advertising error: $e');
    }
  }

  Future<void> startDiscovery() async {
    try {
      _discovery = BonsoirDiscovery(type: _serviceType);
      await _discovery!.ready;

      _discovery!.eventStream!.listen((event) {
        if (event.type == BonsoirDiscoveryEventType.discoveryServiceFound) {
          try {
            event.service?.resolve(_discovery!.serviceResolver);
          } catch (_) {}
        } else if (event.type ==
            BonsoirDiscoveryEventType.discoveryServiceResolved) {
          final resolved = event.service as ResolvedBonsoirService;
          final host = resolved.host;
          if (host == null) return;
          final device = DiscoveredDevice(
            name: resolved.name,
            ip: host,
            port: resolved.port,
          );
          if (!_devices.any((d) => d.ip == device.ip)) {
            _devices.add(device);
            _devicesController.add(List.from(_devices));
          }
        } else if (event.type ==
            BonsoirDiscoveryEventType.discoveryServiceLost) {
          final lost = event.service!;
          _devices.removeWhere((d) => d.name == lost.name);
          _devicesController.add(List.from(_devices));
        }
      });

      await _discovery!.start();
    } catch (e) {
      // ignore: avoid_print
      print('Discovery error: $e');
    }
  }

  Future<void> stopAdvertising() async {
    await _broadcast?.stop();
    _broadcast = null;
  }

  void stopDiscovery() {
    _discovery?.stop();
    _discovery = null;
  }

  void dispose() {
    stopDiscovery();
    _broadcast?.stop();
    _devicesController.close();
  }
}
