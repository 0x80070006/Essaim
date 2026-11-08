import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/account.dart';
import '../core/crypto.dart';
import '../core/node.dart';
import 'dpapi.dart';

enum Phase { loading, welcome, locked, showCodes, home }

const MethodChannel native = MethodChannel('essaim/native');

class AppController extends ChangeNotifier {
  final LocalAuthentication _auth = LocalAuthentication();

  Phase phase = Phase.loading;
  Node? node;
  List<String>? pendingCodes;
  bool biometricEnabled = false;
  bool biometricAvailable = false;
  late String _dataDir;
  late String _downloads;
  late String _deviceName;
  Timer? _throttle;
  DateTime? _backgroundedAt;

  String get _vaultPath => p.join(_dataDir, 'vault.json');
  String get _prefsPath => p.join(_dataDir, 'prefs.json');

  Future<void> init() async {
    _dataDir = (await getApplicationSupportDirectory()).path;
    await Directory(_dataDir).create(recursive: true);
    if (Platform.isAndroid) {
      _downloads = '/storage/emulated/0/Download/Essaim';
      _deviceName = await native.invokeMethod<String>('deviceName') ?? 'Android';
      biometricAvailable = await _auth.canCheckBiometrics;
    } else {
      final dl = await getDownloadsDirectory();
      _downloads = p.join(dl?.path ?? _dataDir, 'Essaim');
      _deviceName = Platform.localHostname;
    }
    final prefs = File(_prefsPath);
    if (await prefs.exists()) {
      biometricEnabled = (jsonDecode(await prefs.readAsString()) as Map)['biometric'] == true;
    }
    final key = await _readKey();
    final vaultFile = File(_vaultPath);
    if (key != null && await vaultFile.exists()) {
      final vault = Vault.fromJson((jsonDecode(await vaultFile.readAsString()) as Map).cast());
      await _startNode(key, vault);
      phase = Phase.locked;
    } else {
      phase = Phase.welcome;
    }
    notifyListeners();
  }

  File get _keyFile => File(p.join(_dataDir, 'network.key'));

  /// The network key, sealed by the OS: Keystore on Android, DPAPI on Windows.
  Future<void> _writeKey(List<int> key) async {
    final sealed = Platform.isAndroid
        ? unb64((await native.invokeMethod<String>('seal', {'value': b64(key)}))!)
        : dpapiProtect(key);
    await _keyFile.writeAsBytes(sealed, flush: true);
  }

  Future<List<int>?> _readKey() async {
    if (!await _keyFile.exists()) return null;
    final sealed = await _keyFile.readAsBytes();
    if (!Platform.isAndroid) return dpapiUnprotect(sealed);
    return unb64((await native.invokeMethod<String>('unseal', {'value': b64(sealed)}))!);
  }

  Future<void> _saveVault(Vault v) async {
    final tmp = File('$_vaultPath.tmp');
    await tmp.writeAsString(jsonEncode(v.toJson()), flush: true);
    await tmp.rename(_vaultPath);
  }

  Future<void> _startNode(List<int> key, Vault vault) async {
    final n = Node(
      dataDir: p.join(_dataDir, 'node'),
      downloadsDir: _downloads,
      networkKey: key,
      vault: vault,
      deviceName: _deviceName,
      platform: Platform.operatingSystem,
      onVaultChanged: (v) => unawaited(_saveVault(v)),
    );
    await n.start();
    node = n;
    // Rebuilding four times a second is plenty for progress bars.
    n.changes.listen((_) {
      _throttle ??= Timer(const Duration(milliseconds: 250), () {
        _throttle = null;
        notifyListeners();
      });
    });
    if (Platform.isAndroid) await native.invokeMethod<void>('startService');
  }

  Future<void> _adopt(List<int> key, Vault vault) async {
    await _writeKey(key);
    await _saveVault(vault);
    await _startNode(key, vault);
  }

