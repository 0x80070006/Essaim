import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app/controller.dart';
import '../core/node.dart';
import 'kit.dart';
import 'settings.dart';

class Home extends StatefulWidget {
  const Home(this.app, {super.key});
  final AppController app;
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final node = app.node!;
    final online = node.devices.where((d) => d.online).length;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                child: Row(children: [
                  logo(36),
                  const SizedBox(width: 8),
                  const Text('Essaim', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
                  const Spacer(),
                  ActionChip(
                    avatar: const Icon(Icons.devices_rounded, size: 18),
                    label: Text('$online en ligne'),
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(builder: (_) => DevicesPage(app))),
                  ),
                  IconButton(tooltip: 'Verrouiller', icon: const Icon(Icons.lock_rounded), onPressed: app.lock),
                ]),
              ),
              if (!node.tailscaleUp)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: C.tomato, borderRadius: BorderRadius.circular(12)),
                  child: const Text('Tailscale est coupé : le partage reprendra dès sa reconnexion.',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  _TabButton('Déposer', Icons.add_rounded, C.tomato, _tab == 0, () => setState(() => _tab = 0)),
                  const SizedBox(width: 10),
                  _TabButton('Catalogue · ${node.items.length}', Icons.grid_view_rounded, C.teal, _tab == 1,
                      () => setState(() => _tab = 1)),
                  const SizedBox(width: 10),
                  _TabButton('Réglages', Icons.tune_rounded, C.grape, _tab == 2, () => setState(() => _tab = 2)),
                ]),
              ),
              Expanded(
                child: switch (_tab) {
                  0 => _UploadTab(app, () => setState(() => _tab = 1)),
                  1 => _CatalogTab(app),
                  _ => SettingsTab(app),
                },
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton(this.label, this.icon, this.color, this.active, this.onTap);
  final String label;
  final IconData icon;
  final Color color;
  final bool active;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final fg = active ? Colors.white : Theme.of(context).colorScheme.onSurface;
    return Expanded(
      child: Material(
        color: active ? color : cardColor(context),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, color: fg, size: 18),
                const SizedBox(width: 5),
                Text(label, style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: 14)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _UploadTab extends StatefulWidget {
  const _UploadTab(this.app, this.showCatalog);
  final AppController app;
  final VoidCallback showCatalog;
  @override
  State<_UploadTab> createState() => _UploadTabState();
}

class _UploadTabState extends State<_UploadTab> {
  bool _hover = false;

  Future<void> _shareAll(Iterable<String> paths) async {
    final node = widget.app.node!;
    try {
      await Future.wait(paths.map(node.share));
    } on FileSystemException catch (e) {
      if (mounted) toast(context, 'Lecture impossible : ${e.path ?? e.message}');
    }
  }

  Future<void> _pick() async {
    if (Platform.isAndroid) {
      if (!await widget.app.ensureFileAccess()) {
        if (mounted) toast(context, "Autorise l'accès aux fichiers, puis réessaie.");
        return;
      }
      if (!mounted) return;
      final path = await Navigator.of(context).push<String>(
          MaterialPageRoute(builder: (_) => const PhoneFileBrowser()));
      if (path != null) await _shareAll([path]);
    } else {
      final picked = await FilePicker.pickFiles();
      await _shareAll(picked.map((f) => f.path).whereType<String>());
    }
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.app.node!;
    final mine = node.items.where((i) => i.localPath != null).take(5).toList();
    final zone = Material(
      color: _hover ? C.marigold : C.marigold.withValues(alpha: .22),
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: _pick,
        child: const SizedBox(
          height: 220,
          width: double.infinity,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Hex(size: 72, color: C.tomato, child: Icon(Icons.add_rounded, color: Colors.white, size: 38)),
            SizedBox(height: 12),
            Text('Choisis un fichier', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900)),
            SizedBox(height: 2),
            Text('Il reste à sa place et se partage tant que cet appareil est connecté.',
                textAlign: TextAlign.center),
          ]),
        ),
      ),
    );
    return ListView(padding: const EdgeInsets.symmetric(horizontal: 16), children: [
      if (Platform.isWindows)
        DropTarget(
          onDragEntered: (_) => setState(() => _hover = true),
          onDragExited: (_) => setState(() => _hover = false),
          onDragDone: (d) {
            setState(() => _hover = false);
            unawaited(_shareAll(d.files.map((f) => f.path)));
          },
          child: zone,
        )
      else
        zone,
      const SizedBox(height: 18),
      for (final j in node.hashingJobs)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _Panel(child: Row(children: [
            FileHex(j.name, size: 44),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(j.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text('Préparation · ${(j.progress * 100).round()} %'),
              const SizedBox(height: 6),
              LinearProgressIndicator(value: j.progress, color: C.tomato, minHeight: 7,
                  borderRadius: BorderRadius.circular(9)),
            ])),
          ])),
        ),
      if (mine.isNotEmpty)
        Row(children: [
          const Expanded(child: Text('Sur cet appareil', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900))),
          TextButton(onPressed: widget.showCatalog, child: const Text('Tout voir')),
        ]),
      for (final i in mine) _FileCard(widget.app, i),
    ]);
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: cardColor(context), borderRadius: BorderRadius.circular(18)),
        child: child,
      );
}

