# Essaim

Partage de fichiers en P2P entre tes propres appareils (Android et Windows), à travers Tailscale, sans serveur.

- Un fichier déposé reste à son emplacement et se partage tant que l'appareil est connecté.
- Les fichiers circulent en morceaux vérifiés par SHA-256 ; chaque appareil repartage ce qu'il reçoit.
- Un seul compte : mot de passe commun, codes de secours, ajout d'appareil par code à 6 chiffres, empreinte sur Android.

## Compiler

Flutter 3.41 ou plus récent. Sous Windows, le mode développeur doit être activé.

    flutter build apk --release
    flutter build windows --release

## Tests

    dart test

## Sécurité

- L'API entre pairs n'accepte que les adresses Tailscale ; seuls la découverte et l'appairage (SPEKE) répondent sur le réseau local.
- Le mot de passe et l'empreinte protègent l'accès à l'interface. Le partage continue app verrouillée, avec une clé scellée par le système (Keystore ou DPAPI).
- Retirer un appareil du compte n'est pas encore possible.