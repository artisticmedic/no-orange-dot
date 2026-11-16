# Changelog

## 0.1.2 — pending public release

- Choose which microphones belong in the priority list and reorder them in Settings → Microphone priority. Included microphones take priority; other available microphones provide fallback when none are connected.
- New microphones stay outside the priority list until included. Unplugged microphones keep their place and saved sound. Choosing a microphone manually leaves the list unchanged.
- Connecting or disconnecting an excluded microphone keeps the current recording and audio engine running when the selected microphone remains available.
- Control membership with `nod mics include <name>` and `nod mics exclude <name>`, or order with `nod mics move <name> <place>`.
- Add full app menus and a larger Mute button in the sidebar.
- Choose shortcuts in Settings for menu commands. Mute and recording shortcuts can work in other apps.
- **Shortcut change:** there are no built-in mute or recording shortcuts. Existing explicitly saved shortcuts are preserved. If your settings never stored the old defaults, set Control–Option–Command–M and Control–Option–Command–R again if you want to keep using them.

The source is versioned as 0.1.2. The public installer and update feed remain on 0.1.1 until the [release checks](docs/release-checklist.md) are complete.

## 0.1.1

- Recover the audio engine after Core Audio restarts during installation.
- Reduce processor use with the editor open.
