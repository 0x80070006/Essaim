import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/controller.dart';
import '../core/account.dart';
import '../core/node.dart';
import 'kit.dart';

const int _minPassword = 8;

class Welcome extends StatelessWidget {
  const Welcome(this.app, {super.key});
  final AppController app;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Narrow(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Center(child: logo(112)),
            const SizedBox(height: 20),
            const Text('Essaim', textAlign: TextAlign.center,
                style: TextStyle(fontSize: 44, fontWeight: FontWeight.w900)),
            const SizedBox(height: 6),
            const Text('Tes fichiers, de tes appareils à tes appareils.',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 16)),
            const SizedBox(height: 36),
            FilledButton(
              onPressed: () => _go(context, CreatePassword(app)),
              child: const Text('Créer mon compte'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.all(16)),
              onPressed: () => _go(context, JoinAccount(app)),
              child: const Text("J'ai déjà un compte sur un autre appareil"),
            ),
          ]),
        ),
      );

  void _go(BuildContext c, Widget page) =>
      Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => page));
}

class _PasswordPair extends StatefulWidget {
  const _PasswordPair({required this.label, required this.onSubmit});
  final String label;
  final Future<void> Function(String) onSubmit;
  @override
  State<_PasswordPair> createState() => _PasswordPairState();
}

class _PasswordPairState extends State<_PasswordPair> {
  final _a = TextEditingController();
  final _b = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _submit() async {
    if (_a.text.length < _minPassword) {
      return setState(() => _error = 'Au moins $_minPassword caractères.');
    }
    if (_a.text != _b.text) {
      return setState(() => _error = 'Les deux mots de passe sont différents.');
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSubmit(_a.text);
    } on BadSecret {
      if (mounted) setState(() => _error = 'Code incorrect ou déjà utilisé.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(controller: _a, obscureText: true,
            decoration: const InputDecoration(labelText: 'Nouveau mot de passe')),
        const SizedBox(height: 12),
        TextField(controller: _b, obscureText: true, onSubmitted: (_) => _submit(),
            decoration: InputDecoration(labelText: 'Encore une fois', errorText: _error)),
        const SizedBox(height: 18),
        FilledButton(onPressed: _busy ? null : _submit,
            child: Text(_busy ? 'Un instant…' : widget.label)),
      ]);
}

class CreatePassword extends StatelessWidget {
  const CreatePassword(this.app, {super.key});
  final AppController app;
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(backgroundColor: Colors.transparent),
        body: Narrow(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Choisis ton mot de passe',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900)),
            const SizedBox(height: 6),
            const Text('Le même servira sur tous tes appareils.'),
            const SizedBox(height: 24),
            _PasswordPair(
              label: 'Continuer',
              onSubmit: (pw) async {
                await app.createAccount(pw);
                if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
              },
            ),
          ]),
        ),
      );
}

class RecoveryCodes extends StatefulWidget {
  const RecoveryCodes(this.app, {super.key});
  final AppController app;
  @override
  State<RecoveryCodes> createState() => _RecoveryCodesState();
}

class _RecoveryCodesState extends State<RecoveryCodes> {
  bool _saved = false;

  @override
  Widget build(BuildContext context) {
    final codes = widget.app.pendingCodes ?? const <String>[];
    return Scaffold(
      body: Narrow(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Center(child: Hex(size: 56, color: C.tomato,
              child: Icon(Icons.key_rounded, color: Colors.white))),
          const SizedBox(height: 14),
          const Text('Garde ces codes en lieu sûr',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900)),
          const SizedBox(height: 6),
          const Text("Mot de passe oublié ? Chaque code permet de le changer une seule fois. "
              "Ils ne seront plus affichés. Sans eux, un mot de passe perdu ne se récupère pas."),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: cardColor(context), borderRadius: BorderRadius.circular(16)),
            child: SelectableText(codes.join('\n'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 16, height: 1.7, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            icon: const Icon(Icons.copy_rounded),
            label: const Text('Copier les codes'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: codes.join('\n')));
              toast(context, 'Codes copiés');
            },
          ),
          CheckboxListTile(
            value: _saved,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text("Je les ai enregistrés"),
            onChanged: (v) => setState(() => _saved = v ?? false),
          ),
          FilledButton(onPressed: _saved ? widget.app.codesSaved : null, child: const Text('Terminer')),
        ]),
      ),
    );
  }
}

