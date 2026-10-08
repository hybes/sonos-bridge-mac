# Sonos Bridge for Mac

A small menu bar app that puts Sonos playback into macOS Now Playing and [Vorssaint](https://github.com/vorssaint/vorssaint-utils). It connects directly to your speakers, so Sonos Web can be closed.

## Install

Requires **Apple Silicon and macOS 14 or later**.

1. Download the app ZIP from [Releases](https://github.com/hybes/sonos-bridge-mac/releases/latest).
2. Unzip it and move **Sonos Bridge.app** into Applications.
3. Open it and allow local network access if macOS asks.
4. Click the speaker icon in the menu bar and choose your room.

There is no main window or Dock icon. Enable **Open at Login** from the menu if you want it to start automatically. Quitting the bridge leaves your speakers playing.

## What works

- Track title, artist, album, artwork and timeline in Now Playing and Vorssaint.
- Play/pause and the track controls your speaker advertises.
- Remembered room selection and automatic reconnection.
- Manual connection using a speaker IP address when discovery fails.

Transport commands go to the group's coordinator, including when you select another room in that group. The bridge follows the room selected in its own menu. Updates normally arrive within two seconds during playback.

Queue publishing is not supported. Seeking is available only when the speaker advertises it. Vorssaint's volume control adjusts the Mac's output, rather than speaker volume.

## Privacy

No Sonos cloud login, extra server or telemetry. Discovery and speaker control use the local network. HTTPS artwork URLs supplied by a speaker may be fetched from their original service.

## Build

Install Xcode Command Line Tools, then run:

```sh
bash build.sh
```

This runs the model tests and creates a locally signed app and ZIP in `dist/`. No package dependencies are required.

For a Developer ID signed and notarised release, configure your own signing identity and a stored `notarytool` keychain profile:

```sh
export SONOS_BRIDGE_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export SONOS_BRIDGE_NOTARY_PROFILE='your-notary-profile'
bash build.sh release
```

Release builds verify the signature, submit the app to Apple, staple the notarisation ticket and generate `SHA256SUMS`. Local builds are not notarised.

## Validation

42 model checks cover XML handling, invalid responses and addresses, metadata, capabilities and grouped-room routing. Live playback metadata, artwork and play/pause were verified through Vorssaint with Sonos Web closed. Login after a restart, sleep/wake and multiple physical speakers still need live testing.

This is an independent utility, unaffiliated with Sonos or Vorssaint.
