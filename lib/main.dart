// ignore_for_file: library_private_types_in_public_api
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:wakelock_plus/wakelock_plus.dart';

// ---------------------------------------------------------------------------
// Data model: saved host entry
// ---------------------------------------------------------------------------

class HostEntry {
  const HostEntry({required this.serverUrl, required this.label});

  final String serverUrl;
  final String label;

  @override
  bool operator ==(Object other) =>
      other is HostEntry && other.serverUrl == serverUrl;

  @override
  int get hashCode => serverUrl.hashCode;

  String toPrefsString() => '$serverUrl|$label';

  static HostEntry? fromPrefsString(String s) {
    final parts = s.split('|');
    if (parts.length < 2 || parts[0].isEmpty) return null;
    return HostEntry(serverUrl: parts[0], label: parts.sublist(1).join('|'));
  }
}

// ---------------------------------------------------------------------------
// Favorites store (singleton, persisted via shared_preferences)
// ---------------------------------------------------------------------------

class FavoritesStore extends ChangeNotifier {
  FavoritesStore._();

  static final FavoritesStore instance = FavoritesStore._();

  static const _prefsKey = 'sharetouch_favorites';

  List<HostEntry> _favorites = [];
  List<HostEntry> get favorites => List.unmodifiable(_favorites);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_prefsKey) ?? [];
    _favorites = raw
        .map(HostEntry.fromPrefsString)
        .whereType<HostEntry>()
        .toList();
    notifyListeners();
  }

  Future<void> add(HostEntry entry) async {
    if (_favorites.contains(entry)) return;
    _favorites = [..._favorites, entry];
    await _persist();
    notifyListeners();
  }

  Future<void> remove(HostEntry entry) async {
    _favorites = _favorites.where((e) => e != entry).toList();
    await _persist();
    notifyListeners();
  }

  bool contains(HostEntry entry) => _favorites.contains(entry);

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _prefsKey, _favorites.map((e) => e.toPrefsString()).toList());
  }
}

// ---------------------------------------------------------------------------
// Subnet scanner: discovers open TCP ports on the local /24 network
// ---------------------------------------------------------------------------

class _ScanProgress {
  const _ScanProgress({
    required this.scanned,
    required this.total,
    required this.found,
  });

  final int scanned;
  final int total;
  final List<String> found;
}

class SubnetScanner {
  static Future<String?> getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}
    return null;
  }

  Stream<_ScanProgress> scan(String localIp, int port) async* {
    final parts = localIp.split('.');
    if (parts.length != 4) return;
    final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
    const batchSize = 25;
    const scanTimeout = Duration(milliseconds: 400);
    final found = <String>[];
    int scanned = 0;

    for (int batchStart = 0; batchStart < 256; batchStart += batchSize) {
      final end = math.min(batchStart + batchSize, 256);
      final futures = List.generate(end - batchStart, (i) async {
        final ip = '$prefix.${batchStart + i}';
        try {
          final socket = await Socket.connect(ip, port, timeout: scanTimeout);
          socket.destroy();
          return ip;
        } catch (_) {
          return null;
        }
      });
      final results = await Future.wait(futures);
      scanned += futures.length;
      for (final r in results) {
        if (r != null) found.add(r);
      }
      yield _ScanProgress(
        scanned: scanned,
        total: 256,
        found: List.from(found),
      );
    }
  }
}

// ---------------------------------------------------------------------------

void main() {
  runApp(const ShareTouchApp());
}

class ShareTouchApp extends StatefulWidget {
  const ShareTouchApp({super.key});

  @override
  State<ShareTouchApp> createState() => _ShareTouchAppState();
}

class _ShareTouchAppState extends State<ShareTouchApp> {
  @override
  void initState() {
    super.initState();
    FavoritesStore.instance.load();
  }

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

  Future<void> _openDiscovery() async {
    final result = await Navigator.of(context).push<_DiscoveryResult>(
      MaterialPageRoute(builder: (_) => const HostDiscoveryPage()),
    );
    if (result == null) return;
    setState(() {
      _serverController.text = result.serverUrl;
      _sessionController.text = result.sessionId;
    });
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
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _openDiscovery,
                icon: const Icon(Icons.wifi_find),
                label: const Text('Cerca host / Preferiti'),
              ),
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

// ---------------------------------------------------------------------------
// Host discovery result passed back to ConnectPage
// ---------------------------------------------------------------------------

class _DiscoveryResult {
  const _DiscoveryResult({required this.serverUrl, required this.sessionId});

  final String serverUrl;
  final String sessionId;
}

// ---------------------------------------------------------------------------
// Host Discovery Page
// ---------------------------------------------------------------------------

class HostDiscoveryPage extends StatefulWidget {
  const HostDiscoveryPage({super.key});

  @override
  State<HostDiscoveryPage> createState() => _HostDiscoveryPageState();
}

class _HostDiscoveryPageState extends State<HostDiscoveryPage> {
  final _urlController = TextEditingController(text: 'http://');

