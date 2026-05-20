import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Minimal WebSocket signaling relay that runs inside the host device.
/// Clients connect to ws://HOST_IP:PORT/room/ROOMCODE and messages are
/// forwarded to all other members of the same room.
class RelayServer {
  HttpServer? _server;
  final _rooms = <String, List<WebSocket>>{};

  int get port => _server?.port ?? 0;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server!.listen(_handle);
  }

  Future<void> _handle(HttpRequest req) async {
    if (!WebSocketTransformer.isUpgradeRequest(req)) {
      req.response.statusCode = 400;
      await req.response.close();
      return;
    }
    final parts = req.uri.path.split('/');
    if (parts.length < 3 || parts[1] != 'room') {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }
    final roomCode = parts[2];
    final ws = await WebSocketTransformer.upgrade(req);
    _joinRoom(ws, roomCode);
  }

  void _joinRoom(WebSocket ws, String roomCode) {
    final room = _rooms.putIfAbsent(roomCode, () => []);
    room.add(ws);

    if (room.length == 1) {
      _send(ws, {'type': 'joined', 'role': 'host'});
    } else {
      _send(ws, {'type': 'joined', 'role': 'peer'});
      _send(room[0], {'type': 'peer_joined'});
    }

    ws.listen(
      (data) {
        final msg = jsonDecode(data as String) as Map<String, dynamic>;
        for (final other in room) {
          if (other != ws && other.readyState == WebSocket.open) {
            _send(other, msg);
          }
        }
      },
      onDone: () {
        room.remove(ws);
        if (room.isEmpty) _rooms.remove(roomCode);
        for (final other in room) {
          _send(other, {'type': 'peer_left'});
        }
      },
      onError: (_) {
        room.remove(ws);
        if (room.isEmpty) _rooms.remove(roomCode);
      },
    );
  }

  void _send(WebSocket ws, Map<String, dynamic> msg) {
    if (ws.readyState == WebSocket.open) ws.add(jsonEncode(msg));
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }
}
