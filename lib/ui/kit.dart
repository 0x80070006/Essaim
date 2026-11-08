import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:path/path.dart' as p;

import '../core/node.dart';

class C {
  static const paper = Color(0xFFFFF7E8);
  static const ink = Color(0xFF1E1B3A);
  static const night = Color(0xFF17152B);
  static const nightCard = Color(0xFF26233F);
  static const marigold = Color(0xFFFFB800);
  static const tomato = Color(0xFFF0492E);
  static const teal = Color(0xFF00A39A);
  static const blue = Color(0xFF2D6BFF);
  static const pink = Color(0xFFE93D82);
  static const green = Color(0xFF2FA84F);
  static const grape = Color(0xFF7A4DE0);
  static const slate = Color(0xFF7C7A92);
}

ThemeData buildTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final fg = dark ? C.paper : C.ink;
  final scheme = ColorScheme.fromSeed(seedColor: C.marigold, brightness: b).copyWith(
    primary: C.marigold,
    onPrimary: C.ink,
    secondary: C.teal,
    error: C.tomato,
    surface: dark ? C.night : C.paper,
    onSurface: fg,
  );
  OutlineInputBorder border(Color c) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: c, width: 2));
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    textTheme: Typography.material2021(platform: TargetPlatform.android)
        .black
        .apply(bodyColor: fg, displayColor: fg),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? C.nightCard : Colors.white,
      enabledBorder: border(fg.withValues(alpha: .18)),
      focusedBorder: border(C.marigold),
      errorBorder: border(C.tomato),
      focusedErrorBorder: border(C.tomato),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      scrolledUnderElevation: 0,
      systemOverlayStyle: dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
    ),
    // Marigold text is unreadable on paper, so only fills use the primary.
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: fg,
        side: BorderSide(color: fg, width: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: fg)),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: C.marigold,
        foregroundColor: C.ink,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
      ),
    ),
  );
}

Widget logo(double size) => SvgPicture.asset('assets/logo.svg', width: size, height: size);

Color cardColor(BuildContext c) =>
    Theme.of(c).brightness == Brightness.dark ? C.nightCard : Colors.white;

class _HexClip extends CustomClipper<Path> {
  @override
  Path getClip(Size s) => Path()
    ..moveTo(s.width / 2, 0)
    ..lineTo(s.width, s.height * .25)
    ..lineTo(s.width, s.height * .75)
    ..lineTo(s.width / 2, s.height)
    ..lineTo(0, s.height * .75)
    ..lineTo(0, s.height * .25)
    ..close();
  @override
  bool shouldReclip(covariant CustomClipper<Path> old) => false;
}

class Hex extends StatelessWidget {
  const Hex({super.key, required this.size, required this.color, this.child});
  final double size;
  final Color color;
  final Widget? child;
  @override
  Widget build(BuildContext context) => ClipPath(
        clipper: _HexClip(),
        child: Container(
            width: size * .92, height: size, color: color, alignment: Alignment.center, child: child),
      );
}

({String label, Color color}) kindOf(String name) {
  final ext = p.extension(name).replaceFirst('.', '').toLowerCase();
  final groups = <Color, List<String>>{
    C.green: ['apk', 'aab', 'xapk'],
    C.pink: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'heic', 'svg'],
    C.blue: ['mp4', 'mkv', 'avi', 'mov', 'webm'],
    C.grape: ['mp3', 'flac', 'wav', 'ogg', 'm4a'],
    C.tomato: ['zip', 'rar', '7z', 'tar', 'gz', 'iso'],
    C.teal: ['pdf', 'doc', 'docx', 'txt', 'md', 'odt', 'xls', 'xlsx', 'csv'],
    C.marigold: ['exe', 'msi', 'bat', 'sh'],
  };
  for (final g in groups.entries) {
    if (g.value.contains(ext)) return (label: ext.toUpperCase(), color: g.key);
  }
  return (label: ext.isEmpty ? '?' : ext.toUpperCase(), color: C.slate);
}