  // Manual Socket.IO search state
  _DiscoverySession? _session;
  List<_ActiveSession> _results = [];
  bool _searching = false;
  String? _error;

  // Subnet scan state
  bool _scanning = false;
  _ScanProgress? _scanProgress;
  List<String> _foundHosts = [];
  StreamSubscription<_ScanProgress>? _scanSubscription;

  @override
  void initState() {
    super.initState();
    FavoritesStore.instance.addListener(_onFavoritesChanged);
  }

  void _onFavoritesChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    FavoritesStore.instance.removeListener(_onFavoritesChanged);
    _scanSubscription?.cancel();
    _session?.dispose();
    _urlController.dispose();
    super.dispose();
  }

  int _extractPort(String url) {
    try {
      final uri = Uri.parse(url.trim());
      if (uri.hasPort) return uri.port;
    } catch (_) {}
    return 3000;
  }

  // ---- Manual Socket.IO search ----

  Future<void> _search() async {
    final url = _urlController.text.trim();
    if (url.isEmpty || url == 'http://') {
      setState(() => _error = 'Inserisci un URL server valido');
      return;
    }

    _session?.dispose();
    setState(() {
      _searching = true;
      _error = null;
      _results = [];
    });

    final session = _DiscoverySession(serverUrl: url);
    _session = session;

    try {
      final results = await session.fetchActiveSessions();
      if (!mounted) return;
      setState(() {
        _results = results;
        _searching = false;
        if (results.isEmpty) _error = 'Nessuna sessione attiva trovata';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _error = 'Errore connessione: $e';
      });
    }
  }

  // ---- Subnet scan ----

