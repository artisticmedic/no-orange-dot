# No Orange Dot release checklist

Status: 17 November 2026. Source version 0.1.2; public installer/feed still 0.1.1. The full suite ran 123 tests: 122 passed, one skipped because a notarized 0.1.2 package is not built. The voice check has light/dark previews and synthesis-only reference verification (−20 dBFS active average). Live hardware and upgrade checks below remain separate from this automated coverage.

## Fix before publishing an installer

- [x] Finalize the active take before Quit and wait for previously queued recording closes. Claude reported live mid-take and stop/quit smoke tests passing. A semaphore-gated regression now proves that an already-stopped take blocks shutdown until both WAVs close and reopen with all submitted frames.
- [x] Check exact file revisions when saving, preserve newer disk edits and malformed files, serialize app/CLI writes, and report read/write failures. Eleven persistence/CLI regressions pass. Hand editors do not participate in the app/CLI lock.
- [x] Check recording creation/setup/write/close errors and suppress Saved on failure; synchronize recording handle handoff with the callback. Injected failures, muted stereo content, and two-mono-buffer input layouts are covered without microphone capture.
- [x] Restart listen-back with the producer's rate; clear stopped input buffers and output silence on underflow. Reader behavior is tested; audible rate switching still needs hardware checks.
- [x] Fix zero-hold gate attenuation, reject unsafe dynamics from CLI/config, and reject empty/extreme indices without crashing. Exact preset names take precedence over numeric positions.
- [x] Give EQ Undo/Redo per-mic traversal, keep pending edits through switches/quit, prevent clear-history resurrection, and preserve newer/malformed history files. External same-mic EQ edits are undoable; text-field Undo stays with the text editor.
- [x] Use one shortcut capture owner, suspend global actions while capturing, and release both old global bindings before registering replacements. Mock tests cover capture transfer and swaps; actual Carbon/non-US keyboard behavior remains a manual check.
- [x] Leave the updater available for retry/recheck after handing off to Installer, including cancellation or failure.
- [x] Stop the driver build on xcodebuild failure. Fixture tests prove stale output is not signed after failure and an empty filtered log does not turn success into failure.

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

The older deep review also noted command-targeting/acknowledgement gaps: NOD_HOME does not isolate distributed commands, and status.json alone is not proof a command was received. Integration tests must avoid sending commands to the real app from scratch fixtures. Meter/ring publication still uses the existing shared-memory design; stress testing remains open.

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
