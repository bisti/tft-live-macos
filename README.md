# TFT Live macOS

TFT launcher for macOS Apple Silicon.

An independent project, unaffiliated with Riot Games.

**[Download the latest release](https://github.com/bisti/tft-live-macos/releases/latest)**

## Requirements

- Apple Silicon Mac running macOS 14 or later.
- Official Riot Client installed.
- Riot account to sign in to the client.
- Space for the game and its updates. The initial download may exceed 10 GB.

## Installation

1. Download `TFT-Live-AppleSilicon.zip` from the releases page.
2. Extract the archive and move `TFT Live.app` to Applications.
3. Open the application and sign in to Riot.
4. Wait for game preparation to finish, then click **Play** in Riot.

The launcher detects your account server, checks its live release, and installs or
updates the TFT Mac client. The required Python runtime is bundled with the application.

The application is ad-hoc signed and has no Apple notarization. macOS may ask
you to allow it when opening it for the first time.

## How it works

The launcher prepares a private copy of components from the installed Riot Client
and adapts their platform identification to Windows. The game runs as a native
Mac client. The components are prepared for ARM64.

The region is obtained from the signed-in account. The manifest is selected from
the published Mac and Windows releases for the corresponding live channel, with
a version consistency check. The Riot patcher handles downloads.

New Riot runtime versions are staged separately and validated before activation.
Failed validation triggers a rollback to the previous version. Compatibility
depends on changes to Riot components and services.

## Local data

Settings, sign-in data, and logs are stored in
`~/Library/Application Support/TFT Live` for the current macOS user.

An existing writable TFT installation can be reused. A new installation uses
`~/Applications/Teamfight Tactics (Live).app`.

The main log is `~/Library/Application Support/TFT Live/launcher.log`.
When reporting an issue, redact account information and any tokens before
sharing logs.

## Building from source

Building requires Python 3.9 or later and Apple developer tools to compile
the two small ARM64 executables.

```sh
python3 build_arm64_host.py
python3 app/build.py
```

The output includes `dist/TFT Live.app`, `dist/TFT-Live-AppleSilicon.zip`, and its
SHA-256 checksum. A local copy of the application is also created at the project root.

The portable Python runtime is downloaded from Python Build Standalone.
Its URL and SHA-256 checksum are pinned in the build script.

Riot components and resources are prepared on each user's machine from their
installation or from Riot services.

## Tests

```sh
python3 -m unittest discover -s tests -v
```

Validation covers a complete installation into an empty directory, an actual
game launch on an EUW1 account, relocating the application, and extracting its
archive. Published releases for all 15 live regions advertised by Riot have
been checked. Matches in other regions still need testing.

## License and third-party components

The original launcher code is available under the MIT license. Third-party
components retain their respective rights and licenses. See `LICENSE` and
`THIRD_PARTY_NOTICES.md` for scope and notices.
