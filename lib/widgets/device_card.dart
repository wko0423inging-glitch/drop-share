import 'package:flutter/material.dart';
import '../services/discovery.dart';

class DeviceCard extends StatelessWidget {
  final DiscoveredDevice device;
  final VoidCallback onTap;

  const DeviceCard({super.key, required this.device, required this.onTap});

  IconData _platformIcon(String platform) {
    switch (platform) {
      case 'android':
        return Icons.android;
      case 'ios':
        return Icons.phone_iphone;
      case 'macos':
        return Icons.laptop_mac;
      case 'windows':
        return Icons.desktop_windows;
      case 'linux':
        return Icons.computer;
      default:
        return Icons.devices;
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 100,
        margin: const EdgeInsets.symmetric(horizontal: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: const Color(0xFF1C1C1E),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: const Color(0xFF007AFF).withOpacity(0.4),
                  width: 1.5,
                ),
              ),
              child: Icon(
                _platformIcon(device.platform),
                color: const Color(0xFF007AFF),
                size: 36,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              device.name,
              style: const TextStyle(fontSize: 12, color: Colors.white),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
