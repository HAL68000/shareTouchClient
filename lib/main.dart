import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

void main() {
  runApp(const ShareTouchApp());
}

class ShareTouchApp extends StatelessWidget {
  const ShareTouchApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ShareTouch Client',
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
      ),
      home: const ConnectPage(),
    );
  }
}

class ConnectPage extends StatefulWidget {
  const ConnectPage({super.key});

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  final _serverController = TextEditingController(text: 'http://localhost:3000');
  final _sessionController = TextEditingController();

  @override
  void dispose() {
    _serverController.dispose();
    _sessionController.dispose();
    super.dispose();
  }

  Future<void> _scanQr() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScanPage()),
    );

    if (raw == null || raw.isEmpty) return;

    final uri = Uri.tryParse(raw.trim());
    if (uri != null && uri.hasScheme && uri.host.isNotEmpty) {
      final server = '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
      final session = uri.queryParameters['session'] ?? '';
      setState(() {
        _serverController.text = server;
        if (session.isNotEmpty) {
          _sessionController.text = session;
        }
      });
      return;
    }

    setState(() {
      _sessionController.text = raw.trim();
    });
  }

  void _openViewer() {
    final server = _serverController.text.trim();
    final session = _sessionController.text.trim();

    if (server.isEmpty || session.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Inserisci server e codice sessione')),
      );
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ViewerPage(
          serverBaseUrl: server,
          sessionId: session,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ShareTouch Mobile Client')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _serverController,
              decoration: const InputDecoration(
                labelText: 'Server URL',
                hintText: 'http://192.168.1.10:3000',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _sessionController,
              decoration: const InputDecoration(
                labelText: 'Codice sessione',
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _scanQr,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Scansiona QR'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _openViewer,
                    icon: const Icon(Icons.cast_connected),
                    label: const Text('Connetti'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              'Gesture supportate: tap click, drag mouse, pinch zoom (max 300%), 3 dita pan, doppio tap 2 dita = tasto Windows.',
            ),
          ],
        ),
      ),
    );
  }
}

class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key});

  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  bool _handled = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scansiona QR sessione')),
      body: MobileScanner(
        onDetect: (capture) {
          if (_handled) return;
          final code = capture.barcodes.firstOrNull?.rawValue;
          if (code == null || code.isEmpty) return;
          _handled = true;
          Navigator.of(context).pop(code);
        },
      ),
    );
  }
}

class ViewerPage extends StatefulWidget {
  const ViewerPage({
    super.key,
    required this.serverBaseUrl,
    required this.sessionId,
  });

  final String serverBaseUrl;
  final String sessionId;

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  late final ShareTouchSession _session;

