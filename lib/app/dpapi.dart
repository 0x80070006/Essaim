import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final class _Blob extends Struct {
  @Uint32()
  external int size;
  external Pointer<Uint8> data;
}

typedef _CryptNative = Int32 Function(Pointer<_Blob>, Pointer<Utf16>,
    Pointer<_Blob>, Pointer<Void>, Pointer<Void>, Uint32, Pointer<_Blob>);
typedef _CryptDart = int Function(Pointer<_Blob>, Pointer<Utf16>,
    Pointer<_Blob>, Pointer<Void>, Pointer<Void>, int, Pointer<_Blob>);

const int _uiForbidden = 1;

Uint8List _run(String symbol, List<int> input) {
  final fn = DynamicLibrary.open('crypt32.dll')
      .lookupFunction<_CryptNative, _CryptDart>(symbol);
  final localFree = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<Pointer<Void> Function(Pointer<Void>),
          Pointer<Void> Function(Pointer<Void>)>('LocalFree');
  final inBlob = calloc<_Blob>();
  final outBlob = calloc<_Blob>();
  final bytes = calloc<Uint8>(input.length);
  try {
    bytes.asTypedList(input.length).setAll(0, input);
    inBlob.ref
      ..size = input.length
      ..data = bytes;
    final ok = fn(inBlob, nullptr, nullptr, nullptr, nullptr, _uiForbidden, outBlob);
    if (ok == 0) throw StateError('$symbol a échoué');
    final out = Uint8List.fromList(outBlob.ref.data.asTypedList(outBlob.ref.size));
    localFree(outBlob.ref.data.cast());
    return out;
  } finally {
    calloc.free(bytes);
    calloc.free(inBlob);
    calloc.free(outBlob);
  }
}

/// Encrypts for the current Windows user account.
Uint8List dpapiProtect(List<int> plain) => _run('CryptProtectData', plain);

Uint8List dpapiUnprotect(List<int> cipher) => _run('CryptUnprotectData', cipher);
