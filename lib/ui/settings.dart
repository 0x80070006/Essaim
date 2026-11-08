import 'dart:io';

import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../core/account.dart';
import 'kit.dart';

class SettingsTab extends StatelessWidget {
  const SettingsTab(this.app, {super.key});
  final AppController app;

  Future<String?> _ask(BuildContext c, String title, String label,
          {bool secret = true, String initial = ''}) =>
      showDialog<String>(
        context: c,
        builder: (d) {
          final t = TextEditingController(text: initial);
          return AlertDialog(
            title: Text(title),
            content: TextField(controller: t, obscureText: secret, autofocus: true,
                decoration: InputDecoration(labelText: label)),
            actions: [
              TextButton(onPressed: () => Navigator.pop(d), child: const Text('Annuler')),
              FilledButton(onPressed: () => Navigator.pop(d, t.text), child: const Text('Valider')),
            ],
          );
        },
      );

  Future<void> _rename(BuildContext c) async {
    final name = await _ask(c, 'Nom de cet appareil', 'Nom', secret: false, initial: app.deviceName);
    if (name != null && name.trim().isNotEmpty) await app.rename(name.trim());
  }

  Future<void> _changePassword(BuildContext c) async {
    final cur = await _ask(c, 'Changer le mot de passe', 'Mot de passe actuel');
    if (cur == null || !c.mounted) return;
    final next = await _ask(c, 'Changer le mot de passe', 'Nouveau (8 caractères minimum)');
    if (next == null || !c.mounted) return;
    if (next.length < 8) return toast(c, 'Il faut au moins 8 caractères');
    try {
      await app.changePassword(cur, next);
      if (c.mounted) toast(c, 'Mot de passe changé sur tous tes appareils');
    } on BadSecret {
      if (c.mounted) toast(c, 'Mot de passe actuel incorrect');
    }
  }

  Future<void> _newCodes(BuildContext c) async {
    final cur = await _ask(c, 'Nouveaux codes de sécurité', 'Mot de passe');
    if (cur == null || !c.mounted) return;
    try {
      await app.regenerateCodes(cur);
    } on BadSecret {
      if (c.mounted) toast(c, 'Mot de passe incorrect');
    }
  }

  Future<void> _biometric(BuildContext c, bool on) async {
    final ok = await app.setBiometric(on);
    if (!ok && c.mounted) {
      toast(c, "Empreinte refusée. Vérifie qu'une empreinte est enregistrée sur le téléphone.");
    }
  }

  Widget _title(String t) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 6),
        child: Text(t, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
      );

  @override
  Widget build(BuildContext context) {
    final node = app.node!;
    const lockChoices = {0: 'Immédiatement', 2: 'Après 2 minutes', 5: 'Après 5 minutes', 15: 'Après 15 minutes', -1: 'Jamais'};
    return ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
      _title('Sécurité'),
      if (Platform.isAndroid)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.fingerprint_rounded),
          title: const Text('Déverrouiller avec mon empreinte'),
          subtitle: app.biometricAvailable ? null : const Text('Non disponible sur cet appareil'),
          value: app.biometricEnabled,
          onChanged: app.biometricAvailable ? (v) => _biometric(context, v) : null,
        ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.timer_outlined),
        title: const Text('Verrouillage automatique'),
        trailing: DropdownButton<int>(
          value: app.autoLockMinutes,
          underline: const SizedBox.shrink(),
          items: [for (final e in lockChoices.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
          onChanged: (v) => app.setAutoLock(v!),
        ),
      ),
      ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.password_rounded),
          title: const Text('Changer le mot de passe'), onTap: () => _changePassword(context)),
      ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.key_rounded),
          title: const Text('Générer de nouveaux codes de sécurité'),
          subtitle: Text('${node.vault.recoveryLeft} code(s) restant(s)'),
          onTap: () => _newCodes(context)),
      _title('Cet appareil'),
      ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.badge_outlined),
          title: const Text('Nom'), subtitle: Text(app.deviceName), onTap: () => _rename(context)),
      ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.folder_outlined),
          title: const Text('Dossier des téléchargements'), subtitle: Text(app.downloadsFolder)),
      if (Platform.isWindows)
        FutureBuilder<bool>(
          future: app.startsWithWindows(),
          builder: (_, s) => SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.power_settings_new_rounded),
            title: const Text('Lancer Essaim au démarrage de Windows'),
            value: s.data ?? false,
            onChanged: app.setStartsWithWindows,
          ),
        ),
      _title('Apparence'),
      SegmentedButton<ThemeMode>(
        segments: const [
          ButtonSegment(value: ThemeMode.system, label: Text('Système')),
          ButtonSegment(value: ThemeMode.light, label: Text('Clair')),
          ButtonSegment(value: ThemeMode.dark, label: Text('Sombre')),
        ],
        selected: {app.themeMode},
        onSelectionChanged: (v) => app.setTheme(v.first),
      ),
    ]);
  }
}
