import 'dart:convert';
import 'dart:typed_data';

import 'crypto.dart';

const int passwordIterations = 210000;
const int recoveryIterations = 10000;
const int recoveryCodeCount = 8;

// No I, L, O or U: these codes get copied by hand from paper.
const String _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

class BadSecret implements Exception {
  const BadSecret();
}

class _Slot {
  _Slot(this.salt, this.box);
  final String salt;
  final Sealed box;

  Map<String, Object?> toJson() => {'salt': salt, ...box.toJson()};
  factory _Slot.fromJson(Map<String, Object?> j) =>
      _Slot(j['salt'] as String, Sealed.fromJson(j));
}

/// The account shared by all devices: the network key wrapped once by the
/// password and once by each unused recovery code. Devices exchange it, and
/// the newest authentic revision wins, so a password change reaches them all.
class Vault {
  Vault._(this.rev, this.updatedAt, this.updatedBy, this._password,
      this._recovery, this.mac);

  final int rev;
  final int updatedAt;
  final String updatedBy;
  final _Slot _password;
  final List<_Slot> _recovery;
  final String mac;

  int get recoveryLeft => _recovery.length;

  Map<String, Object?> _body() => {
        'rev': rev,
        'updatedAt': updatedAt,
        'updatedBy': updatedBy,
        'pw': _password.toJson(),
        'recovery': _recovery.map((s) => s.toJson()).toList(),
      };

  Map<String, Object?> toJson() => {..._body(), 'mac': mac};

  factory Vault.fromJson(Map<String, Object?> j) => Vault._(
        j['rev'] as int,
        j['updatedAt'] as int,
        j['updatedBy'] as String,
        _Slot.fromJson((j['pw'] as Map).cast()),
        (j['recovery'] as List)
            .map((e) => _Slot.fromJson((e as Map).cast()))
            .toList(),
        j['mac'] as String,
      );

  static Uint8List _macOf(List<int> key, Map<String, Object?> body) =>
      hmacSha256(key, utf8.encode('essaim-vault|${canonicalJson(body)}'));

  bool isAuthentic(List<int> networkKey) => constantTimeEq(
      unb64(mac), _macOf(networkKey, _body()));

  bool isNewerThan(Vault o) {
    if (rev != o.rev) return rev > o.rev;
    if (updatedAt != o.updatedAt) return updatedAt > o.updatedAt;
    return updatedBy.compareTo(o.updatedBy) > 0;
  }

  static Future<_Slot> _wrap(
      String secret, int iterations, List<int> networkKey) async {
    final salt = randomBytes(16);
    final kek = await pbkdf2(secret, salt, iterations);
    return _Slot(b64(salt), await seal(kek, networkKey));
  }

  static Vault _build(int rev, String device, List<int> key, _Slot pw,
      List<_Slot> recovery) {
    final draft = Vault._(rev, DateTime.now().millisecondsSinceEpoch, device,
        pw, recovery, '');
    return Vault._(draft.rev, draft.updatedAt, device, pw, recovery,
        b64(_macOf(key, draft._body())));
  }

  static String normalizeCode(String code) =>
      code.toUpperCase().replaceAll(RegExp(r'[^0-9A-Z]'), '');

  static List<String> newRecoveryCodes() => List.generate(recoveryCodeCount, (_) {
        final raw = randomBytes(16).map((b) => _alphabet[b % 32]).join();
        return [for (var i = 0; i < 16; i += 4) raw.substring(i, i + 4)]
            .join('-');
      });

  static Future<List<_Slot>> _wrapCodes(
          List<String> codes, List<int> key) =>
      Future.wait(codes
          .map((c) => _wrap(normalizeCode(c), recoveryIterations, key)));

  /// First password on the first device.
  static Future<AccountCreated> create(String password, String device) async {
    final key = randomBytes(32);
    final codes = newRecoveryCodes();
    final vault = _build(1, device, key,
        await _wrap(password, passwordIterations, key),
        await _wrapCodes(codes, key));
    return AccountCreated(key, vault, codes);
  }

  /// Returns the network key, or throws [BadSecret].
  Future<Uint8List> unlock(String password) async {
    try {
      final kek = await pbkdf2(
          password, unb64(_password.salt), passwordIterations);
      return await unseal(kek, _password.box);
    } catch (_) {
      throw const BadSecret();
    }
  }

  /// Spends one recovery code to set a new password. Throws [BadSecret].
  Future<Vault> resetPassword(
      String code, String newPassword, String device) async {
    final normalized = normalizeCode(code);
    for (var i = 0; i < _recovery.length; i++) {
      final slot = _recovery[i];
      final kek =
          await pbkdf2(normalized, unb64(slot.salt), recoveryIterations);
      final Uint8List key;
      try {
        key = await unseal(kek, slot.box);
      } catch (_) {
        continue;
      }
      return _build(
        rev + 1,
        device,
        key,
        await _wrap(newPassword, passwordIterations, key),
        [..._recovery]..removeAt(i),
      );
    }
    throw const BadSecret();
  }

  Future<Vault> changePassword(
      List<int> networkKey, String newPassword, String device) async {
    return _build(rev + 1, device, networkKey,
        await _wrap(newPassword, passwordIterations, networkKey), _recovery);
  }

  /// Replaces every recovery code; the old ones stop working.
  Future<AccountCreated> regenerateCodes(
      List<int> networkKey, String device) async {
    final codes = newRecoveryCodes();
    final vault = _build(rev + 1, device, networkKey, _password,
        await _wrapCodes(codes, networkKey));
    return AccountCreated(Uint8List.fromList(networkKey), vault, codes);
  }
}

class AccountCreated {
  AccountCreated(this.networkKey, this.vault, this.recoveryCodes);
  final Uint8List networkKey;
  final Vault vault;
  final List<String> recoveryCodes;
}
