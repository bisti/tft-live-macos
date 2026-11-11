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
updates the TFT Mac client. The application and its host are native Swift executables.

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

The private components are named `Riot Runtime.app`. Existing installations are
migrated automatically. Signed UI files are shared using hard links within each
runtime. The active runtime and its previous version are retained. Older prepared
versions, including the bootstrap once superseded, are removed automatically.

A new runtime is confirmed after account-region checks and successful preparation
of the TFT installation. Setup failures restore the previous runtime and retry
preparation. Cached components are checked for changes at startup. Damaged bundles
are rebuilt while preserving the user's settings and sign-in data.

## Local data

Settings, sign-in data, and logs are stored in
`~/Library/Application Support/TFT Live` for the current macOS user.

An existing writable TFT installation can be reused. A new installation uses
`~/Applications/Teamfight Tactics (Live).app`.

The main log is `~/Library/Application Support/TFT Live/launcher.log`.
Launcher and host console logs use 10 MiB files with three rotated archives.
Before a new Riot host starts, its session logs are reduced to the three newest
files per log folder, with older retained files trimmed to 10 MiB.
When reporting an issue, redact account information and any tokens before
sharing logs.

## Building from source

Building requires Swift 6 or later and Apple developer tools on an Apple Silicon Mac.

```sh
./build.sh
```

The output includes `dist/TFT Live.app`, `dist/TFT-Live-AppleSilicon.zip`, and its
SHA-256 checksum. A local copy of the application is also created at the project root.

The interface, command-line launcher, SDK host, configuration, runtime updates,
repair, logging, and ARM64 component adaptation are implemented in Swift.
The application uses the Swift libraries provided by macOS.

The former Python launch and build commands remain as small compatibility wrappers
that forward to the native executables or the shell build script.

To launch from a terminal, use `./launch-tft-live.sh`. To see preparation output
directly, run `./TFT\ Live.app/Contents/MacOS/TFTLiveCLI`.

Riot components and resources are prepared on each user's machine from their
installation or from Riot services.

## Tests

```sh
./test.sh
```

The Swift Testing suite covers regional configuration, published release matching,
ARM64 SDK adaptation, preparation checks, rollback, transactional replacement,
log rotation, and legacy state compatibility. The test script locates the testing
framework supplied by Xcode or the Apple command-line tools.

The optional integration test prepares components from the installed Riot Client,
removes and repairs the SDK and UI, starts a headless Swift host, and downloads
a current Riot runtime. It requires network access and temporary disk space.

```sh
TFT_NATIVE_INTEGRATION=1 ./test.sh --filter IntegrationTests
```

An actual game launch and matches were previously verified on EUW1. Published
release metadata for all 15 live regions advertised by Riot was checked during
earlier validation. Matches in other regions still need testing.

## License and third-party components

The original launcher code is available under the MIT license. Third-party
components retain their respective rights and licenses. See `LICENSE` and
`THIRD_PARTY_NOTICES.md` for scope and notices.
