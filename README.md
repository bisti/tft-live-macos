# TFT Live macOS

Lanceur TFT pour macOS Apple Silicon.

Projet indépendant, non affilié à Riot Games.

**[Télécharger la dernière version](https://github.com/bisti/tft-live-macos/releases/latest)**

## Prérequis

- Mac Apple Silicon sous macOS 14 ou plus.
- Riot Client officiel installé.
- Compte Riot pour se connecter dans le client.
- Espace disponible pour le jeu et ses mises à jour. Le téléchargement initial peut dépasser 10 Go.

## Installation

1. Télécharger `TFT-Live-AppleSilicon.zip` depuis les versions publiées.
2. Décompresser et déplacer `TFT Live.app` dans Applications.
3. Ouvrir l’application et se connecter dans Riot.
4. Attendre la préparation du jeu, puis cliquer sur **Jouer** dans Riot.

Le lanceur détecte le serveur du compte, vérifie sa version live et installe ou met
à jour le client TFT Mac. Le moteur Python nécessaire est intégré à l’application.

L’application possède une signature locale et ne dispose pas de notarisation
Apple. macOS peut demander une autorisation lors de la première ouverture.

## Fonctionnement

Le lanceur prépare une copie privée des composants du Riot Client installé et
adapte leur identification de plateforme à Windows. Le jeu exécuté est le client
Mac natif. Les composants sont préparés en ARM64.

La région est obtenue auprès du compte connecté. Le manifeste est sélectionné
à partir des publications Mac et Windows du canal live correspondant, avec un
contrôle de cohérence entre leurs versions. Le patcher Riot effectue les téléchargements.

Les nouvelles versions du runtime Riot sont préparées séparément et vérifiées avant
activation. Un échec de validation déclenche le retour à la version précédente.
La compatibilité dépend des évolutions des composants et services Riot.

## Données locales

Les paramètres, la connexion et les journaux restent dans
`~/Library/Application Support/TFT Live` pour le compte macOS courant.

Une installation TFT existante et modifiable peut être réutilisée. Une nouvelle
installation utilise `~/Applications/Teamfight Tactics (Live).app`.

Le journal principal est `~/Library/Application Support/TFT Live/launcher.log`.
Lors d’un signalement, masquer les informations de compte et les jetons éventuels
avant de partager des journaux.

## Construire depuis les sources

La construction utilise Python 3.9 ou plus et les outils de développement Apple
pour compiler les deux petits exécutables ARM64.

```sh
python3 build_arm64_host.py
python3 portable/build.py
```

La sortie comprend `dist/TFT Live.app`, `dist/TFT-Live-AppleSilicon.zip` et son
empreinte SHA-256. Une copie locale de l’application est également créée à la racine.

Le moteur Python portable est téléchargé depuis Python Build Standalone.
Son URL et son empreinte SHA-256 sont fixées dans la recette de construction.

Les composants et les ressources Riot sont préparés sur la machine de chaque
utilisateur à partir de son installation ou des services Riot.

## Tests

```sh
python3 -m unittest discover -s tests -v
```

La validation réalisée couvre une installation complète dans un dossier vide,
l’ouverture réelle du jeu sur un compte EUW1, le déplacement de l’application et
l’extraction de son archive. Les publications des 15 régions live annoncées par
Riot ont été vérifiées. Les parties dans les autres régions restent à tester.

## Licence et composants tiers

Le code original du lanceur est proposé sous licence MIT. Les composants tiers
conservent leurs droits et leurs licences. Consulter `LICENSE` et
`THIRD_PARTY_NOTICES.md` pour le périmètre et les notices.
