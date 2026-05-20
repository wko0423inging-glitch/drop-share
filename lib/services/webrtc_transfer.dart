import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path_provider/path_provider.dart';
import 'signaling_client.dart';

typedef WebRTCProgressCallback = void Function(
    String fileName, int received, int total);
typedef WebRTCCompleteCallback = void Function(
    String fileName, String filePath);

const _iceConfig = {
  'iceServers': [
    {'urls': 'stun:stun.l.google.com:19302'},
    {'urls': 'stun:stun1.l.google.com:19302'},
    {
      'urls': [
        'turn:openrelay.metered.ca:80',
        'turn:openrelay.metered.ca:443',
        'turns:openrelay.metered.ca:443',
      ],
      'username': 'openrelayproject',
      'credential': 'openrelayproject',
    },
  ],
  'iceCandidatePoolSize': 10,
};

const _chunkSize = 16 * 1024;

class WebRTCTransferService {
  final SignalingClient _signaling;

  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;

  // Receive state — chunks streamed directly to disk, no in-memory accumulation
  String? _rxFileName;
  int _rxTotal = 0;
  int _rxReceived = 0;
  IOSink? _rxSink;
  String? _rxFilePath;
  Directory? _saveDir;

  // Send cancel flag
  bool _cancelRequested = false;

  WebRTCProgressCallback? onReceiveProgress;
  WebRTCCompleteCallback? onReceiveComplete;
  void Function()? onReceiveCancelled;

  WebRTCTransferService(this._signaling);

  Future<void> init({required bool isHost}) async {
    _saveDir = await _resolveDir();

    _pc = await createPeerConnection(_iceConfig);

    _pc!.onIceCandidate = (candidate) {
      _signaling.send({'type': 'ice', 'candidate': candidate.toMap()});
    };

    _pc!.onDataChannel = (channel) {
      _dc = channel;
      _attachDataChannelListeners(channel);
    };

    _signaling.messages.listen(_onSignal);

    if (isHost) {
      _dc = await _pc!.createDataChannel(
        'file',
        RTCDataChannelInit()
          ..ordered = true
          ..maxRetransmits = -1,
      );
      _attachDataChannelListeners(_dc!);

      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      _signaling.send({'type': 'offer', 'sdp': offer.sdp});
    }
  }

  static Future<Directory> _resolveDir() async {
    if (Platform.isAndroid) {
      final ext = await getExternalStorageDirectory();
      if (ext != null) return ext;
    }
    return getApplicationDocumentsDirectory();
  }

  void _attachDataChannelListeners(RTCDataChannel dc) {
    dc.onMessage = _onMessage;
  }

  void _onMessage(RTCDataChannelMessage msg) {
    if (msg.isBinary) {
      if (_rxSink == null) return;
      _rxSink!.add(msg.binary);
      _rxReceived += msg.binary.length;
      onReceiveProgress?.call(_rxFileName!, _rxReceived, _rxTotal);

      if (_rxReceived >= _rxTotal) {
        final sink = _rxSink!;
        final path = _rxFilePath!;
        final name = _rxFileName!;
        _rxSink = null;
        _rxFilePath = null;
        _rxFileName = null;
        _rxTotal = 0;
        _rxReceived = 0;
        sink.close().then((_) => onReceiveComplete?.call(name, path));
      }
    } else {
      final text = msg.text;
      if (text == 'CANCEL') {
        _abortReceive();
        onReceiveCancelled?.call();
        return;
      }
      // Metadata header: "fileName|fileSize"
      final parts = text.split('|');
      if (parts.length >= 2 && _saveDir != null) {
        _rxFileName = parts[0];
        _rxTotal = int.tryParse(parts[1]) ?? 0;
        _rxReceived = 0;
        _rxFilePath = '${_saveDir!.path}/$_rxFileName';
        _rxSink = File(_rxFilePath!).openWrite();
      }
    }
  }

  void _abortReceive() {
    final sink = _rxSink;
    final path = _rxFilePath;
    _rxSink = null;
    _rxFilePath = null;
    _rxFileName = null;
    _rxTotal = 0;
    _rxReceived = 0;
    sink?.close().then((_) {
      if (path != null) File(path).delete().ignore();
    });
  }

  Future<void> _onSignal(Map<String, dynamic> msg) async {
    switch (msg['type']) {
      case 'offer':
        await _pc!.setRemoteDescription(
            RTCSessionDescription(msg['sdp'] as String, 'offer'));
        final answer = await _pc!.createAnswer();
        await _pc!.setLocalDescription(answer);
        _signaling.send({'type': 'answer', 'sdp': answer.sdp});
        break;
      case 'answer':
        await _pc!.setRemoteDescription(
            RTCSessionDescription(msg['sdp'] as String, 'answer'));
        break;
      case 'ice':
        final c = msg['candidate'] as Map<String, dynamic>;
        await _pc!.addCandidate(RTCIceCandidate(
          c['candidate'] as String?,
          c['sdpMid'] as String?,
          c['sdpMLineIndex'] as int?,
        ));
        break;
    }
  }

  Future<void> waitForConnection(
      {Duration timeout = const Duration(seconds: 30)}) async {
    if (_dc?.state == RTCDataChannelState.RTCDataChannelOpen) return;
    final completer = Completer<void>();
    final prev = _dc?.onDataChannelState;
    _dc?.onDataChannelState = (state) {
      prev?.call(state);
      if (state == RTCDataChannelState.RTCDataChannelOpen &&
          !completer.isCompleted) {
        completer.complete();
      }
    };
    await completer.future.timeout(timeout);
  }

  void cancelSend() {
    _cancelRequested = true;
    _dc?.send(RTCDataChannelMessage('CANCEL'));
  }

  Future<void> sendFile({
    required String fileName,
    required int fileSize,
    required Stream<List<int>> fileStream,
    void Function(double progress)? onProgress,
  }) async {
    _cancelRequested = false;
    await waitForConnection();
    final dc = _dc!;

    dc.send(RTCDataChannelMessage('$fileName|$fileSize'));

    int sent = 0;
    outer:
    await for (final chunk in fileStream) {
      for (var i = 0; i < chunk.length; i += _chunkSize) {
        if (_cancelRequested) break outer;
        final end = (i + _chunkSize).clamp(0, chunk.length);
        final slice = Uint8List.fromList(chunk.sublist(i, end));
        dc.send(RTCDataChannelMessage.fromBinary(slice));
        sent += slice.length;
        onProgress?.call(sent / fileSize);
        await Future.delayed(Duration.zero);
      }
    }
    if (!_cancelRequested) onProgress?.call(1.0);
  }

  Future<void> dispose() async {
    _abortReceive();
    await _dc?.close();
    await _pc?.close();
    await _signaling.dispose();
  }
}
