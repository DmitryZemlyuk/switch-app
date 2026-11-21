# Switch

A tiny macOS menu bar app for turning Aqara smart plugs on and off – locally, without the Aqara cloud.

Click the plug icon in the menu bar and you get one tile per plug: tap a tile to toggle it. Plugs can be renamed and shown as a plug or a light. Right-click the icon for the app menu (open at login, language, log, unpair, quit).

## How it works

- The Aqara Hub M1S Gen 2 exposes its Zigbee devices as a **Matter bridge** on the local network.
- Switch pairs with the hub as an additional Matter controller (Aqara Home and other controllers keep working) and talks to it directly over the LAN: discovery via mDNS, commands and live state updates over IPv6/UDP.
- The Matter stack is [matter.js](https://github.com/project-chip/matter.js), running in a small helper process on the Node.js already installed on the Mac, which the SwiftUI app talks to over JSON lines on stdin/stdout.

Works only on the home network – there is no remote access by design.

## Requirements

- macOS 13 or newer, Apple silicon
- Node.js 22.13 or newer (Homebrew, nodejs.org installer, nvm, fnm, Volta and similar are found automatically)
- An Aqara hub with Matter bridging (Hub M1S Gen 2, M2, M3, E1) on the same network as the Mac
- IPv6 enabled on the LAN (link-local is enough)

## Setup

1. Download the latest `Switch-x.y.z-macos-arm64.zip` from Releases, unpack it and move `Switch.app` to Applications.
2. The app is ad-hoc signed, not notarized, so clear the quarantine flag once: `xattr -dr com.apple.quarantine /Applications/Switch.app` (or allow it in System Settings → Privacy & Security → Open Anyway). Then open it and allow local network access.
3. In Aqara Home, open the hub → Matter → add to another ecosystem, copy the 11-digit pairing code and enter it in Switch.

## Languages

Ukrainian, Russian and English – follows the system language or can be picked from the menu.

## Building

`scripts/build-app.sh` builds everything on macOS: the helper bundle (`helper/`, esbuild), the Swift app (`app/`, SwiftPM) and assembles `dist/Switch.app` plus a zip. GitHub Actions runs it on every push to `main` and publishes a release for the version in `VERSION` (only the three newest releases are kept).

Helper unit tests: `cd helper && npm ci && npm test`.

## Troubleshooting

Right-click the menu bar icon → Show Log opens `~/Library/Logs/Switch/helper.log` with the Matter helper output. Pairing data lives in `~/Library/Application Support/Switch/matter`.
