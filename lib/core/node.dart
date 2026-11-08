import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'account.dart';
import 'crypto.dart';
import 'manifest.dart';

const int defaultPort = 47800;
const int _workersPerPeer = 4;
const Duration _clockTolerance = Duration(minutes: 5);
const Duration _onlineWindow = Duration(seconds: 12);

enum ItemStatus { seeding, finished, downloading, stalled, paused, available, unreachable, missing }

class DeviceInfo {
  DeviceInfo(this.id, this.name, this.platform, this.addrs);
  final String id;
  final String name;
  final String platform;
  List<String> addrs;

  Map<String, Object?> toJson() =>
      {'id': id, 'name': name, 'platform': platform, 'addrs': addrs};
  factory DeviceInfo.fromJson(Map<String, Object?> j) => DeviceInfo(
      j['id'] as String,
      j['name'] as String,
      j['platform'] as String,
      (j['addrs'] as List).cast<String>());
}

class CatalogEntry {
  CatalogEntry(this.id, this.name, this.size, this.addedBy, this.addedAt,
      this.updatedAt, this.removed, this.sig);
  final String id;
  final String name;
  final int size;
  final String addedBy;
  final int addedAt;
  final int updatedAt;
  final bool removed;
  final String sig;

  Map<String, Object?> _body() => {
        'id': id,
        'name': name,
        'size': size,
        'addedBy': addedBy,
        'addedAt': addedAt,
        'updatedAt': updatedAt,
        'removed': removed,
      };
  Map<String, Object?> toJson() => {..._body(), 'sig': sig};

  factory CatalogEntry.fromJson(Map<String, Object?> j) => CatalogEntry(
      j['id'] as String,
      j['name'] as String,
      j['size'] as int,
      j['addedBy'] as String,
      j['addedAt'] as int,
      j['updatedAt'] as int,
      j['removed'] as bool,
      j['sig'] as String);

  static Uint8List _mac(List<int> key, Map<String, Object?> body) =>
      hmacSha256(key, utf8.encode('essaim-entry|${canonicalJson(body)}'));

  bool isAuthentic(List<int> key) =>
      constantTimeEq(unb64(sig), _mac(key, _body()));

  CatalogEntry signed(List<int> key) {
    final s = b64(_mac(key, _body()));
    return CatalogEntry(id, name, size, addedBy, addedAt, updatedAt, removed, s);
  }

  bool supersedes(CatalogEntry o) {
    if (updatedAt != o.updatedAt) return updatedAt > o.updatedAt;
    return removed && !o.removed;
  }
}

class _LocalFile {
  _LocalFile(this.id, this.path, this.complete, this.bits, this.mtime,
      {this.paused = false, this.sharing = true});
  final String id;
  String path;
  bool complete;
  Uint8List bits;
  int mtime;
  bool paused;

  /// False once the user marks a finished file as "Terminé".
  bool sharing;

  Map<String, Object?> toJson() => {
        'id': id,
        'path': path,
        'complete': complete,
        'bits': b64(bits),
        'mtime': mtime,
        'paused': paused,
        'sharing': sharing,
      };
  factory _LocalFile.fromJson(Map<String, Object?> j) => _LocalFile(
      j['id'] as String,
      j['path'] as String,
      j['complete'] as bool,
      unb64(j['bits'] as String),
      j['mtime'] as int,
      paused: j['paused'] as bool,
      sharing: j['sharing'] as bool? ?? true);
}

bool _bit(List<int> bits, int i) =>
    i >> 3 < bits.length && (bits[i >> 3] >> (i & 7)) & 1 == 1;
void _setBit(List<int> bits, int i) => bits[i >> 3] |= 1 << (i & 7);
Uint8List _newBits(int n) => Uint8List((n + 7) >> 3);
int _countBits(List<int> bits, int n) {
  var c = 0;
  for (var i = 0; i < n; i++) {
    if (_bit(bits, i)) c++;
  }
  return c;
}

class _Have {
  _Have(this.complete, this.bits, this.pct);
  final bool complete;
  final double pct;
  final Uint8List? bits;
  bool has(int i) =>
      complete || (bits != null && i >> 3 < bits!.length && _bit(bits!, i));
  int count(int total) => complete
      ? total
      : bits == null
          ? 0
          : _countBits(bits!, total);
}

class _Peer {
  _Peer(this.info);
  DeviceInfo info;
  DateTime? lastOk;
  DateTime nextTry = DateTime.fromMillisecondsSinceEpoch(0);
  int failures = 0;
  String? goodAddr;
  Map<String, _Have> have = {};
  bool get online =>
      lastOk != null && DateTime.now().difference(lastOk!) < _onlineWindow;
}

class _Download {
  _Download(this.manifest, this.raf);
  final Manifest manifest;
  final RandomAccessFile raf;
  final Set<int> inflight = {};
  final Map<String, int> activePerPeer = {};
  final Map<String, DateTime> banned = {};
  Future<void> writes = Future.value();
  DateTime lastSave = DateTime.now();
  bool closing = false;
}

