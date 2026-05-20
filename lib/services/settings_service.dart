import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

class SettingsService {
  static const _fileName = 'settings.json';

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<Map<String, dynamic>> _loadAll() async {
    try {
      final f = await _file();
      if (!await f.exists()) return {};
      return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveAll(Map<String, dynamic> data) async {
    final f = await _file();
    await f.writeAsString(jsonEncode(data));
  }

  Future<String?> getDeviceName() async =>
      (await _loadAll())['deviceName'] as String?;

  Future<void> setDeviceName(String name) async {
    final data = await _loadAll();
    data['deviceName'] = name;
    await _saveAll(data);
  }
}
