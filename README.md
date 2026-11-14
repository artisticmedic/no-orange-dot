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

- Parametric EQ with up to 8 bands and a draggable curve
- Noise gate and compressor
- Mute, which closes the real microphone
- Record to a WAV file in `~/Music/No Orange Dot/`
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
- The app's own binary is the command-line tool. Run it with `help` for the full list:

```sh
NoOrangeDot status
NoOrangeDot mute toggle
NoOrangeDot band set 3 freq=450 gain=-2.5
NoOrangeDot comp on threshold=-18 ratio=3
NoOrangeDot record start
```

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

To remove everything, run `./scripts/uninstall.sh`.

## Credits and license

The virtual audio driver is built from [BlackHole](https://github.com/ExistentialAudio/BlackHole)
by Existential Audio, used under the GPL-3.0.

This project is licensed under the GNU General Public License v3.0. See `LICENSE`.