class _Rate {
  int pending = 0;
  double perSecond = 0;
  void tick() {
    perSecond = perSecond * 0.6 + pending * 0.4;
    if (perSecond < 1024) perSecond = 0;
    pending = 0;
  }
}

class PeerProgress {
  PeerProgress(this.name, this.platform, this.online, this.progress, this.self);
  final String name;
  final String platform;
  final bool online;
  final double progress;
  final bool self;
}

class CatalogItem {
  CatalogItem(this.entry, this.status, this.progress, this.peers, this.down,
      this.up, this.localPath, this.error);
  final CatalogEntry entry;
  final ItemStatus status;
  final double progress;
  final List<PeerProgress> peers;
  final double down;
  final double up;
  final String? localPath;
  final String? error;

  /// Other online devices holding at least one piece.
  int get onlinePeers =>
      peers.where((x) => !x.self && x.online && x.progress > 0).length;

  /// Online devices, this one included, holding the complete file.
  int get onlineSeeds =>
      peers.where((x) => x.online && x.progress >= 1).length;
}

class HashingJob {
  HashingJob(this.name);
  final String name;
  double progress = 0;
}

class DeviceView {
  DeviceView(this.info, this.online, this.self, this.lastOk);
  final DeviceInfo info;
  final bool online;
  final bool self;
  final DateTime? lastOk;
}

class PairingSession {
  PairingSession(this.code, this.expires, this.addrs);
  final String code;
  final DateTime expires;
  final List<String> addrs;
  int failures = 0;
  final Map<String, Uint8List> keys = {};
  final Map<String, List<String>> pubs = {};
}

bool isTailscaleAddress(InternetAddress a) {
  final b = a.rawAddress;
  if (a.type == InternetAddressType.IPv4) {
    return b[0] == 100 && b[1] >= 64 && b[1] <= 127;
  }
  return b[0] == 0xfd && b[1] == 0x7a && b[2] == 0x11 && b[3] == 0x5c &&
      b[4] == 0xa1 && b[5] == 0xe0;
}

Future<void> _writeJson(String path, Object? value) async {
  final tmp = File('$path.tmp');
  await tmp.writeAsString(jsonEncode(value), flush: true);
  await tmp.rename(path);
}

/// One device in the swarm: serves pieces, syncs the catalogue with every
/// known peer and fetches pieces from all peers at once.
class Node {
  Node({
    required this.dataDir,
    required this.downloadsDir,
    required List<int> networkKey,
    required Vault vault,
    required this.deviceName,
    required this.platform,
    this.port = defaultPort,
    this.allowAnyNetwork = false,
    this.advertised,
    this.syncInterval = const Duration(seconds: 3),
    this.onVaultChanged,
  })  : _key = Uint8List.fromList(networkKey),
        _vault = vault;

  final String dataDir;
  String downloadsDir;
  String deviceName;
  final String platform;
  final int port;

  /// Only for tests on loopback. In use, the private API answers Tailscale
  /// addresses alone, which WireGuard already encrypts.
  final bool allowAnyNetwork;
  final List<String>? advertised;
  final Duration syncInterval;
  final void Function(Vault vault)? onVaultChanged;

  final Uint8List _key;
  Vault _vault;
  Vault get vault => _vault;
  Uint8List get networkKey => _key;

