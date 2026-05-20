import 'package:flutter/material.dart';
import '../services/discovery_service.dart';

class DeviceCard extends StatelessWidget {
  final DiscoveredDevice device;
  final VoidCallback? onTap;

  const DeviceCard({
    super.key,
    required this.device,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: disabled ? 0.4 : 1.0,
        child: Column(
          children: [
            Container(
              width: 70,
              height: 70,
              decoration: BoxDecoration(
                color: const Color(0xFF2C2C2E),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(
                Icons.phone_android,
                color: Color(0xFF007AFF),
                size: 36,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              device.name,
              style: const TextStyle(color: Colors.white, fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}