class LockScreen extends StatefulWidget {
  const LockScreen(this.app, {super.key});
  final AppController app;
  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final _pw = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.app.biometricLogin());
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.app.login(_pw.text);
    } on BadSecret {
      if (mounted) setState(() => _error = 'Mot de passe incorrect.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return Scaffold(
      body: Narrow(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Center(child: logo(88)),
          const SizedBox(height: 14),
          const Text('Content de te revoir', textAlign: TextAlign.center,
              style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900)),
          const SizedBox(height: 26),
          TextField(controller: _pw, obscureText: true, autofocus: !app.biometricEnabled,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(labelText: 'Mot de passe', errorText: _error)),
          const SizedBox(height: 14),
          FilledButton(onPressed: _busy ? null : _submit,
              child: Text(_busy ? 'Vérification…' : 'Entrer')),
          if (app.biometricEnabled && app.biometricAvailable) ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.all(14)),
              icon: const Icon(Icons.fingerprint_rounded),
              label: const Text('Utiliser mon empreinte'),
              onPressed: app.biometricLogin,
            ),
          ],
          TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ResetPassword(app))),
            child: const Text('Mot de passe oublié ?'),
          ),
        ]),
      ),
    );
  }
}

class ResetPassword extends StatelessWidget {
  ResetPassword(this.app, {super.key});
  final AppController app;
  final TextEditingController _code = TextEditingController();

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(backgroundColor: Colors.transparent),
        body: Narrow(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Nouveau mot de passe', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900)),
            const SizedBox(height: 6),
            const Text('Entre un de tes codes de sécurité. Il ne resservira plus.'),
            const SizedBox(height: 20),
            TextField(controller: _code,
                decoration: const InputDecoration(labelText: 'Code de sécurité', hintText: 'XXXX-XXXX-XXXX-XXXX')),
            const SizedBox(height: 12),
            _PasswordPair(
              label: 'Changer le mot de passe',
              onSubmit: (pw) async {
                await app.resetPassword(_code.text, pw);
                if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
              },
            ),
          ]),
        ),
      );
}

class JoinAccount extends StatefulWidget {
  const JoinAccount(this.app, {super.key});
  final AppController app;
  @override
  State<JoinAccount> createState() => _JoinAccountState();
}

class _JoinAccountState extends State<JoinAccount> {
  final Map<String, PairableDevice> _found = {};
  final _manual = TextEditingController();
  final _code = TextEditingController();
  String? _selected;
  String? _error;
  bool _scanning = false;
  bool _busy = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _scan();
    _timer = Timer.periodic(const Duration(seconds: 6), (_) => _scan());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _scan() {
    if (_scanning) return;
    _scanning = true;
    scanForPairing().listen(
      (d) {
        if (mounted) setState(() => _found[d.addr] = d);
      },
      onDone: () => _scanning = false,
      onError: (_) => _scanning = false,
    );
  }

  Future<void> _join() async {
    final addr = _selected ?? _manual.text.trim();
    if (addr.isEmpty) return setState(() => _error = 'Choisis un appareil.');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.app.join(addr, _code.text);
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } on WrongPairingCode {
      if (mounted) setState(() => _error = 'Code incorrect ou expiré.');
    } on SocketException {
      if (mounted) setState(() => _error = 'Cet appareil ne répond pas.');
    } on TimeoutException {
      if (mounted) setState(() => _error = 'Cet appareil ne répond pas.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(backgroundColor: Colors.transparent),
        body: Narrow(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Connecter cet appareil', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900)),
            const SizedBox(height: 6),
            const Text('Sur ton autre appareil, ouvre Appareils puis « Ajouter un appareil ». Il apparaîtra ici.'),
            const SizedBox(height: 18),
            if (_found.isEmpty)
              const Row(children: [
                SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 3, color: C.teal)),
                SizedBox(width: 10),
                Text('Recherche sur ton réseau…'),
              ]),
            for (final d in _found.values)
              Card(
                elevation: 0,
                color: _selected == d.addr ? C.marigold : cardColor(context),
                child: ListTile(
                  textColor: _selected == d.addr ? C.ink : null,
                  iconColor: _selected == d.addr ? C.ink : null,
                  leading: Icon(d.platform == 'android' ? Icons.smartphone_rounded : Icons.computer_rounded),
                  title: Text(d.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                  subtitle: Text(d.addr),
                  onTap: () => setState(() => _selected = d.addr),
                ),
              ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Il ne s\'affiche pas ?'),
              children: [
                TextField(controller: _manual, onChanged: (_) => setState(() => _selected = null),
                    decoration: const InputDecoration(labelText: 'Adresse affichée sur cet appareil', hintText: '100.98.152.31')),
              ],
            ),
            const SizedBox(height: 12),
            TextField(controller: _code, keyboardType: TextInputType.number, maxLength: 6,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 28, letterSpacing: 8, fontWeight: FontWeight.w900),
                decoration: InputDecoration(labelText: 'Code à 6 chiffres', counterText: '', errorText: _error)),
            const SizedBox(height: 14),
            FilledButton(onPressed: _busy ? null : _join, child: Text(_busy ? 'Connexion…' : 'Connecter')),
          ]),
        ),
      );
}