class _CatalogTab extends StatefulWidget {
  const _CatalogTab(this.app);
  final AppController app;
  @override
  State<_CatalogTab> createState() => _CatalogTabState();
}

class _CatalogTabState extends State<_CatalogTab> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final items = widget.app.node!.items
        .where((i) => i.entry.name.toLowerCase().contains(_q.toLowerCase()))
        .toList();
    return ListView(padding: const EdgeInsets.symmetric(horizontal: 16), children: [
      TextField(
        onChanged: (v) => setState(() => _q = v),
        decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded), hintText: 'Chercher un fichier'),
      ),
      const SizedBox(height: 12),
      if (items.isEmpty)
        const Padding(
          padding: EdgeInsets.all(40),
          child: Text('Rien ici pour le moment. Dépose un premier fichier !', textAlign: TextAlign.center),
        ),
      for (final i in items) _FileCard(widget.app, i),
      const SizedBox(height: 20),
    ]);
  }
}

class _FileCard extends StatelessWidget {
  const _FileCard(this.app, this.item);
  final AppController app;
  final CatalogItem item;

  @override
  Widget build(BuildContext context) {
    final node = app.node!;
    final id = item.entry.id;
    final downloading = item.status == ItemStatus.downloading;
    final partial = downloading || item.status == ItemStatus.paused || item.status == ItemStatus.stalled;
    final remaining = item.entry.size * (1 - item.progress);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: cardColor(context),
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => _details(context),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              FileHex(item.entry.name),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(item.entry.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                  const SizedBox(height: 4),
                  Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    StatusPill(item.status),
                    Text(formatBytes(item.entry.size), style: const TextStyle(fontSize: 13)),
                    if (item.up > 0) Text('↑ ${formatBytes(item.up)}/s', style: const TextStyle(fontSize: 13, color: C.green, fontWeight: FontWeight.w700)),
                  ]),
                  if (partial) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: item.progress, minHeight: 7, color: statusOf(item.status).color,
                        borderRadius: BorderRadius.circular(9)),
                    const SizedBox(height: 3),
                    Text([
                      '${(item.progress * 100).round()} %',
                      if (downloading && item.down > 0) '↓ ${formatBytes(item.down)}/s',
                      if (downloading && item.down > 0) 'reste ${formatEta(remaining / item.down)}',
                    ].join(' · '), style: const TextStyle(fontSize: 13)),
                  ],
                  if (item.error != null) ...[
                    const SizedBox(height: 5),
                    Text(item.error!, style: const TextStyle(fontSize: 13, color: C.tomato, fontWeight: FontWeight.w700)),
                  ],
                  for (final x in item.peers.where((x) => !x.self && x.online && x.progress < 1))
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('${x.name} : ${(x.progress * 100).round()} %',
                          style: const TextStyle(fontSize: 13, color: C.blue, fontWeight: FontWeight.w700)),
                    ),
                  const SizedBox(height: 7),
                  Row(children: [
                    PeerHexes(item.peers),
                    const SizedBox(width: 7),
                    Flexible(child: Text(peersLine(item), maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12))),
                  ]),
                ]),
              ),
              const SizedBox(width: 6),
              switch (item.status) {
                ItemStatus.available => IconButton.filled(
                    tooltip: 'Télécharger',
                    style: IconButton.styleFrom(backgroundColor: C.teal, foregroundColor: Colors.white),
                    icon: const Icon(Icons.download_rounded),
                    onPressed: () => _download(context, node, id)),
                ItemStatus.downloading || ItemStatus.stalled => IconButton(
                    tooltip: 'Mettre en pause', icon: const Icon(Icons.pause_rounded), onPressed: () => node.pause(id)),
                ItemStatus.paused => IconButton(
                    tooltip: 'Reprendre', icon: const Icon(Icons.play_arrow_rounded), onPressed: () => node.resume(id)),
                ItemStatus.seeding || ItemStatus.finished => IconButton(
                    tooltip: 'Ouvrir', icon: const Icon(Icons.open_in_new_rounded), onPressed: () => app.openFile(item.localPath!)),
                _ => const SizedBox.shrink(),
              },
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _download(BuildContext context, Node node, String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Télécharger ce fichier ?'),
        content: Text('${item.entry.name}\n${formatBytes(item.entry.size)} · ${peersLine(item)}\n\nDestination : ${app.downloadsFolder}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Télécharger')),
        ],
      ),
    );
    if (ok != true) return;
    if (!await app.ensureFileAccess()) {
      if (context.mounted) toast(context, "Sans l'accès aux fichiers, le téléchargement ne peut pas démarrer.");
      return;
    }
    try {
      await node.download(id);
    } on FileSystemException catch (e) {
      if (context.mounted) toast(context, 'Écriture impossible : ${e.osError?.message ?? e.message}');
    }
  }

  void _details(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _FileSheet(app, item.entry.id),
    );
  }
}

