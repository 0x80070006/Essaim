import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'crypto.dart';

const int _minPiece = 256 * 1024;
const int _maxPiece = 32 * 1024 * 1024;
const int _targetPieces = 2000;

int pieceSizeFor(int fileSize) {
  var size = _minPiece;
  while (size < _maxPiece && fileSize / size > _targetPieces) {
    size *= 2;
  }
  return size;
}

/// What a file is made of. Its hash is the file's identity across the swarm,
/// so a manifest received from any peer can be checked against its id.
class Manifest {
  Manifest(this.name, this.size, this.pieceSize, this.hashes);

  final String name;
  final int size;
  final int pieceSize;
  final List<String> hashes;

  int get pieceCount => hashes.length;

  int lengthOf(int index) => min(pieceSize, size - index * pieceSize);

  Map<String, Object?> toJson() =>
      {'name': name, 'size': size, 'pieceSize': pieceSize, 'hashes': hashes};

  factory Manifest.fromJson(Map<String, Object?> j) => Manifest(
        j['name'] as String,
        j['size'] as int,
        j['pieceSize'] as int,
        (j['hashes'] as List).cast<String>(),
      );

  String get id => sha256Hex(utf8.encode(canonicalJson(toJson())));
}

/// Hashes [path] piece by piece in a background isolate.
Future<Manifest> buildManifest(
  String path, {
  void Function(double progress)? onProgress,
}) async {
  final progress = ReceivePort();
  final sub = progress.listen((m) => onProgress?.call(m as double));
  final send = progress.sendPort;
  try {
    return Manifest.fromJson(await _hashInIsolate(path, send));
  } finally {
    await sub.cancel();
    progress.close();
  }
}

// Kept apart so the isolate closure captures only these two values.
Future<Map<String, Object?>> _hashInIsolate(String path, SendPort send) =>
    Isolate.run(() => _hashFile(path, send));

Future<Map<String, Object?>> _hashFile(String path, SendPort send) async {
  final file = File(path);
  final size = await file.length();
  final pieceSize = pieceSizeFor(size);
  final raf = await file.open();
  final hashes = <String>[];
  try {
    var done = 0;
    do {
      final chunk = await raf.read(pieceSize);
      if (chunk.isEmpty && size != 0) {
        throw const FileSystemException('Fichier raccourci pendant la lecture');
      }
      hashes.add(b64(sha256Bytes(chunk)));
      done += chunk.length;
      send.send(size == 0 ? 1.0 : done / size);
    } while (done < size);
  } finally {
    await raf.close();
  }
  return Manifest(p.basename(path), size, pieceSize, hashes).toJson();
}