  Future<void> createAccount(String password) async {
    final created = await Vault.create(password, _deviceName);
    await _adopt(created.networkKey, created.vault);
    pendingCodes = created.recoveryCodes;
    phase = Phase.showCodes;
    notifyListeners();
  }

  void codesSaved() {
    pendingCodes = null;
    phase = Phase.home;
    notifyListeners();
  }

  Future<void> join(String addr, String code) async {
    final target = addr.contains(':') ? addr : '$addr:$defaultPort';
    final r = await joinWithCode(target, code);
    if (r.host.addrs.isEmpty) r.host.addrs = [target];
    await _adopt(r.networkKey, r.vault);
    await node!.addPeer(r.host);
    phase = Phase.locked;
    notifyListeners();
  }

  /// Throws [BadSecret] on a wrong password.
  Future<void> login(String password) async {
    await node!.vault.unlock(password);
    phase = Phase.home;
    notifyListeners();
  }

  /// Throws [BadSecret] on a wrong or already used code.
  Future<void> resetPassword(String code, String newPassword) async {
    final v = await node!.vault.resetPassword(code, newPassword, _deviceName);
    await node!.replaceVault(v);
    phase = Phase.home;
    notifyListeners();
  }

  Future<void> changePassword(String current, String next) async {
    await node!.vault.unlock(current);
    final v = await node!.vault.changePassword(node!.networkKey, next, _deviceName);
    await node!.replaceVault(v);
    notifyListeners();
  }

  Future<void> regenerateCodes(String password) async {
    await node!.vault.unlock(password);
    final created = await node!.vault.regenerateCodes(node!.networkKey, _deviceName);
    await node!.replaceVault(created.vault);
    pendingCodes = created.recoveryCodes;
    phase = Phase.showCodes;
    notifyListeners();
  }

  void lock() {
    phase = Phase.locked;
    notifyListeners();
  }

  /// Returns true when the fingerprint was accepted.
  Future<bool> biometricLogin() async {
    if (!biometricEnabled || !biometricAvailable || phase != Phase.locked) return false;
    final ok = await _promptBiometric('Déverrouiller Essaim');
    if (ok) {
      phase = Phase.home;
      notifyListeners();
    }
    return ok;
  }

  Future<bool> _promptBiometric(String reason) async {
    try {
      return await _auth.authenticate(localizedReason: reason, biometricOnly: true);
    } on Exception {
      return false;
    }
  }

  Future<void> setBiometric(bool enabled) async {
    if (enabled && !await _promptBiometric('Activer le déverrouillage par empreinte')) return;
    biometricEnabled = enabled;
    await File(_prefsPath).writeAsString(jsonEncode({'biometric': enabled}));
    notifyListeners();
  }

  void onBackgrounded() => _backgroundedAt = DateTime.now();

  void onResumed() {
    final since = _backgroundedAt;
    _backgroundedAt = null;
    if (since != null && phase == Phase.home &&
        DateTime.now().difference(since) > const Duration(minutes: 2)) {
      lock();
    }
  }

  Future<void> openFile(String path) async {
    if (Platform.isAndroid) {
      await native.invokeMethod<void>('openFile', {'path': path});
    } else {
      await Process.run('explorer', [path]);
    }
  }

  Future<bool> ensureFileAccess() async {
    if (!Platform.isAndroid) return true;
    if (await native.invokeMethod<bool>('hasAllFiles') == true) return true;
    await native.invokeMethod<void>('requestAllFiles');
    return false;
  }

  static const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

  Future<bool> startsWithWindows() async {
    final r = await Process.run('reg', ['query', _runKey, '/v', 'Essaim']);
    return r.exitCode == 0;
  }

  Future<void> setStartsWithWindows(bool on) async {
    await Process.run('reg', on
        ? ['add', _runKey, '/v', 'Essaim', '/t', 'REG_SZ', '/d', '"${Platform.resolvedExecutable}"', '/f']
        : ['delete', _runKey, '/v', 'Essaim', '/f']);
    notifyListeners();
  }
}