  @override
  void initState() {
    super.initState();
    _session = ShareTouchSession(
      serverBaseUrl: widget.serverBaseUrl,
      sessionId: widget.sessionId,
    )..connect();
  }

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: AnimatedBuilder(
          animation: _session,
          builder: (context, _) {
            return Stack(
              children: [
                Positioned.fill(
                  child: ControlSurface(session: _session),
                ),
                Positioned(
                  top: 8,
                  left: 8,
                  child: Row(
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.55),
                          shape: BoxShape.circle,
                        ),
                        child: IconButton(
                          onPressed: () => Navigator.of(context).maybePop(),
                          tooltip: 'Chiudi viewer',
                          icon: const Icon(Icons.arrow_back),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class ControlSurface extends StatefulWidget {
  const ControlSurface({super.key, required this.session});

  final ShareTouchSession session;

  @override
  State<ControlSurface> createState() => _ControlSurfaceState();
}

class _ControlSurfaceState extends State<ControlSurface> {
  final Map<int, Offset> _pointers = {};

  DateTime? _singleDownAt;
  Offset? _singleDownPos;
  Offset? _lastSinglePos;
  bool _singleTapEligible = false;

  bool _twoFingerActive = false;
  bool _twoFingerMoved = false;
  DateTime? _twoFingerStartAt;
  double _twoFingerStartDistance = 0;
  double _twoFingerStartScale = 1;

  DateTime? _lastTwoFingerTapAt;

  Offset? _threeFingerStartCenter;
  Offset _panStart = Offset.zero;

  double _scale = 1;
  Offset _pan = Offset.zero;

  static const double _minZoom = 1;
  static const double _maxZoom = 3;

  static const int _singleTapMaxMs = 260;
  static const double _singleTapMaxMove = 18;

  static const int _twoFingerTapMaxMs = 380;
  static const int _twoFingerDoubleGapMs = 700;
  static const double _twoFingerTapMaxDistanceChange = 28;

  Offset _centerOf(List<Offset> points) {
    double sx = 0;
    double sy = 0;
    for (final p in points) {
      sx += p.dx;
      sy += p.dy;
    }
    return Offset(sx / points.length, sy / points.length);
  }

  double _distance(Offset a, Offset b) {
    final dx = a.dx - b.dx;
    final dy = a.dy - b.dy;
    return math.sqrt(dx * dx + dy * dy);
  }

  Offset _clampPan(Offset pan, Size size, double scale) {
    if (scale <= _minZoom) return Offset.zero;
    final maxX = ((scale - 1) * size.width) / 2;
    final maxY = ((scale - 1) * size.height) / 2;
    return Offset(
      pan.dx.clamp(-maxX, maxX),
      pan.dy.clamp(-maxY, maxY),
    );
  }

  Offset _normalizedFromLocal(Offset local, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    final adjustedX = cx + (local.dx - cx - _pan.dx) / _scale;
    final adjustedY = cy + (local.dy - cy - _pan.dy) / _scale;

    return Offset(
      (adjustedX / size.width).clamp(0.0, 1.0),
      (adjustedY / size.height).clamp(0.0, 1.0),
    );
  }

  void _handlePointerDown(PointerDownEvent event, Size size) {
    _pointers[event.pointer] = event.localPosition;

    final count = _pointers.length;
    if (count == 1) {
      _singleTapEligible = true;
      _singleDownAt = DateTime.now();
      _singleDownPos = event.localPosition;
      _lastSinglePos = event.localPosition;
      return;
    }

    _singleTapEligible = false;

    if (count == 2) {
      final points = _pointers.values.toList(growable: false);
      _twoFingerActive = true;
      _twoFingerMoved = false;
      _twoFingerStartAt = DateTime.now();
      _twoFingerStartDistance = _distance(points[0], points[1]);
      _twoFingerStartScale = _scale;
      return;
    }

    if (count == 3) {
      final center = _centerOf(_pointers.values.toList(growable: false));
      _threeFingerStartCenter = center;
      _panStart = _pan;
    }
  }

  void _handlePointerMove(PointerMoveEvent event, Size size) {
    _pointers[event.pointer] = event.localPosition;

    final count = _pointers.length;
    if (count == 1) {
      final current = _pointers.values.first;
      final normalized = _normalizedFromLocal(current, size);

      final prev = _lastSinglePos;
      final dx = prev == null ? 0.0 : current.dx - prev.dx;
      final dy = prev == null ? 0.0 : current.dy - prev.dy;

      _lastSinglePos = current;
      widget.session.sendMove(normalized.dx, normalized.dy, dx, dy);
      return;
    }

    if (count == 2) {
      final points = _pointers.values.toList(growable: false);
      final dist = _distance(points[0], points[1]);
      if ((dist - _twoFingerStartDistance).abs() > _twoFingerTapMaxDistanceChange) {
        _twoFingerMoved = true;
      }

      if (_twoFingerStartDistance > 0) {
        final nextScale = (_twoFingerStartScale * (dist / _twoFingerStartDistance))
            .clamp(_minZoom, _maxZoom);
        setState(() {
          _scale = nextScale;
          _pan = _clampPan(_pan, size, _scale);
        });
      }
      return;
    }

    if (count == 3 && _scale > _minZoom && _threeFingerStartCenter != null) {
      final center = _centerOf(_pointers.values.toList(growable: false));
      final delta = center - _threeFingerStartCenter!;
      setState(() {
        _pan = _clampPan(_panStart + delta, size, _scale);
      });
    }
  }

  void _handlePointerUp(PointerUpEvent event, Size size) {
    final oldCount = _pointers.length;
    final upPos = _pointers[event.pointer] ?? event.localPosition;
    _pointers.remove(event.pointer);
    final newCount = _pointers.length;

    if (oldCount == 2 && newCount < 2 && _twoFingerActive) {
      final now = DateTime.now();
      final dt = now.difference(_twoFingerStartAt ?? now).inMilliseconds;
      final isTap = dt <= _twoFingerTapMaxMs && !_twoFingerMoved;

      if (isTap) {
        final last = _lastTwoFingerTapAt;
        if (last != null && now.difference(last).inMilliseconds <= _twoFingerDoubleGapMs) {
          widget.session.sendMeta();
          _lastTwoFingerTapAt = null;
        } else {
          _lastTwoFingerTapAt = now;
          widget.session.setStatus('Primo tap a 2 dita rilevato');
        }
      } else {
        _lastTwoFingerTapAt = null;
      }

      _twoFingerActive = false;
      _twoFingerMoved = false;
    }

    if (oldCount == 1 && newCount == 0 && _singleTapEligible) {
      final downAt = _singleDownAt;
      final downPos = _singleDownPos;

      if (downAt != null && downPos != null) {
        final elapsed = DateTime.now().difference(downAt).inMilliseconds;
        final moved = (upPos - downPos).distance;
        if (elapsed <= _singleTapMaxMs && moved <= _singleTapMaxMove) {
          final normalized = _normalizedFromLocal(upPos, size);
          widget.session.sendClick(normalized.dx, normalized.dy);
        }
      }
    }

    if (newCount == 0) {
      _singleTapEligible = false;
      _singleDownAt = null;
      _singleDownPos = null;
      _lastSinglePos = null;
      _threeFingerStartCenter = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final renderer = widget.session.renderer;

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);

        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) => _handlePointerDown(e, size),
          onPointerMove: (e) => _handlePointerMove(e, size),
          onPointerUp: (e) => _handlePointerUp(e, size),
          onPointerCancel: (e) {
            _pointers.remove(e.pointer);
          },
          child: Stack(
            children: [
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black,
                  child: Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()
                      ..translate(_pan.dx, _pan.dy)
                      ..scale(_scale, _scale),
                    child: RTCVideoView(
                      renderer,
                      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Text(
                      'Tap click · Drag move · Zoom ${(100 * _scale).round()}% · 3 dita pan · doppio tap 2 dita = Windows',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class ShareTouchSession extends ChangeNotifier {
  ShareTouchSession({
    required this.serverBaseUrl,
    required this.sessionId,
  });

  final String serverBaseUrl;
  final String sessionId;

  final RTCVideoRenderer renderer = RTCVideoRenderer();

  io.Socket? _socket;
  RTCPeerConnection? _pc;
  bool _remoteDescriptionSet = false;
  final List<RTCIceCandidate> _pendingRemoteCandidates = [];
  MediaStream? _remoteVideoStream;
  Completer<void>? _iceGatheringCompleter;
  static const bool _trickleIceEnabled = false;

  String status = 'Connessione in corso...';

  Future<void> connect() async {
    await renderer.initialize();

    final socket = io.io(
      serverBaseUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect()
          .enableForceNew()
          .build(),
    );

    _socket = socket;

    socket.onConnect((_) {
      setStatus('Socket connesso, join sessione...');
      socket.emit('mobile:join-session', {'sessionId': sessionId});
    });

    socket.on('mobile:join-failed', (data) {
      final reason = (data is Map && data['reason'] != null)
          ? data['reason'].toString()
          : 'Join fallito';
      setStatus(reason);
    });

    socket.on('mobile:joined', (_) {
      setStatus('Connesso. In attesa stream desktop...');
    });

    socket.on('webrtc:signal', (data) async {
      if (data is! Map) return;
      final from = data['from']?.toString();
      if (from != 'desktop') return;
      final signal = data['signal'];
      if (signal is! Map) return;
      await _handleDesktopSignal(Map<String, dynamic>.from(signal));
    });

    socket.on('session:ended', (_) {
      setStatus('Sessione terminata dal desktop');
    });

    socket.onDisconnect((_) {
      setStatus('Disconnesso dal server');
    });

    socket.connect();
  }

  Future<void> _ensurePeerConnection() async {
    if (_pc != null) return;

    _pc = await createPeerConnection({
      'sdpSemantics': 'unified-plan',
      'iceServers': [
        {
          'urls': [
            'stun:stun.l.google.com:19302',
            'stun:stun1.l.google.com:19302',
          ]
        }
      ],
      'iceCandidatePoolSize': 6,
    });

    _pc!.onIceCandidate = (candidate) {
      if (!_trickleIceEnabled) return;

      final value = candidate.candidate;
      if (value == null || value.isEmpty) return;

      _socket?.emit('webrtc:signal', {
        'sessionId': sessionId,
        'from': 'mobile',
        'signal': {
          'candidate': value,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        }
      });
    };

    _pc!.onTrack = (event) async {
      await _attachIncomingTrack(event);
    };

    _pc!.onAddStream = (stream) {
      _attachIncomingStream(stream);
    };

    _pc!.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        setStatus('Stream connesso');
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateConnecting) {
        setStatus('Connessione WebRTC in corso...');
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        setStatus('Connessione WebRTC fallita');
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        setStatus('Connessione WebRTC interrotta');
      }
    };

    _pc!.onIceConnectionState = (state) {
      if (state == RTCIceConnectionState.RTCIceConnectionStateChecking) {
        setStatus('Verifica percorso di rete WebRTC...');
      } else if (state ==
          RTCIceConnectionState.RTCIceConnectionStateConnected) {
        setStatus('Rete WebRTC collegata');
      } else if (state ==
          RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        setStatus('Negoziazione WebRTC completata');
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        setStatus('ICE fallito: nessun percorso media trovato');
      }
    };

    _pc!.onIceGatheringState = (state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
        _iceGatheringCompleter?.complete();
        _iceGatheringCompleter = null;
      }
    };
  }

  Future<void> _waitForIceGatheringComplete({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final pc = _pc;
    if (pc == null) return;

    if (pc.iceGatheringState ==
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      return;
    }

    final completer = Completer<void>();
    _iceGatheringCompleter = completer;

    try {
      await completer.future.timeout(timeout);
    } catch (_) {
      setStatus('ICE non completo entro timeout, invio SDP comunque');
    } finally {
      if (identical(_iceGatheringCompleter, completer)) {
        _iceGatheringCompleter = null;
      }
    }
  }

  Future<void> _attachIncomingTrack(RTCTrackEvent event) async {
    if (event.track.kind != 'video') return;

    if (event.streams.isNotEmpty) {
      _attachIncomingStream(event.streams.first);
      return;
    }

    _remoteVideoStream ??= await createLocalMediaStream('remote-video');
    _remoteVideoStream!.addTrack(event.track);
    renderer.srcObject = _remoteVideoStream;
    setStatus('Stream video agganciato');
    notifyListeners();
  }

  void _attachIncomingStream(MediaStream stream) {
    renderer.srcObject = stream;
    _remoteVideoStream = stream;
    setStatus('Stream attivo');
    notifyListeners();
  }

  Future<void> _handleDesktopSignal(Map<String, dynamic> signal) async {
    await _ensurePeerConnection();

    final candidate = signal['candidate']?.toString();
    if (candidate != null && candidate.isNotEmpty) {
      final sdpMid = signal['sdpMid']?.toString();
      final sdpMLineIndex = signal['sdpMLineIndex'];
      final midLineIndex = sdpMLineIndex is int
          ? sdpMLineIndex
          : int.tryParse(sdpMLineIndex?.toString() ?? '');

      final iceCandidate = RTCIceCandidate(candidate, sdpMid, midLineIndex);

      if (!_remoteDescriptionSet) {
        _pendingRemoteCandidates.add(iceCandidate);
        setStatus('Candidate ICE ricevuta, in attesa della descrizione remota');
        return;
      }

      await _pc!.addCandidate(iceCandidate);
      setStatus('Candidate ICE remota aggiunta');
      return;
    }

    final sdp = signal['sdp']?.toString();
    final type = signal['type']?.toString();
    if (sdp == null || type == null) return;

    final desc = RTCSessionDescription(sdp, type);
    await _pc!.setRemoteDescription(desc);
    _remoteDescriptionSet = true;
    await _flushPendingRemoteCandidates();

    if (type == 'offer') {
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);

      if (!_trickleIceEnabled) {
        await _waitForIceGatheringComplete();
      }

      final currentLocalDescription = await _pc!.getLocalDescription();
      final responseType = currentLocalDescription?.type ?? answer.type;
      final responseSdp = currentLocalDescription?.sdp ?? answer.sdp;

      _socket?.emit('webrtc:signal', {
        'sessionId': sessionId,
        'from': 'mobile',
        'signal': {
          'type': responseType,
          'sdp': responseSdp,
        }
      });
      setStatus('Risposta WebRTC inviata');
    }
  }

  Future<void> _flushPendingRemoteCandidates() async {
    if (_pc == null || !_remoteDescriptionSet || _pendingRemoteCandidates.isEmpty) {
      return;
    }

    for (final candidate in List<RTCIceCandidate>.from(_pendingRemoteCandidates)) {
      await _pc!.addCandidate(candidate);
    }
    _pendingRemoteCandidates.clear();
    setStatus('Candidate ICE remote sincronizzate');
  }

  void sendMove(double x, double y, double dxClient, double dyClient) {
    _socket?.emit('control:move', {
      'sessionId': sessionId,
      'x': x,
      'y': y,
      'dxClient': dxClient,
      'dyClient': dyClient,
    });
  }

  void sendClick(double x, double y, {int button = 1}) {
    _socket?.emit('control:click', {
      'sessionId': sessionId,
      'x': x,
      'y': y,
      'button': button,
    });
  }

  void sendMeta() {
    _socket?.emit('control:meta', {
      'sessionId': sessionId,
    });
    setStatus('Tasto Windows inviato');
  }

  void setStatus(String next) {
    status = next;
    notifyListeners();
  }

  @override
  Future<void> dispose() async {
    _remoteDescriptionSet = false;
    _pendingRemoteCandidates.clear();
    _iceGatheringCompleter = null;

    try {
      await _pc?.close();
    } catch (_) {}
    _pc = null;

    _socket?.disconnect();
    _socket?.dispose();

    try {
      await _remoteVideoStream?.dispose();
    } catch (_) {}
    _remoteVideoStream = null;

    try {
      await renderer.dispose();
    } catch (_) {}

    super.dispose();
  }
}
