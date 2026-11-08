import 'package:essaim/app/dpapi.dart';
import 'package:test/test.dart';

void main() {
  test('DPAPI chiffre et restitue la clé', () {
    final key = List<int>.generate(32, (i) => i * 7 % 256);
    final sealed = dpapiProtect(key);
    expect(sealed, isNot(key));
    expect(dpapiUnprotect(sealed), key);
  });
}