  Future<void> _startScan() async {
    _scanSubscription?.cancel();
    setState(() {
      _scanning = true;
      _scanProgress = null;
      _foundHosts = [];
      _error = null;
      _results = [];
    });

    final localIp = await SubnetScanner.getLocalIp();
    if (!mounted) return;

    if (localIp == null) {
      setState(() {
        _scanning = false;
        _error = "Impossibile determinare l'indirizzo IP locale";
      });
      return;
    }

    final port = _extractPort(_urlController.text);

    _scanSubscription = SubnetScanner().scan(localIp, port).listen(
      (progress) {
        if (!mounted) return;
        setState(() {
          _scanProgress = progress;
          _foundHosts = progress.found;
          if (progress.scanned >= progress.total) {
            _scanning = false;
            if (progress.found.isEmpty) {
              _error = 'Nessun host trovato sulla porta $port';
            }
          }
        });
      },
      onDone: () {
        if (!mounted) return;
        setState(() => _scanning = false);
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _scanning = false;
          _error = 'Errore scansione: $e';
        });
      },
      cancelOnError: true,
    );
  }

  void _cancelScan() {
    _scanSubscription?.cancel();
    setState(() => _scanning = false);
  }

  // When user taps a found host, auto-query its sessions
  void _selectFoundHost(String ip) {
    final port = _extractPort(_urlController.text);
    setState(() {
      _urlController.text = 'http://$ip:$port';
      _results = [];
      _error = null;
    });
    _search();
  }

  void _connectTo(_ActiveSession active) {
    Navigator.of(context).pop(
      _DiscoveryResult(
        serverUrl: _urlController.text.trim(),
        sessionId: active.sessionId,
      ),
    );
  }

  Future<void> _toggleFavorite(String serverUrl, String label) async {
    final entry = HostEntry(serverUrl: serverUrl, label: label);
    if (FavoritesStore.instance.contains(entry)) {
      await FavoritesStore.instance.remove(entry);
    } else {
      await FavoritesStore.instance.add(entry);
    }
  }

  void _loadFavorite(HostEntry entry) {
    setState(() {
      _urlController.text = entry.serverUrl;
      _results = [];
      _foundHosts = [];
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final favorites = FavoritesStore.instance.favorites;
    final currentUrl = _urlController.text.trim();
    final isFavorite = favorites.any((e) => e.serverUrl == currentUrl);
    final port = _extractPort(currentUrl);
    final progress = _scanProgress;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cerca host / Preferiti'),
        actions: [
          IconButton(
            tooltip: isFavorite
                ? 'Rimuovi dai preferiti'
                : 'Aggiungi ai preferiti',
            icon: Icon(
              isFavorite ? Icons.star : Icons.star_border,
              color: isFavorite ? Colors.amber : null,
            ),
            onPressed: () {
              final url = _urlController.text.trim();
              if (url.isEmpty || url == 'http://') return;
              _toggleFavorite(url, url);
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          // ---- URL field + manual search ----
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlController,
                    decoration: const InputDecoration(
                      labelText: 'Server URL',
                      hintText: 'http://192.168.1.10:3000',
                    ),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: (_searching || _scanning) ? null : _search,
                  icon: _searching
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.search),
                  label: const Text('Cerca'),
                ),
              ],
            ),
          ),
          // ---- Subnet scan button ----
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _scanning
                    ? _cancelScan
                    : (_searching ? null : _startScan),
                icon: Icon(_scanning ? Icons.stop : Icons.wifi_find),
                label: Text(
                  _scanning
                      ? 'Annulla scansione'
                      : 'Scansiona rete locale (porta $port)',
                ),
              ),
            ),
          ),
          // ---- Scan progress bar ----
          if (_scanning || progress != null) ...[
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(
                    value: progress == null
                        ? null
                        : progress.scanned / progress.total,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    progress == null
                        ? 'Rilevamento IP locale...'
                        : '${progress.scanned}/${progress.total} IP scansionati'
                            '${progress.found.isEmpty ? "" : " \u00b7 ${progress.found.length} trovati"}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
          // ---- Found hosts from TCP scan ----
          if (_foundHosts.isNotEmpty) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                'Host trovati (porta $port)',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            ..._foundHosts.map(
              (ip) => ListTile(
                leading: const Icon(Icons.computer),
                title: Text('http://$ip:$port'),
                trailing: FilledButton.tonal(
                  onPressed: () => _selectFoundHost(ip),
                  child: const Text('Interroga'),
                ),
              ),
            ),
          ],
          // ---- Error message ----
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          // ---- Sessions from Socket.IO query ----
          if (_results.isNotEmpty) ...[
            const SizedBox(height: 4),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                'Sessioni attive',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            ..._results.map(
              (active) => ListTile(
                leading: const Icon(Icons.desktop_windows),
                title: Text(active.sessionId),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (active.shareLabel.isNotEmpty)
                      Text(
                        active.shareLabel,
                        style: const TextStyle(fontSize: 12),
                      ),
                    if (active.hostName.isNotEmpty)
                      Text(
                        active.hostName,
                        style: const TextStyle(fontSize: 12),
                      ),
                  ],
                ),
                trailing: FilledButton.tonal(
                  onPressed: () => _connectTo(active),
                  child: const Text('Connetti'),
                ),
              ),
            ),
          ],
          // ---- Favorites ----
          if (favorites.isNotEmpty) ...[
            const Divider(height: 24),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                'Preferiti',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            ...favorites.map(
              (fav) => ListTile(
                leading: const Icon(Icons.star, color: Colors.amber),
                title: Text(fav.label),
                subtitle: Text(
                  fav.serverUrl,
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Carica URL',
                      icon: const Icon(Icons.open_in_new),
                      onPressed: () => _loadFavorite(fav),
                    ),
                    IconButton(
                      tooltip: 'Rimuovi preferito',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () =>
                          FavoritesStore.instance.remove(fav),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Socket.IO session discovery (connects to a specific server URL)
// ---------------------------------------------------------------------------

class _ActiveSession {
  const _ActiveSession({
    required this.sessionId,
    required this.shareLabel,
    required this.hostName,
  });

  final String sessionId;
  final String shareLabel;
  final String hostName;
}

class _DiscoverySession {
  _DiscoverySession({required this.serverUrl});

  final String serverUrl;
  io.Socket? _socket;

  Future<List<_ActiveSession>> fetchActiveSessions({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final completer = Completer<List<_ActiveSession>>();

    final socket = io.io(
      serverUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect()
          .enableForceNew()
          .build(),
    );
    _socket = socket;

    void abort(String reason) {
      if (!completer.isCompleted) completer.completeError(reason);
    }

    Timer? timer;

    socket.onConnect((_) {
      timer = Timer(timeout, () => abort('Timeout risposta server'));
      socket.emit('mobile:list-sessions');
    });

    socket.on('mobile:sessions-list', (data) {
      timer?.cancel();
      final sessions = <_ActiveSession>[];
      if (data is List) {
        for (final item in data) {
          if (item is Map) {
            final id = item['sessionId']?.toString() ?? '';
            final shareLabel = item['shareLabel']?.toString() ?? '';
            final host = item['hostName']?.toString() ?? '';
            if (id.isNotEmpty) {
              sessions.add(
                _ActiveSession(
                  sessionId: id,
                  shareLabel: shareLabel,
                  hostName: host,
                ),
              );
            }
          }
        }
      }
      if (!completer.isCompleted) completer.complete(sessions);
    });

    socket.onConnectError((e) => abort('Connessione rifiutata: $e'));
    socket.onError((e) => abort('Errore socket: $e'));
    socket.onDisconnect((_) {
      if (!completer.isCompleted) completer.complete([]);
    });

    socket.connect();

    try {
      return await completer.future.timeout(timeout);
    } finally {
      timer?.cancel();
      dispose();
    }
  }

  void dispose() {
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
  }
}

// ---------------------------------------------------------------------------

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
    WakelockPlus.enable();
    _session = ShareTouchSession(
      serverBaseUrl: widget.serverBaseUrl,
      sessionId: widget.sessionId,
    )..connect();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
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
                      ..translateByDouble(_pan.dx, _pan.dy, 0, 1)
                      ..scaleByDouble(_scale, _scale, 1, 1),
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
                      'Tap click \u00b7 Drag move \u00b7 Zoom ${(100 * _scale).round()}% \u00b7 3 dita pan \u00b7 doppio tap 2 dita = Windows',
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