  late String deviceId;
  HttpServer? _server;
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 3);
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;

  final Map<String, CatalogEntry> _catalog = {};
  final Map<String, _LocalFile> _local = {};
  final Map<String, _Peer> _peers = {};
  final Map<String, Manifest> _manifests = {};
  final Map<String, _Download> _downloads = {};
  final Map<String, _Rate> _down = {};
  final Map<String, _Rate> _up = {};
  final Set<String> _missing = {};
  final Map<String, String> _errors = {};
  final List<HashingJob> hashingJobs = [];
  PairingSession? _pairing;
  PairingSession? get pairing => _pairing;
  void Function()? onPaired;

  Timer? _syncTimer;
  Timer? _tickTimer;
  bool _syncing = false;
  bool _stopped = false;
  int _ticks = 0;
  List<String> _addrs = [];
  List<String> get addresses => _addrs;
  bool get tailscaleUp => allowAnyNetwork || _addrs.isNotEmpty;

  String _f(String name) => p.join(dataDir, name);

  Future<void> start() async {
    await Directory(p.join(dataDir, 'manifests')).create(recursive: true);
    await _load();
    await _refreshAddrs();
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server!.listen((r) => unawaited(_handle(r)));
    for (final l in _local.values.where((l) => !l.complete && !l.paused)) {
      unawaited(_startDownload(l.id));
    }
    _syncTimer = Timer.periodic(syncInterval, (_) => unawaited(syncNow()));
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    unawaited(syncNow());
  }

  Future<void> stop() async {
    _stopped = true;
    _syncTimer?.cancel();
    _tickTimer?.cancel();
    await _server?.close(force: true);
    _http.close(force: true);
    for (final id in _downloads.keys.toList()) {
      await _closeDownload(id);
    }
    await _save();
    await _changes.close();
  }

  Future<Object?> _read(String name) async {
    final f = File(_f(name));
    if (!await f.exists()) return null;
    return jsonDecode(await f.readAsString());
  }

  Future<void> _load() async {
    final identity = await _read('device.json') as Map?;
    if (identity == null) {
      deviceId = randomBytes(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      await _writeJson(_f('device.json'), {'id': deviceId});
    } else {
      deviceId = identity['id'] as String;
    }
    for (final e in (await _read('catalog.json') as List? ?? [])) {
      final c = CatalogEntry.fromJson((e as Map).cast());
      _catalog[c.id] = c;
    }
    for (final e in (await _read('local.json') as List? ?? [])) {
      final l = _LocalFile.fromJson((e as Map).cast());
      _local[l.id] = l;
    }
    await for (final f in Directory(p.join(dataDir, 'manifests')).list()) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      final m = Manifest.fromJson((jsonDecode(await f.readAsString()) as Map).cast());
      _manifests[p.basenameWithoutExtension(f.path)] = m;
    }
    for (final e in (await _read('peers.json') as List? ?? [])) {
      final d = DeviceInfo.fromJson((e as Map).cast());
      _peers[d.id] = _Peer(d);
    }
  }

  Future<void> _save() async {
    await _writeJson(_f('catalog.json'), _catalog.values.map((e) => e.toJson()).toList());
    await _writeJson(_f('local.json'), _local.values.map((e) => e.toJson()).toList());
    await _writeJson(_f('peers.json'), _peers.values.map((e) => e.info.toJson()).toList());
  }

  Future<void> _refreshAddrs() async {
    if (advertised != null) {
      _addrs = advertised!;
      return;
    }
    final out = <String>[];
    for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final a in i.addresses) {
        if (isTailscaleAddress(a)) out.add('${a.address}:$port');
      }
    }
    _addrs = out;
  }

  DeviceInfo get self => DeviceInfo(deviceId, deviceName, platform, _addrs);

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void _tick() {
    for (final r in [..._down.values, ..._up.values]) {
      r.tick();
    }
    if (++_ticks % 10 == 0) unawaited(_checkLocals());
    _notify();
  }

  Future<void> _checkLocals() async {
    await _refreshAddrs();
    for (final l in _local.values.where((l) => l.complete)) {
      final f = File(l.path);
      final ok = await f.exists() &&
          (await f.lastModified()).millisecondsSinceEpoch == l.mtime;
      if (ok) {
        _missing.remove(l.id);
      } else {
        _missing.add(l.id);
      }
    }
  }

  // ---- Signed requests ----

  String _signature(String method, String path, String time, String device, List<int> body) =>
      b64(hmacSha256(_key, utf8.encode('$method\n$path\n$time\n$device\n${sha256Hex(body)}')));

  bool _timeOk(String? time) {
    final t = int.tryParse(time ?? '');
    if (t == null) return false;
    final delta = DateTime.now().millisecondsSinceEpoch - t;
    return delta.abs() < _clockTolerance.inMilliseconds;
  }

  Future<Uint8List> _send(
    _Peer peer,
    String method,
    String path, {
    List<int> body = const [],
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final addrs = [
      ?peer.goodAddr,
      ...peer.info.addrs.where((a) => a != peer.goodAddr),
    ];
    Object error = const SocketException('aucune adresse');
    for (final addr in addrs) {
      try {
        final result = await _sendTo(addr, method, path, body).timeout(timeout);
        peer.goodAddr = addr;
        return result;
      } catch (e) {
        error = e;
      }
    }
    throw error;
  }

  Future<Uint8List> _sendTo(String addr, String method, String path, List<int> body) async {
    final req = await _http.openUrl(method, Uri.parse('http://$addr$path'));
    final time = '${DateTime.now().millisecondsSinceEpoch}';
    req.headers
      ..set('x-essaim-device', deviceId)
      ..set('x-essaim-time', time)
      ..set('x-essaim-sig', _signature(method, path, time, deviceId, body));
    req.contentLength = body.length;
    req.add(body);
    final res = await req.close();
    final data = await _collect(res);
    if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
    return data;
  }

  static Future<Uint8List> _collect(Stream<List<int>> s) async {
    final b = BytesBuilder(copy: false);
    await for (final c in s) {
      b.add(c);
    }
    return b.takeBytes();
  }

  // ---- Server ----

  Future<void> _reply(HttpRequest r, int code, [Object? json]) async {
    r.response.statusCode = code;
    r.response.headers.contentType = ContentType.json;
    r.response.write(jsonEncode(json ?? {}));
    await r.response.close();
  }

  Future<void> _handle(HttpRequest r) async {
    try {
      final path = r.uri.path;
      if (path == '/v1/hello') {
        return await _reply(r, 200, {
          'app': 'essaim',
          'name': deviceName,
          'platform': platform,
          'pairing': _activePairing != null,
        });
      }
      final body = await _collect(r);
      if (path == '/v1/pair/start' && r.method == 'POST') {
        return await _pairStart(r, body);
      }
      if (path == '/v1/pair/finish' && r.method == 'POST') {
        return await _pairFinish(r, body);
      }
      final remote = r.connectionInfo?.remoteAddress;
      if (!allowAnyNetwork && (remote == null || !isTailscaleAddress(remote))) {
        return await _reply(r, 403);
      }
      final device = r.headers.value('x-essaim-device') ?? '';
      final time = r.headers.value('x-essaim-time');
      final sig = r.headers.value('x-essaim-sig') ?? '';
      if (!_timeOk(time) ||
          !constantTimeEq(utf8.encode(sig),
              utf8.encode(_signature(r.method, path, time!, device, body)))) {
        return await _reply(r, 401);
      }
      final parts = path.split('/');
      if (path == '/v1/sync' && r.method == 'POST') {
        await _ingest((jsonDecode(utf8.decode(body)) as Map).cast());
        return await _reply(r, 200, _syncPayload());
      }
      if (parts.length == 4 && parts[2] == 'manifest') {
        final m = await _manifestOf(parts[3]);
        return m == null ? await _reply(r, 404) : await _reply(r, 200, m.toJson());
      }
      if (parts.length == 5 && parts[2] == 'piece') {
        return await _servePiece(r, parts[3], int.parse(parts[4]));
      }
      await _reply(r, 404);
    } catch (_) {
      try {
        await _reply(r, 500);
      } catch (_) {}
    }
  }

  Future<void> _servePiece(HttpRequest r, String id, int index) async {
    final l = _local[id];
    final m = await _manifestOf(id);
    if (l == null || m == null || _missing.contains(id) || (l.complete && !l.sharing) ||
        index < 0 || index >= m.pieceCount || !_bit(l.bits, index)) {
      return _reply(r, 404);
    }
    final raf = await File(l.path).open();
    final Uint8List data;
    try {
      await raf.setPosition(index * m.pieceSize);
      data = await raf.read(m.lengthOf(index));
    } finally {
      await raf.close();
    }
    r.response.headers.contentType = ContentType.binary;
    r.response.contentLength = data.length;
    r.response.add(data);
    await r.response.close();
    (_up[id] ??= _Rate()).pending += data.length;
  }

  Map<String, Object?> _haveMap() {
    final out = <String, Object?>{};
    _local.forEach((id, l) {
      if (_missing.contains(id) || (l.complete && !l.sharing)) return;
      final total = _manifests[id]?.pieceCount ?? 0;
      out[id] = l.complete
          ? {'complete': true}
          : {
              'complete': false,
              'bits': b64(l.bits),
              'pct': total == 0 ? 0.0 : _countBits(l.bits, total) / total,
            };
    });
    return out;
  }

  Map<String, Object?> _syncPayload() => {
        'from': self.toJson(),
        'known': _peers.values.map((x) => x.info.toJson()).toList(),
        'have': _haveMap(),
        'catalog': _catalog.values.map((e) => e.toJson()).toList(),
        'vault': _vault.toJson(),
      };

  Future<void> _ingest(Map<String, Object?> m) async {
    var dirty = false;
    final from = DeviceInfo.fromJson((m['from'] as Map).cast());
    if (from.id != deviceId) {
      final peer = _peers[from.id] ??= _Peer(from);
      peer.info = from;
      peer.lastOk = DateTime.now();
      peer.failures = 0;
      peer.have = (m['have'] as Map).map((k, v) {
        final bits = v['bits'] as String?;
        return MapEntry(k as String, _Have(v['complete'] as bool, bits == null ? null : unb64(bits), (v['pct'] as num? ?? 0).toDouble()));
      });
    }
    for (final raw in m['known'] as List) {
      final d = DeviceInfo.fromJson((raw as Map).cast());
      if (d.id != deviceId && !_peers.containsKey(d.id)) {
        _peers[d.id] = _Peer(d);
        dirty = true;
      }
    }
    for (final raw in m['catalog'] as List) {
      final e = CatalogEntry.fromJson((raw as Map).cast());
      final cur = _catalog[e.id];
      if ((cur == null || e.supersedes(cur)) && e.isAuthentic(_key)) {
        _catalog[e.id] = e;
        dirty = true;
        if (e.removed) await _dropLocal(e.id);
      }
    }
    final v = Vault.fromJson((m['vault'] as Map).cast());
    if (v.isNewerThan(_vault) && v.isAuthentic(_key)) {
      _vault = v;
      onVaultChanged?.call(v);
    }
    if (dirty) await _save();
    _pumpAll();
    _notify();
  }

  /// Exchanges state with every peer that is due for a retry.
  Future<void> syncNow() async {
    if (_syncing || _stopped) return;
    _syncing = true;
    try {
      final now = DateTime.now();
      final body = utf8.encode(jsonEncode(_syncPayload()));
      await Future.wait(_peers.values.where((x) => !x.nextTry.isAfter(now)).map((x) async {
        try {
          final res = await _send(x, 'POST', '/v1/sync', body: body);
          await _ingest((jsonDecode(utf8.decode(res)) as Map).cast());
          x.failures = 0;
          x.nextTry = now;
        } catch (_) {
          x.failures++;
          x.nextTry = now.add(Duration(seconds: min(15, 3 * x.failures)));
        }
      }));
    } finally {
      _syncing = false;
    }
    _notify();
  }

  /// Adds a device already known by address; used right after pairing.
  Future<void> addPeer(DeviceInfo info) async {
    _peers[info.id] = _Peer(info);
    await _save();
    await syncNow();
  }

  // ---- Sharing ----

  Future<Manifest?> _manifestOf(String id) async {
    final cached = _manifests[id];
    if (cached != null) return cached;
    final f = File(p.join(dataDir, 'manifests', '$id.json'));
    if (!await f.exists()) return null;
    return _manifests[id] = Manifest.fromJson((jsonDecode(await f.readAsString()) as Map).cast());
  }

  Future<void> _storeManifest(String id, Manifest m) async {
    _manifests[id] = m;
    await _writeJson(p.join(dataDir, 'manifests', '$id.json'), m.toJson());
  }

  /// Puts a file in the swarm. The bytes stay where they are on disk.
  Future<String> share(String path) async {
    final job = HashingJob(p.basename(path));
    hashingJobs.add(job);
    _notify();
    try {
      final file = File(path);
      final m = await buildManifest(path, onProgress: (v) {
        job.progress = v;
        _notify();
      });
      final id = m.id;
      await _storeManifest(id, m);
      final bits = _newBits(m.pieceCount);
      for (var i = 0; i < m.pieceCount; i++) {
        _setBit(bits, i);
      }
      await _closeDownload(id);
      _local[id] = _LocalFile(id, path, true, bits, (await file.lastModified()).millisecondsSinceEpoch);
      _missing.remove(id);
      final now = DateTime.now().millisecondsSinceEpoch;
      _catalog[id] = CatalogEntry(id, m.name, m.size, deviceId, now, now, false, '').signed(_key);
      await _save();
      unawaited(syncNow());
      return id;
    } finally {
      hashingJobs.remove(job);
      _notify();
    }
  }

  /// This device stops offering the file; it stays in the catalogue.
  Future<void> stopSharing(String id) async {
    await _dropLocal(id);
    await _save();
    _notify();
  }

  /// Removes the entry for every device. Finished files on disk are kept.
  Future<void> removeFromCatalog(String id) async {
    final e = _catalog[id];
    if (e == null) return;
    _catalog[id] = CatalogEntry(id, e.name, e.size, e.addedBy, e.addedAt,
        DateTime.now().millisecondsSinceEpoch, true, '').signed(_key);
    await _dropLocal(id);
    await _save();
    _notify();
    unawaited(syncNow());
  }

  /// Switches a finished file between "En partage" and "Terminé".
  Future<void> setSharing(String id, bool on) async {
    final l = _local[id];
    if (l == null || !l.complete) return;
    l.sharing = on;
    await _save();
    _notify();
    unawaited(syncNow());
  }

  Future<void> _dropLocal(String id) async {
    _errors.remove(id);
    await _closeDownload(id);
    final l = _local.remove(id);
    _missing.remove(id);
    if (l != null && !l.complete) {
      try {
        await File(l.path).delete();
      } catch (_) {}
    }
  }

  // ---- Downloading ----

  String _partPath(String id) => p.join(downloadsDir, '.partiel', '$id.part');

  Future<void> download(String id) async {
    final e = _catalog[id];
    if (e == null || e.removed || _local.containsKey(id)) return;
    final part = _partPath(id);
    await Directory(p.dirname(part)).create(recursive: true);
    _local[id] = _LocalFile(id, part, false, Uint8List(0), 0);
    await _save();
    _notify();
    await _startDownload(id);
  }

  Future<void> pause(String id) async {
    final l = _local[id];
    if (l == null || l.complete) return;
    l.paused = true;
    await _closeDownload(id);
    await _save();
    _notify();
  }

  Future<void> resume(String id) async {
    final l = _local[id];
    if (l == null || l.complete) return;
    l.paused = false;
    await _save();
    await _startDownload(id);
    _notify();
  }

  Future<Manifest?> _fetchManifest(String id) async {
    final known = await _manifestOf(id);
    if (known != null) return known;
    for (final x in _peers.values.where((x) => x.online && x.have.containsKey(id))) {
      try {
        final res = await _send(x, 'GET', '/v1/manifest/$id');
        final m = Manifest.fromJson((jsonDecode(utf8.decode(res)) as Map).cast());
        if (m.id != id) continue;
        await _storeManifest(id, m);
        return m;
      } catch (_) {}
    }
    return null;
  }

  final Set<String> _starting = {};

  Future<void> _startDownload(String id) async {
    if (_downloads.containsKey(id) || !_starting.add(id)) return;
    try {
      final l = _local[id];
      if (l == null || l.complete || l.paused) return;
      final m = await _fetchManifest(id);
      // Nothing written yet: follow the current destination after a failure.
      if (l.bits.every((b) => b == 0)) l.path = _partPath(id);
      await Directory(p.dirname(l.path)).create(recursive: true);
      if (m == null) {
        _errors[id] = 'Impossible de récupérer ce fichier auprès des pairs';
        return;
      }
      if (_local[id] != l || l.paused) return;
      if (l.bits.length != (m.pieceCount + 7) >> 3) l.bits = _newBits(m.pieceCount);
      final raf = await File(l.path).open(mode: FileMode.append);
      await raf.truncate(m.size);
      _downloads[id] = _Download(m, raf);
      _errors.remove(id);
      _pump(id);
    } on FileSystemException catch (e) {
      _errors[id] = 'Écriture impossible : ${e.osError?.message ?? e.message}';
      _notify();
    } finally {
      _starting.remove(id);
    }
  }

  void _pumpAll() {
    for (final l in _local.values.toList()) {
      if (l.complete || l.paused) continue;
      if (_downloads.containsKey(l.id)) {
        _pump(l.id);
      } else {
        unawaited(_startDownload(l.id));
      }
    }
  }

  void _pump(String id) {
    final d = _downloads[id];
    final l = _local[id];
    if (d == null || l == null || d.closing) return;
    final total = d.manifest.pieceCount;
    final peers = _peers.values.where((x) {
      final ban = d.banned[x.info.id];
      return x.online && x.have.containsKey(id) &&
          (ban == null || ban.isBefore(DateTime.now()));
    }).toList()..shuffle();
    for (final x in peers) {
      final have = x.have[id]!;
      while ((d.activePerPeer[x.info.id] ?? 0) < _workersPerPeer) {
        int? best;
        var bestRarity = 1 << 30;
        for (var i = 0; i < total; i++) {
          if (_bit(l.bits, i) || d.inflight.contains(i) || !have.has(i)) continue;
          // Rarest first, so partial copies complement each other.
          var rarity = 0;
          for (final o in peers) {
            if (o.have[id]!.has(i)) rarity++;
          }
          if (rarity < bestRarity) {
            bestRarity = rarity;
            best = i;
            if (rarity == 1) break;
          }
        }
        if (best == null) break;
        d.inflight.add(best);
        d.activePerPeer[x.info.id] = (d.activePerPeer[x.info.id] ?? 0) + 1;
        unawaited(_fetchPiece(id, d, l, x, best));
      }
    }
  }

  Future<void> _fetchPiece(String id, _Download d, _LocalFile l, _Peer x, int i) async {
    try {
      final data = await _send(x, 'GET', '/v1/piece/$id/$i', timeout: const Duration(seconds: 120));
      final hash = data.length > 1 << 20
          ? await _hashOffThread(data)
          : b64(sha256Bytes(data));
      if (hash != d.manifest.hashes[i] || data.length != d.manifest.lengthOf(i)) {
        d.banned[x.info.id] = DateTime.now().add(const Duration(minutes: 1));
        return;
      }
      if (d.closing) return;
      d.writes = d.writes.then((_) async {
        if (d.closing) return;
        await d.raf.setPosition(i * d.manifest.pieceSize);
        await d.raf.writeFrom(data);
      });
      await d.writes;
      if (d.closing) return;
      _setBit(l.bits, i);
      (_down[id] ??= _Rate()).pending += data.length;
      _errors.remove(id);
      if (_countBits(l.bits, d.manifest.pieceCount) == d.manifest.pieceCount) {
        await _finish(id, d, l);
      } else if (DateTime.now().difference(d.lastSave).inSeconds >= 2) {
        d.lastSave = DateTime.now();
        await _save();
      }
    } on FileSystemException catch (e) {
      _errors[id] = 'Écriture impossible : ${e.osError?.message ?? e.message}';
      d.banned[x.info.id] = DateTime.now().add(const Duration(seconds: 5));
    } catch (_) {
      _errors[id] = 'Impossible de joindre ${x.info.name}';
      d.banned[x.info.id] = DateTime.now().add(const Duration(seconds: 5));
    } finally {
      d.inflight.remove(i);
      d.activePerPeer[x.info.id] = (d.activePerPeer[x.info.id] ?? 1) - 1;
      _pump(id);
      _notify();
    }
  }

  Future<void> _finish(String id, _Download d, _LocalFile l) async {
    d.closing = true;
    await d.writes;
    await d.raf.flush();
    await d.raf.close();
    _downloads.remove(id);
    await Directory(downloadsDir).create(recursive: true);
    final target = await _uniquePath(d.manifest.name);
    await File(l.path).rename(target);
    l
      ..path = target
      ..complete = true
      ..mtime = (await File(target).lastModified()).millisecondsSinceEpoch;
    await _save();
    _notify();
    unawaited(syncNow());
  }

  Future<String> _uniquePath(String rawName) async {
    // A peer holding the network key still must not write outside the folder.
    final name = p.basename(rawName.replaceAll('\\', '/'));
    final stem = p.basenameWithoutExtension(name);
    final ext = p.extension(name);
    var candidate = p.join(downloadsDir, name);
    for (var n = 1; await File(candidate).exists(); n++) {
      candidate = p.join(downloadsDir, '$stem ($n)$ext');
    }
    return candidate;
  }

  Future<void> _closeDownload(String id) async {
    final d = _downloads.remove(id);
    if (d == null) return;
    d.closing = true;
    await d.writes;
    await d.raf.close();
  }

  // ---- View models ----

  List<CatalogItem> get items {
    final out = <CatalogItem>[];
    for (final e in _catalog.values.where((e) => !e.removed)) {
      out.add(_viewOf(e));
    }
    out.sort((a, b) => b.entry.addedAt.compareTo(a.entry.addedAt));
    return out;
  }

  CatalogItem _viewOf(CatalogEntry e) {
    final id = e.id;
    final l = _local[id];
    final m = _manifests[id];
    final total = m?.pieceCount ?? 0;
    var mine = 0.0;
    if (l != null) {
      mine = l.complete
          ? 1.0
          : total == 0
              ? 0.0
              : _countBits(l.bits, total) / total;
    }
    final peers = <PeerProgress>[
      if (l != null && !_missing.contains(id) && (l.sharing || !l.complete))
        PeerProgress(deviceName, platform, true, mine, true),
    ];
    for (final x in _peers.values) {
      final have = x.have[id];
      if (have == null) continue;
      final pct = have.complete ? 1.0 : (total == 0 ? have.pct : have.count(total) / total);
      peers.add(PeerProgress(x.info.name, x.info.platform, x.online, pct, false));
    }
    final anyOnline = peers.any((x) => !x.self && x.online && x.progress > 0);
    final down = _down[id]?.perSecond ?? 0;
    final ItemStatus status;
    if (l == null) {
      status = anyOnline ? ItemStatus.available : ItemStatus.unreachable;
    } else if (l.complete) {
      status = _missing.contains(id)
          ? ItemStatus.missing
          : l.sharing
              ? ItemStatus.seeding
              : ItemStatus.finished;
    } else if (l.paused) {
      status = ItemStatus.paused;
    } else {
      status = anyOnline ? ItemStatus.downloading : ItemStatus.stalled;
    }
    return CatalogItem(e, status, mine, peers, down, _up[id]?.perSecond ?? 0,
        l != null && l.complete ? l.path : null, _errors[id]);
  }

  List<DeviceView> get devices => [
        DeviceView(self, true, true, DateTime.now()),
        ..._peers.values.map((x) => DeviceView(x.info, x.online, false, x.lastOk)),
      ];

  double get totalDown => _down.values.fold(0, (s, r) => s + r.perSecond);
  double get totalUp => _up.values.fold(0, (s, r) => s + r.perSecond);

  // ---- Vault changes made on this device ----

  Future<void> replaceVault(Vault v) async {
    _vault = v;
    onVaultChanged?.call(v);
    unawaited(syncNow());
  }

  // ---- Pairing (host side) ----

  PairingSession? get _activePairing {
    final s = _pairing;
    if (s == null) return null;
    if (DateTime.now().isAfter(s.expires)) return _pairing = null;
    return s;
  }

  PairingSession startPairing() {
    final code = (randomBytes(4).fold<int>(0, (a, b) => (a << 8) | b) % 1000000)
        .toString()
        .padLeft(6, '0');
    return _pairing = PairingSession(
        code, DateTime.now().add(const Duration(minutes: 5)), _addrs);
  }

  void cancelPairing() {
    _pairing = null;
    _notify();
  }

  Future<void> _pairStart(HttpRequest r, List<int> body) async {
    final s = _activePairing;
    if (s == null || s.keys.length >= 16) return _reply(r, 403);
    final m = jsonDecode(utf8.decode(body)) as Map;
    final speke = Speke(s.code);
    final pubA = m['pub'] as String;
    final sk = speke.shared(Speke.decode(pubA));
    final sid = b64(randomBytes(12));
    final pubB = Speke.encode(speke.public);
    s.keys[sid] = sk;
    s.pubs[sid] = [pubA, pubB];
    await _reply(r, 200, {'sid': sid, 'pub': pubB});
  }

  Future<void> _pairFinish(HttpRequest r, List<int> body) async {
    final s = _activePairing;
    if (s == null) return _reply(r, 403);
    final m = jsonDecode(utf8.decode(body)) as Map;
    final sid = m['sid'] as String;
    final sk = s.keys.remove(sid);
    final pubs = s.pubs.remove(sid);
    if (sk == null || pubs == null) return _reply(r, 403);
    final expected = pairConfirm(sk, 'A', pubs);
    if (!constantTimeEq(unb64(m['confirm'] as String), expected)) {
      if (++s.failures >= 3) _pairing = null;
      _notify();
      return _reply(r, 403);
    }
    final sealed = await seal(sk, utf8.encode(jsonEncode({
      'key': b64(_key),
      'vault': _vault.toJson(),
      'host': self.toJson(),
    })));
    _pairing = null;
    await _reply(r, 200, {'confirm': b64(pairConfirm(sk, 'B', pubs)), 'payload': sealed.toJson()});
    _notify();
    onPaired?.call();
  }
}