class FileHex extends StatelessWidget {
  const FileHex(this.name, {super.key, this.size = 56});
  final String name;
  final double size;
  @override
  Widget build(BuildContext context) {
    final k = kindOf(name);
    final text = k.label.length > 4 ? k.label.substring(0, 4) : k.label;
    return Hex(
      size: size,
      color: k.color,
      child: Text(text,
          style: TextStyle(
              color: k.color == C.marigold ? C.ink : Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: size * .24)),
    );
  }
}

({String label, Color color, IconData icon}) statusOf(ItemStatus s) => switch (s) {
      ItemStatus.seeding => (label: 'En partage', color: C.green, icon: Icons.upload_rounded),
      ItemStatus.finished => (label: 'Terminé', color: C.grape, icon: Icons.check_rounded),
      ItemStatus.downloading => (label: 'Téléchargement', color: C.blue, icon: Icons.download_rounded),
      ItemStatus.stalled => (label: 'En attente de pairs', color: C.marigold, icon: Icons.hourglass_top_rounded),
      ItemStatus.paused => (label: 'En pause', color: C.slate, icon: Icons.pause_rounded),
      ItemStatus.available => (label: 'Disponible', color: C.teal, icon: Icons.bolt_rounded),
      ItemStatus.unreachable => (label: 'Source hors ligne', color: C.slate, icon: Icons.cloud_off_rounded),
      ItemStatus.missing => (label: 'Fichier introuvable', color: C.tomato, icon: Icons.error_outline_rounded),
    };

class StatusPill extends StatelessWidget {
  const StatusPill(this.status, {super.key});
  final ItemStatus status;
  @override
  Widget build(BuildContext context) {
    final s = statusOf(status);
    final fg = s.color == C.marigold ? C.ink : Colors.white;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: s.color, borderRadius: BorderRadius.circular(99)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(s.icon, size: 14, color: fg),
        const SizedBox(width: 4),
        Text(s.label, style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w800)),
      ]),
    );
  }
}

/// One hexagon per device: solid holds the whole file, tinted holds part of
/// it, hollow is offline.
class PeerHexes extends StatelessWidget {
  const PeerHexes(this.peers, {super.key});
  final List<PeerProgress> peers;
  @override
  Widget build(BuildContext context) {
    if (peers.isEmpty) return const SizedBox.shrink();
    final off = Theme.of(context).colorScheme.onSurface.withValues(alpha: .16);
    return Wrap(spacing: 3, children: [
      for (final x in peers)
        Tooltip(
          message: '${x.name} · ${(x.progress * 100).round()} %${x.online ? '' : ' · hors ligne'}',
          child: Hex(
            size: 16,
            color: !x.online
                ? off
                : x.progress >= 1
                    ? C.green
                    : C.marigold.withValues(alpha: .35 + x.progress * .65),
          ),
        ),
    ]);
  }
}

String formatBytes(num b) {
  const units = ['o', 'Ko', 'Mo', 'Go', 'To'];
  var v = b.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 || v >= 100 ? 0 : 1)} ${units[i]}';
}

String formatEta(double seconds) {
  if (seconds < 60) return '${seconds.ceil()} s';
  if (seconds < 3600) return '${(seconds / 60).ceil()} min';
  return '${(seconds / 3600).toStringAsFixed(1)} h';
}

String peersLine(CatalogItem i) {
  final p = i.onlinePeers;
  final s = i.onlineSeeds;
  return '$p pair${p > 1 ? 's' : ''} en ligne · $s source${s > 1 ? 's' : ''} complète${s > 1 ? 's' : ''}';
}

class Narrow extends StatelessWidget {
  const Narrow({super.key, required this.child, this.width = 420});
  final Widget child;
  final double width;
  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width),
          child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: child),
        ),
      );
}

void toast(BuildContext c, String text) =>
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(text)));
