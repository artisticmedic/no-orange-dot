# No Orange Dot release checklist

Status: 16 November 2026. Source version 0.1.2; public installer/feed still 0.1.1. The priority feature and voice check passed 76 automated tests (one existing installer test skipped). The voice check has light/dark previews and a synthesis-only reference verification: 6.57 seconds, −20 dBFS active average, −6.73 dBFS peak. Audible A/B and hardware behavior still need hands-on checks. Those checks do not replace hardware and upgrade testing.

## Fix before publishing an installer

- [x] Finalize the active take before Quit and wait for previously queued recording closes. Claude verified quitting mid-take; stop-then-immediate-quit with an active client still needs the live check below.
- [x] Check exact file revisions when saving, preserve newer disk edits and malformed files, serialize app/CLI writes, and report read/write failures. Eleven persistence/CLI regressions pass. Hand editors do not participate in the app/CLI lock.
- [ ] Triage the remaining confirmed review findings: zero-hold gate attenuation, recording write errors, listen-back rate changes, undo/history behavior, shortcut capture/registration, and invalid CLI bounds.
- [ ] Make driver builds fail when xcodebuild fails. The current `build-driver.sh` pipeline can continue and package a stale driver.

## Hands-on checks

Use the single app in /Applications. Keep the person's current audio settings backed up and restore test changes. Perform disruptive install/Core Audio checks in a disposable macOS guest.

- [ ] Idle → call → idle: microphone opens on demand, closes after the last client, and accurately reports who is using it. Try Hex and a real call app.
- [ ] Priority: include/exclude/reorder, restart persistence, unplug/replug preferred and fallback devices, and an empty priority list. Check that excluded-device arrival does not stop a take or interrupt the active source.
- [ ] Manual input choice stays separate from priority. A preferred mic reconnecting resumes automatic priority; absent preferred mics retain the current connected fallback.
- [ ] Audio: gate/compressor/limiter, headphones, changing 44.1/48/96 kHz inputs, sleep/wake, and an app continuing to use the virtual mic through a device switch.
- [ ] Mute: check call output, recording, and monitoring separately. State the intended behavior in the UI/help; do not assume all three paths are identical.
- [ ] Record: repeated short takes, stop-then-immediate-quit while a client keeps the engine running, pause/resume, playback and raw comparison, folder failures, and deletion/recovery.
- [ ] Voice check: play the reference and a real take at the same system volume; test quiet/loud speech, mute/close stopping the live check, recording selection during playback, and a Mac without the reference voice installed. The guide uses average signal level in dBFS, not LUFS or calibrated room loudness.
- [ ] Keyboard/accessibility: actual custom shortcuts, global mute/record, standard text shortcuts, switching between shortcut recorders, VoiceOver, and a non-US keyboard layout.
- [ ] Clean install and 0.1.1 → 0.1.2 upgrade in a guest, preserving settings and driver availability. Test cancelled/failed installation and the updater retry path.

## Package and distribute

- [ ] Build a fresh signed installer and notarize it: `./scripts/build-installer.sh --notarize`. The default command signs but does not notarize.
- [ ] Verify Gatekeeper acceptance, package contents, supported macOS versions and both architectures. The current app binary targets macOS 14 on arm64 and x86_64; hardware coverage remains incomplete.
- [ ] Complete the outstanding notary credential maintenance before using the `onair` Keychain profile for distribution. Do not put credentials in source or release notes.
- [ ] After validation, tag the release and publish the installer with the changelog and checksum.
- [ ] Generate the feed with `scripts/make-feed.sh`, update the separate updates repository, and test that an older copy discovers the release and opens the accepted installer.

No tag, installer publication, or feed update is implied by committing the source version.

## Landing page and first use

Planned location: `https://timgailey.com/apps/no-orange-dot`. No No Orange Dot page exists in the local site worktree yet. The existing apps directory also contains another lane's React Grab work; preserve it.

A first page needs:

- A plain explanation of microphone EQ with on-demand microphone access, plus a real screenshot or short demonstration.
- A prominent versioned macOS download, macOS requirements, Apple silicon/Intel support, and a link to release notes.
- Three setup steps: install app/driver, choose the real microphone and preferences, then select No Orange Dot Mic in the call/recording app.
- A privacy explanation: processing stays local; the system's orange indicator still appears while audio is actually captured. Explain what update checks request and how optional crash reporting works.
- Short troubleshooting, uninstall instructions, and links to GitHub/support and source/license information.

Inside the app, add a first-run path for microphone permission, missing driver, real-input choice, and selecting the virtual mic in other apps. A successful install should lead to working audio without requiring the README or an agent.
