import 'dart:collection';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:cryptography/cryptography.dart' as cg;

final Random _rng = Random.secure();

Uint8List randomBytes(int n) =>
    Uint8List.fromList(List<int>.generate(n, (_) => _rng.nextInt(256)));

String b64(List<int> v) => base64Url.encode(v);
Uint8List unb64(String v) => base64Url.decode(base64Url.normalize(v));

Uint8List sha256Bytes(List<int> data) =>
    Uint8List.fromList(c.sha256.convert(data).bytes);

String sha256Hex(List<int> data) => c.sha256.convert(data).toString();

Uint8List hmacSha256(List<int> key, List<int> data) =>
    Uint8List.fromList(c.Hmac(c.sha256, key).convert(data).bytes);

bool constantTimeEq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// JSON with recursively sorted keys, so that two devices always sign and
/// hash the same bytes for the same value.
String canonicalJson(Object? value) => jsonEncode(_sorted(value));

Object? _sorted(Object? v) {
  if (v is Map) {
    final out = SplayTreeMap<String, Object?>();
    v.forEach((k, val) => out[k as String] = _sorted(val));
    return out;
  }
  if (v is List) return v.map(_sorted).toList();
  return v;
}

/// Password stretching. Runs in its own isolate so the UI keeps animating.
Future<Uint8List> pbkdf2(String secret, List<int> salt, int iterations) {
  final s = List<int>.from(salt);
  return Isolate.run(() async {
    final kdf = cg.Pbkdf2(
      macAlgorithm: cg.Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    );
    final key = await kdf.deriveKey(
      secretKey: cg.SecretKey(utf8.encode(secret)),
      nonce: s,
    );
    return Uint8List.fromList(await key.extractBytes());
  });
}

final cg.AesGcm _aes = cg.AesGcm.with256bits();

class Sealed {
  Sealed(this.nonce, this.cipher);
  final String nonce;
  final String cipher;

  Map<String, Object?> toJson() => {'n': nonce, 'c': cipher};
  factory Sealed.fromJson(Map<String, Object?> j) =>
      Sealed(j['n'] as String, j['c'] as String);
}

Future<Sealed> seal(List<int> key, List<int> plain) async {
  final box = await _aes.encrypt(plain, secretKey: cg.SecretKey(key));
  return Sealed(b64(box.nonce), b64([...box.cipherText, ...box.mac.bytes]));
}

/// Throws [cg.SecretBoxAuthenticationError] when the key is wrong.
Future<Uint8List> unseal(List<int> key, Sealed box) async {
  final raw = unb64(box.cipher);
  final plain = await _aes.decrypt(
    cg.SecretBox(
      raw.sublist(0, raw.length - 16),
      nonce: unb64(box.nonce),
      mac: cg.Mac(raw.sublist(raw.length - 16)),
    ),
    secretKey: cg.SecretKey(key),
  );
  return Uint8List.fromList(plain);
}

/// SPEKE over the RFC 3526 2048-bit group: turns a 6-digit pairing code into
/// a strong shared key. An eavesdropper learns nothing it can brute-force
/// offline, and an active attacker gets one guess per attempt.
class Speke {
  Speke(String code) : _base = _hashToGroup(code) {
    _x = _randomBig(40) + BigInt.two;
    public = _base.modPow(_x, _p);
  }

  final BigInt _base;
  late final BigInt _x;
  late final BigInt public;

  static final BigInt _p = BigInt.parse(
    'FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74'
    '020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437'
    '4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED'
    'EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF05'
    '98DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB'
    '9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B'
    'E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718'
    '3995497CEA956AE515D2261898FA051015728E5A8AACAA68FFFFFFFFFFFFFFFF',
    radix: 16,
  );
  static final BigInt _q = (_p - BigInt.one) >> 1;

  static BigInt _randomBig(int bytes) => _toBig(randomBytes(bytes));

  static BigInt _toBig(List<int> b) {
    var out = BigInt.zero;
    for (final v in b) {
      out = (out << 8) | BigInt.from(v);
    }
    return out;
  }

  static BigInt _hashToGroup(String code) {
    final expanded = <int>[];
    for (var i = 0; expanded.length < 256 + 32; i++) {
      expanded.addAll(sha256Bytes(utf8.encode('essaim-speke-base:$i:$code')));
    }
    return (_toBig(expanded) % _p).modPow(BigInt.two, _p);
  }

  static bool validPublic(BigInt v) =>
      v > BigInt.one && v < _p - BigInt.one && v.modPow(_q, _p) == BigInt.one;

  /// Session key bound to both public values. Throws on an invalid peer value.
  Uint8List shared(BigInt other) {
    if (!validPublic(other)) throw const FormatException('valeur invalide');
    final k = other.modPow(_x, _p);
    final a = public < other ? public : other;
    final b = public < other ? other : public;
    return sha256Bytes(
      utf8.encode('essaim-speke-key|${a.toRadixString(16)}|'
          '${b.toRadixString(16)}|${k.toRadixString(16)}'),
    );
  }

  static String encode(BigInt v) => v.toRadixString(16);
  static BigInt decode(String v) => BigInt.parse(v, radix: 16);
}