class _FileSheet extends StatelessWidget {
  const _FileSheet(this.app, this.id);
  final AppController app;
  final String id;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          final node = app.node!;
          final item = node.items.where((i) => i.entry.id == id).firstOrNull;
          if (item == null) return const SizedBox(height: 80);
          final s = item.status;
          final done = s == ItemStatus.seeding || s == ItemStatus.finished;
          final partial = s == ItemStatus.downloading || s == ItemStatus.stalled || s == ItemStatus.paused;
          return SafeArea(
            child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(20, 0, 20, 16), children: [
              Text(item.entry.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
              const SizedBox(height: 6),
              Row(children: [StatusPill(s), const SizedBox(width: 8), Text(formatBytes(item.entry.size))]),
              if (item.localPath != null) ...[const SizedBox(height: 6), SelectableText(item.localPath!)],
              if (item.error != null) ...[
                const SizedBox(height: 6),
                Text(item.error!, style: const TextStyle(color: C.tomato, fontWeight: FontWeight.w700)),
              ],
              const SizedBox(height: 14),
              if (done)
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('En partage'), icon: Icon(Icons.upload_rounded)),
                    ButtonSegment(value: false, label: Text('Terminé'), icon: Icon(Icons.check_rounded)),
                  ],
                  selected: {s == ItemStatus.seeding},
                  onSelectionChanged: (v) => node.setSharing(id, v.first),
                ),
              if (partial) ...[
                LinearProgressIndicator(value: item.progress, minHeight: 9, color: statusOf(s).color,
                    borderRadius: BorderRadius.circular(9)),
                const SizedBox(height: 4),
                Text('${(item.progress * 100).round()} % sur cet appareil'),
                const SizedBox(height: 10),
                FilledButton.icon(
                  icon: Icon(s == ItemStatus.paused ? Icons.play_arrow_rounded : Icons.pause_rounded),
                  label: Text(s == ItemStatus.paused ? 'Reprendre' : 'Mettre en pause'),
                  onPressed: () => s == ItemStatus.paused ? node.resume(id) : node.pause(id),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.close_rounded),
                  label: const Text('Annuler le téléchargement'),
                  onPressed: () {
                    node.stopSharing(id);
                    Navigator.pop(context);
                  },
                ),
              ],
              const SizedBox(height: 8),
              const Text('Appareils', style: TextStyle(fontWeight: FontWeight.w900)),
              if (item.peers.isEmpty) const Text('Aucun appareil ne propose ce fichier pour le moment.'),
              for (final x in item.peers)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(children: [
                    Icon(x.platform == 'android' ? Icons.smartphone_rounded : Icons.computer_rounded,
                        color: x.online ? C.green : C.slate),
                    const SizedBox(width: 10),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(x.self ? '${x.name} (cet appareil)' : x.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 3),
                      LinearProgressIndicator(value: x.progress, minHeight: 6, color: x.progress >= 1 ? C.green : C.blue,
                          borderRadius: BorderRadius.circular(9)),
                    ])),
                    const SizedBox(width: 10),
                    Text(x.online ? '${(x.progress * 100).round()} %' : 'Hors ligne'),
                  ]),
                ),
              if (done)
                TextButton.icon(
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('Oublier ce fichier sur cet appareil'),
                  onPressed: () {
                    node.stopSharing(id);
                    Navigator.pop(context);
                  },
                ),
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: C.tomato),
                icon: const Icon(Icons.delete_outline_rounded),
                label: const Text('Retirer du catalogue (tous les appareils)'),
                onPressed: () {
                  node.removeFromCatalog(id);
                  Navigator.pop(context);
                },
              ),
            ]),
          );
        },
      );
}

