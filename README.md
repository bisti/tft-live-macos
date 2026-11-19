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

Sign in and follow game updates in Riot Client. TFT Live shows its own window
for Riot component updates or setup errors. Closing that window lets setup
continue in the background. Choosing Quit during preparation lets setup and
logging finish before the launcher exits.

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

The private components are named `Riot Runtime.app`. Signed UI files are shared
using hard links within each runtime. The active runtime and its previous version are retained. Older prepared
versions, including the initial runtime once superseded, are removed automatically.

A new runtime is confirmed after account-region checks and successful preparation
of the TFT installation. Setup failures restore the previous runtime and retry
preparation. A temporary download, disk or sign-in failure allows another attempt
on the next launch. A confirmed binary incompatibility defers that specific
manifest for 24 hours. Cached components are checked for changes at startup.
Damaged bundles are rebuilt while preserving the user's settings and sign-in data.

## Local data

Settings, sign-in data, and logs are stored in
`~/Library/Application Support/TFT Live` for the current macOS user.

The launcher updates its configuration templates when a profile is reopened.
It keeps local changes when merging new defaults. If a local edit conflicts
with a Riot system YAML update, the launcher reports the conflict and keeps
the local file. When recording a template for the first time, it preserves
settings whose origin it cannot identify. The launcher still manages the
active patch URL, region and shared Mac launch configuration for all three
platform aliases.

An existing writable TFT installation can be reused. A new installation uses
`~/Applications/Teamfight Tactics (Live).app`.

The graphical launcher writes its output to `~/Library/Application Support/TFT Live/launcher.log`.
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
SHA-256 checksum. SwiftPM keeps its compilation cache in `.build/`.

The interface, command-line launcher, SDK host, configuration, runtime updates,
repair, logging, and ARM64 component adaptation are implemented in Swift.
The application uses the Swift libraries provided by macOS.

Open `dist/TFT Live.app` to launch the local build. To see preparation output in a terminal,
run `"./dist/TFT Live.app/Contents/MacOS/TFTLiveCLI"`.

Riot components and resources are prepared on each user's machine from their
installation or from Riot services.

## Tests

```sh
./test.sh
```

The Swift Testing suite covers regional configuration, published release matching,
ARM64 SDK adaptation, preparation checks, rollback, transactional replacement,
log rotation, and runtime metadata. The test script locates the testing
framework supplied by Xcode or the Apple command-line tools.

The optional integration tests use the application built in `dist/`. They check
console output from a surviving child process, prepare installed Riot components,
remove and repair the SDK and UI, start a headless Swift host, and download
a current Riot runtime. They require network access and temporary disk space.

```sh
TFT_NATIVE_INTEGRATION=1 ./test.sh --filter IntegrationTests
```

The integration suite checks the NA1 release using Riot services. Testing the Play
button and game startup requires a separate run with a signed-in account.

## License and third-party components

The original launcher code is available under the MIT license. Third-party
components retain their respective rights and licenses. See `LICENSE` and
`THIRD_PARTY_NOTICES.md` for scope and notices.