// Kept apart so the isolate closure captures only the bytes.
Future<String> _hashOffThread(Uint8List data) =>
    Isolate.run(() => b64(sha256Bytes(data)));

Uint8List pairConfirm(List<int> key, String role, List<String> pubs) =>
    hmacSha256(key, utf8.encode('essaim-confirm|$role|${pubs[0]}|${pubs[1]}'));

class JoinResult {
  JoinResult(this.networkKey, this.vault, this.host);
  final Uint8List networkKey;
  final Vault vault;
  final DeviceInfo host;
}

class WrongPairingCode implements Exception {
  const WrongPairingCode();
}

/// Joins the account of the device at [addr] using its 6-digit code.
Future<JoinResult> joinWithCode(String addr, String code) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  Future<Map<String, Object?>> post(String path, Object body) async {
    final req = await client.postUrl(Uri.parse('http://$addr$path'));
    req.write(jsonEncode(body));
    final res = await req.close();
    final text = await utf8.decodeStream(res);
    if (res.statusCode != 200) throw const WrongPairingCode();
    return (jsonDecode(text) as Map).cast();
  }

  try {
    final speke = Speke(code.replaceAll(RegExp(r'\D'), ''));
    final pubA = Speke.encode(speke.public);
    final start = await post('/v1/pair/start', {'pub': pubA});
    final pubB = start['pub'] as String;
    final sk = speke.shared(Speke.decode(pubB));
    final pubs = [pubA, pubB];
    final finish = await post('/v1/pair/finish', {
      'sid': start['sid'],
      'confirm': b64(pairConfirm(sk, 'A', pubs)),
    });
    if (!constantTimeEq(unb64(finish['confirm'] as String), pairConfirm(sk, 'B', pubs))) {
      throw const WrongPairingCode();
    }
    final plain = await unseal(sk, Sealed.fromJson((finish['payload'] as Map).cast()));
    final j = (jsonDecode(utf8.decode(plain)) as Map).cast<String, Object?>();
    return JoinResult(
      unb64(j['key'] as String),
      Vault.fromJson((j['vault'] as Map).cast()),
      DeviceInfo.fromJson((j['host'] as Map).cast()),
    );
  } finally {
    client.close(force: true);
  }
}

