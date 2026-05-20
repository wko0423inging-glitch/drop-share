import 'dart:async';
import 'dart:convert';
import 'dart:io';

class SignalingClient {
  WebSocket? _ws;
  final _ctrl = StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get messages => _ctrl.stream;

  /// Connect to relay at [url]/room/[roomCode].
  /// Returns the assigned role ('host' or 'peer').
  Future<String> connect(String relayUrl, String roomCode) async {
    _ws = await WebSocket.connect('$relayUrl/room/$roomCode');

    final roleCompleter = Completer<String>();

    _ws!.listen(
      (data) {
        final msg = jsonDecode(data as String) as Map<String, dynamic>;
        if (!roleCompleter.isCompleted && msg['type'] == 'joined') {
          roleCompleter.complete(msg['role'] as String);
        }
        _ctrl.add(msg);
      },
      onDone: () => _ctrl.add({'type': 'disconnected'}),
      onError: (e) => _ctrl.add({'type': 'error', 'error': e.toString()}),
    );

    return roleCompleter.future.timeout(const Duration(seconds: 10));
  }

  void send(Map<String, dynamic> msg) {
    if (_ws?.readyState == WebSocket.open) {
      _ws!.add(jsonEncode(msg));
    }
  }

  Future<void> dispose() async {
    await _ws?.close();
    await _ctrl.close();
  }
}
