import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:essaim/core/account.dart';
import 'package:essaim/core/crypto.dart';
import 'package:essaim/core/node.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<void> until(bool Function() ok, {int seconds = 40, String what = ''}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('Délai dépassé : $what');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('essaim'));
  tearDown(() async {
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  Future<Node> node(String name, int port, AccountCreated a) async {
    final n = Node(
      dataDir: p.join(root.path, name, 'data'),
      downloadsDir: p.join(root.path, name, 'dl'),
      networkKey: a.networkKey,
      vault: a.vault,
      deviceName: name,
      platform: 'test',
      port: port,
      allowAnyNetwork: true,
      advertised: ['127.0.0.1:$port'],
      syncInterval: const Duration(milliseconds: 200),
    );
    await n.start();
    return n;
  }

  test('compte : mot de passe, code de secours à usage unique', () async {
    final a = await Vault.create('correct horse', 'pc');
    expect(await a.vault.unlock('correct horse'), a.networkKey);
    await expectLater(a.vault.unlock('faux'), throwsA(isA<BadSecret>()));

    final code = a.recoveryCodes[3].toLowerCase();
    final v2 = await a.vault.resetPassword(code, 'nouveau mdp', 'pc');
    expect(await v2.unlock('nouveau mdp'), a.networkKey);
    await expectLater(v2.unlock('correct horse'), throwsA(isA<BadSecret>()));
    expect(v2.recoveryLeft, recoveryCodeCount - 1);
    await expectLater(
        v2.resetPassword(code, 'encore', 'pc'), throwsA(isA<BadSecret>()));
    expect(v2.isAuthentic(a.networkKey), isTrue);
    expect(v2.isNewerThan(a.vault), isTrue);
    expect(v2.isAuthentic(randomBytes(32)), isFalse);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('appairage : bon code accepté, mauvais code refusé', () async {
    final a = await Vault.create('motdepasse', 'pc');
    final host = await node('hote', 48110, a);
    addTearDown(host.stop);

    final s = host.startPairing();
    final wrong = s.code == '000000' ? '000001' : '000000';
    await expectLater(joinWithCode('127.0.0.1:48110', wrong),
        throwsA(isA<WrongPairingCode>()));

    final r = await joinWithCode('127.0.0.1:48110', s.code);
    expect(r.networkKey, a.networkKey);
    expect(r.host.name, 'hote');
    expect(r.vault.isAuthentic(a.networkKey), isTrue);
    expect(host.pairing, isNull);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('un pair sans la clé est rejeté', () async {
    final a = await Vault.create('motdepasse', 'pc');
    final b = await Vault.create('autre', 'pc2');
    final na = await node('a', 48120, a);
    final nb = await node('b', 48121, b);
    addTearDown(na.stop);
    addTearDown(nb.stop);
    await nb.addPeer(DeviceInfo('x', 'a', 'test', ['127.0.0.1:48120']));
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(nb.devices.where((d) => !d.self && d.online), isEmpty);
    expect(na.devices.where((d) => !d.self), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('essaim : A partage, B télécharge, C récupère depuis B sans A', () async {
    final a = await Vault.create('motdepasse', 'pc');
    final na = await node('A', 48130, a);
    final nb = await node('B', 48131, a);
    final nc = await node('C', 48132, a);
    addTearDown(nb.stop);
    addTearDown(nc.stop);

    final bytes = List<int>.generate(3 * 1024 * 1024 + 123, (_) => Random().nextInt(256));
    final src = File(p.join(root.path, 'été démo.apk'))..writeAsBytesSync(bytes);

    await nb.addPeer(na.self);
    await nc.addPeer(nb.self);
    final id = await na.share(src.path);
    expect(File(src.path).existsSync(), isTrue, reason: 'le fichier reste en place');

    await until(() => nb.items.any((i) => i.entry.id == id && i.status == ItemStatus.available),
        what: 'catalogue vers B');
    expect(nb.items.single.onlineSeeds, 1);

    await nb.download(id);
    await until(() => nb.items.single.status == ItemStatus.seeding, what: 'B complet');
    final bFile = File(nb.items.single.localPath!);
    expect(p.basename(bFile.path), 'été démo.apk');
    expect(sha256Hex(bFile.readAsBytesSync()), sha256Hex(bytes));

    await until(() => na.items.single.onlinePeers == 1, what: 'A voit B');

    await nb.setSharing(id, false);
    expect(nb.items.single.status, ItemStatus.finished);
    await until(() => na.items.single.onlinePeers == 0, what: 'Terminé retire B');
    await nb.setSharing(id, true);
    await until(() => na.items.single.onlinePeers == 1, what: 'B repartage');

    await na.stop();
    await until(() => nc.items.any((i) => i.entry.id == id && i.status == ItemStatus.available),
        what: 'catalogue vers C');
    await nc.download(id);
    await until(() => nc.items.single.status == ItemStatus.seeding, what: 'C complet depuis B');
    expect(sha256Hex(File(nc.items.single.localPath!).readAsBytesSync()), sha256Hex(bytes));
    await until(() => nb.items.single.onlineSeeds == 2, what: 'B compte 2 sources');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('reprise, fichier déplacé et retrait du catalogue', () async {
    final a = await Vault.create('motdepasse', 'pc');
    final na = await node('A', 48140, a);
    final nb = await node('B', 48141, a);
    addTearDown(na.stop);
    addTearDown(nb.stop);
    final src = File(p.join(root.path, 'doc.bin'))
      ..writeAsBytesSync(List<int>.filled(800 * 1024, 7));
    await nb.addPeer(na.self);
    final id = await na.share(src.path);
    await until(() => nb.items.isNotEmpty, what: 'catalogue');

    await nb.download(id);
    await nb.pause(id);
    expect(nb.items.single.status, anyOf(ItemStatus.paused, ItemStatus.seeding));
    await nb.resume(id);
    await until(() => nb.items.single.status == ItemStatus.seeding, what: 'reprise');

    src.renameSync('${src.path}.moved');
    await until(() => na.items.single.status == ItemStatus.missing,
        seconds: 15, what: 'fichier manquant détecté');

    await na.removeFromCatalog(id);
    await until(() => nb.items.isEmpty, what: 'retrait propagé');
    expect(File(p.join(root.path, 'B', 'dl', 'doc.bin')).existsSync(), isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