class PhoneFileBrowser extends StatefulWidget {
  const PhoneFileBrowser({super.key});
  @override
  State<PhoneFileBrowser> createState() => _PhoneFileBrowserState();
}

class _PhoneFileBrowserState extends State<PhoneFileBrowser> {
  static const _root = '/storage/emulated/0';
  String _dir = '$_root/Download';

  @override
  Widget build(BuildContext context) {
    final entries = Directory(_dir).listSync()
      ..removeWhere((e) => p.basename(e.path).startsWith('.'))
      ..sort((a, b) {
        final d = (a is Directory ? 0 : 1) - (b is Directory ? 0 : 1);
        return d != 0 ? d : a.path.toLowerCase().compareTo(b.path.toLowerCase());
      });
    return PopScope(
      canPop: _dir == _root,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) setState(() => _dir = p.dirname(_dir));
      },
      child: Scaffold(
        appBar: AppBar(title: Text(_dir == _root ? 'Stockage' : p.basename(_dir))),
        body: ListView(children: [
          for (final e in entries)
            ListTile(
              leading: e is Directory
                  ? const Hex(size: 40, color: C.marigold, child: Icon(Icons.folder_rounded, color: C.ink, size: 20))
                  : FileHex(e.path, size: 40),
              title: Text(p.basename(e.path)),
              subtitle: e is File ? Text(formatBytes(e.lengthSync())) : null,
              onTap: () => e is Directory
                  ? setState(() => _dir = e.path)
                  : Navigator.of(context).pop(e.path),
            ),
        ]),
      ),
    );
  }
}

class DevicesPage extends StatelessWidget {
  const DevicesPage(this.app, {super.key});
  final AppController app;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Appareils', style: TextStyle(fontWeight: FontWeight.w900))),
        body: ListenableBuilder(
          listenable: app,
          builder: (context, _) {
            final node = app.node!;
            return ListView(padding: const EdgeInsets.all(16), children: [
              FilledButton.icon(
                icon: const Icon(Icons.add_rounded),
                label: const Text('Ajouter un appareil'),
                onPressed: () => showDialog<void>(context: context, builder: (_) => _PairingDialog(node)),
              ),
              const SizedBox(height: 14),
              for (final d in node.devices)
                Card(
                  elevation: 0,
                  color: cardColor(context),
                  child: ListTile(
                    leading: Hex(size: 40, color: d.online ? C.green : C.slate,
                        child: Icon(d.info.platform == 'android' ? Icons.smartphone_rounded : Icons.computer_rounded,
                            color: Colors.white, size: 20)),
                    title: Text(d.self ? '${d.info.name} (cet appareil)' : d.info.name,
                        style: const TextStyle(fontWeight: FontWeight.w800)),
                    subtitle: Text(d.online ? 'En ligne · ${d.info.addrs.join(', ')}' : 'Hors ligne'),
                  ),
                ),
            ]);
          },
        ),
      );
}

class _PairingDialog extends StatefulWidget {
  const _PairingDialog(this.node);
  final Node node;
  @override
  State<_PairingDialog> createState() => _PairingDialogState();
}

class _PairingDialogState extends State<_PairingDialog> {
  late final PairingSession _s = widget.node.startPairing();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    widget.node.onPaired = () {
      if (mounted) Navigator.pop(context);
    };
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (DateTime.now().isAfter(_s.expires) || widget.node.pairing == null) {
        Navigator.pop(context);
      } else {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.node.onPaired = null;
    widget.node.cancelPairing();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final left = _s.expires.difference(DateTime.now());
    final code = '${_s.code.substring(0, 3)} ${_s.code.substring(3)}';
    return AlertDialog(
      title: const Text('Sur le nouvel appareil, entre :'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(code, style: const TextStyle(fontSize: 46, fontWeight: FontWeight.w900, color: C.tomato)),
        Text('Expire dans ${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')}'),
        const SizedBox(height: 10),
        if (_s.addrs.isNotEmpty) SelectableText('Adresse : ${_s.addrs.first.split(':').first}'),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler'))],
    );
  }
}
