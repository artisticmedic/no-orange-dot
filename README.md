# Tim's Amazing No Orange Dot Microphone EQ

A menu bar app for macOS that gives your microphone an EQ, a noise gate and a compressor, and
opens the microphone only while something is using it.

Most microphone software keeps the mic open the whole time it runs, so the orange dot in the menu
bar never goes away. This one stays closed until an app starts listening, opens within about a
tenth of a second, and closes again when the app stops.

## How it works

Two parts:

- **No Orange Dot Mic**, a virtual input device. Apps select it in place of the real microphone.
- **The menu bar app**, which watches that device. When an app starts reading from it, the app
  opens your real microphone, processes the sound and feeds it to the virtual device. When the
  last app stops, it closes the microphone.

The orange dot still appears while an app is using the mic. It goes away when they stop.

## Features

- Parametric EQ with up to 8 bands and a draggable curve, with undo and a history of earlier curves
- Simple tone sliders in plain words (Rumble, Weight, Body, Box, Words, Edge) that move the EQ bands for you
- Noise gate, compressor, a de-esser that softens sharp S sounds, and a limiter that catches peaks before they clip
- Mute, which closes the real microphone
- Record to a WAV file in `~/Music/No Orange Dot/`
- Presets: save whole sounds in a list, loop one recording, and click down the list to hear each on the same words
- Listen back: hear the processed mic in your headphones
- Keyboard shortcuts you choose: none are built in. Mute and record can work in any app, and every menu command can have one
- The microphone's own preamp gain, with a lock that stops other apps changing it, on hardware that allows it
- A separate saved sound for each microphone
- A live view of your voice behind the EQ curve, shaded where the EQ adds and takes away
- Recordings keep a raw take, so you can replay one through the EQ and change the curve while it loops
- Matching: fit an EQ that makes one microphone sound like a recording of another
- A name of your choice for the microphone apps see
- Mono and stereo microphones at 44.1, 48, 88.2 and 96 kHz
- Start at login

## Control it from scripts or an agent

Everything the windows can do is also available from the command line and from a settings file.

- `config.json` in `~/Library/Application Support/NoOrangeDot/` holds every setting. The app
  re-reads it within half a second of any edit.
- `status.json` in the same folder says what the app is doing: whether the mic is open, whether
  an app is listening, and the last recording.
- `nod` is the command-line tool. Install it from Settings › Automation, which links
  `/usr/local/bin/nod` to the app's own binary. Run `nod help` for the full list:

```sh
nod status
nod mute toggle
nod band set 3 freq=450 gain=-2.5
nod comp on threshold=-18 ratio=3
nod deess on amount=6
nod limiter on ceiling=-1
nod record toggle
nod shortcut mute ctrl+opt+cmd+m
nod history restore 1
```

Settings → Microphone priority lets you include or exclude each microphone and move included ones up or down. Included microphones take priority, in your chosen order. New microphones stay excluded until you include them, and unplugged microphones keep their place. If no included mic is connected, the app keeps the current microphone if available, or automatically picks another. You can still choose any connected microphone manually. A manual choice lasts until it disconnects, an included microphone reconnects, you edit the priority list, or the app restarts. Choosing a mic never changes the list. The Microphone → Microphone Priority… menu opens these controls.

`nod mics` lists included and other known microphones. `nod mics include <name>`, `nod mics exclude <name>`, and `nod mics move <name> <place>` change membership and order. Excluding a microphone keeps its saved EQ and settings.

## Requirements

macOS 14 or later.

## Build from source

Needs Xcode.

```sh
git clone --recurse-submodules <repo-url>
cd no-orange-dot
./scripts/build-driver.sh
./scripts/build-app.sh
./scripts/install-driver.sh   # asks for your password, restarts Core Audio
open "build/Tim's Amazing No Orange Dot Microphone EQ.app"
```

`./scripts/build-installer.sh` builds one installer package with the app and the driver. It needs
Developer ID certificates; add `--unsigned` to build without them, or `--notarize` to send the
signed package to Apple.

The driver is BlackHole with one change, kept in `patches/renameable-device.patch` and applied by
the build script: the visible device can be renamed while it runs.

Then pick **No Orange Dot Mic** as the input in your apps or in System Settings › Sound.

To remove the app, the driver and `nod`, run `./scripts/uninstall.sh`. Settings stay unless you add
`--settings`.

## Updates

The app looks for a new version once a day, and on request in Settings › Updates or with `nod update`.
It reads one small JSON file from the update address and sends nothing else:

```json
{ "version": "0.2.0", "url": "https://…/No Orange Dot 0.2.0.pkg", "notes": "…", "minimumSystem": "14.0" }
```

`nod update install` or the Install button downloads the package and opens it in Installer only if
Gatekeeper accepts it as notarized and it was signed by the same Developer ID team as the running
app. The app restarts itself when the installer finishes. `scripts/make-feed.sh` writes the JSON for
a release. `nod update feed <https address>` points a copy of the app at another feed.

## Tests

```sh
./scripts/test.sh       # the audio chain, the settings model and the CLI
./scripts/vm-check.sh   # installs the package in a clean macOS guest; needs the vm tool
```

The CLI tests run against a throwaway folder named by `NOD_HOME`, so they never touch your settings.

## Delay and processor use

```sh
swift scripts/measure-latency.swift   # plays five short sounds and records both microphones
```

Measured on an Apple silicon MacBook Pro with its built-in microphone at 48 kHz: the virtual mic hears
a sound about 20 ms after the real one. The app uses about 0.2% of one core while the mic is closed and
4 to 8% while an app is using the mic with the editor window open.

## Credits and license

The virtual audio driver is built from [BlackHole](https://github.com/ExistentialAudio/BlackHole)
by Existential Audio, used under the GPL-3.0.

This project is licensed under the GNU General Public License v3.0. See `LICENSE`.