class PairableDevice {
  PairableDevice(this.addr, this.name, this.platform);
  final String addr;
  final String name;
  final String platform;
}

/// Looks for devices showing a pairing code: the local /24 networks, plus the
/// tailnet when the Tailscale CLI exists (desktop only).
Stream<PairableDevice> scanForPairing({int port = defaultPort}) {
  final out = StreamController<PairableDevice>();
  () async {
    final client = HttpClient()..connectionTimeout = const Duration(milliseconds: 900);
    final hosts = <String>{};
    for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final a in i.addresses) {
        final b = a.rawAddress;
        final private = b[0] == 10 || (b[0] == 192 && b[1] == 168) ||
            (b[0] == 172 && b[1] >= 16 && b[1] <= 31);
        if (!private) continue;
        for (var h = 1; h < 255; h++) {
          if (h != b[3]) hosts.add('${b[0]}.${b[1]}.${b[2]}.$h');
        }
      }
    }
    try {
      final r = await Process.run('tailscale', ['status', '--json'])
          .timeout(const Duration(seconds: 3));
      final peers = (jsonDecode(r.stdout as String) as Map)['Peer'] as Map?;
      for (final x in peers?.values ?? const []) {
        if (x['Online'] == true) hosts.add((x['TailscaleIPs'] as List).first as String);
      }
    } catch (_) {}
    final queue = hosts.toList();
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final h = queue.removeLast();
        final addr = '$h:$port';
        try {
          final req = await client.getUrl(Uri.parse('http://$addr/v1/hello'));
          final res = await req.close().timeout(const Duration(seconds: 2));
          final j = jsonDecode(await utf8.decodeStream(res)) as Map;
          if (j['app'] == 'essaim' && j['pairing'] == true) {
            out.add(PairableDevice(addr, j['name'] as String, j['platform'] as String));
          }
        } catch (_) {}
      }
    }

    await Future.wait(List.generate(48, (_) => worker()));
    client.close(force: true);
    await out.close();
  }();
  return out.stream;
}
