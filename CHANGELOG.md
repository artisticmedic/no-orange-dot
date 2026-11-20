# Changelog

## 0.1.2 — pending public release

- Shape your sound in plain words with the Simple card on the Sound page: Rumble, Weight, Body, Box, Words and Edge. Each slider moves the EQ band that covers its range, or adds one, so presets and the Equalizer stay in step. From a script: `nod tone weight 2`.
- Add a de-esser that softens sharp S sounds. It turns down only the highs above a frequency you choose, only while an S is sounding. Turn it on from the Sound page, the Sound menu or `nod deess on`.
- Compare your voice with a fixed-level spoken reference on the Sound page. Check the live processed signal or a recording against a speaking range, with separate peak warnings and an output-level control.
- Hear myself, Record and Mute are keys in the sidebar, styled like the Mute key. While recording, Record becomes Stop with the time so far, beside Pause. A saved confirmation follows in the toolbar.
- The window is a standard Mac split view: the system places the window buttons, the sidebar and the toolbar, and the toolbar shows the page's name. On a wide window the Sound page uses two columns: Equalizer, Tone and Dynamics on the left; Voice level and Presets on the right. A narrow window stacks them. Text and controls are larger, and lines that explained what the screen already shows are gone; their explanations are in tooltips. Presets are a list of names, with the one in use lit and an Edited mark after changes. The Equalizer's starting curves and earlier curves share one menu. Each dynamics row opens its settings without turning it on, and shows how much it is working while the mic is open.
- Use as the Mac's microphone is now saved and holds. When AirPods or another device take over the Mac's input as they connect, No Orange Dot switches it back and says so. Choosing another input in System Settings or Control Center turns the setting off.
- Voice level says when an app such as Hex reads the real microphone directly, so nothing reaches No Orange Dot to measure, and how to change it.
- The Equalizer switch now turns off only the EQ bands. The gate, compressor, de-esser and limiter stay as they are. To hear the mic or a take with everything off, use Sound › Hear Without Processing or Original in the player; the top bar shows Processing off while it is on.
- Output level lives in Voice level only.
- One player for recordings, pinned under the Sound and Recordings pages. Pause, click the waveform to move the playhead, drag the playhead to scrub, and drag across the waveform to select a part. Loop repeats the selection, or the whole take without one. Save as New Recording keeps the selection as its own take, raw audio included, and leaves the original alone. With the player focused: Space plays or pauses, arrow keys move a second (five with Shift), I and O set the selection's ends, L loops, Escape clears.
- Takes saved without raw audio play in the same player, as saved. The separate compare controls in Voice level and Presets, the playing bar above the page and the playing chip in the top bar are gone.
- The player is one row: play, the take, the waveform, the time, Original and Loop.
- Recordings are grouped by day, with the time and length of each. Show in Finder and Move to Trash appear on hover and on right-click. A folder menu at the top switches between the default folder, folders used before and a new one, and shows the folder in Finder.
- The Voice level card says what it is measuring: your mic, a recording, the reference voice, or Mic off, with Check My Voice beside it.
- Starting a recording stops any playback and the reference voice, and says so. Playback waits until the recording stops. Hear myself (formerly Listen) can stay on while recording, and the recording bar shows it.
- The whole Stop button in the recording bar responds to clicks, not just its icon and label, and it highlights on hover.
- Finish pending recording-file writes before quitting, and give rapid successive takes unique filenames.
- Keep newer CLI or hand-edited settings when a GUI save is pending. Report failed saves instead of silently discarding them.
- Report recording setup/write/close failures, and keep file handles alive until their audio callback finishes. Restart headphone monitoring when input rates change and output silence when input stops.
- Undo and redo EQ edits in order, with separate history for each microphone. Keep the last edit when quitting; clearing history stays cleared.
- Use one shortcut recorder at a time and safely swap global shortcuts. Text editing keeps its own Undo/Redo and Control shortcuts.
- Fix the noise gate at zero hold, reject unsafe dynamics and invalid CLI indices, and correctly address presets with numeric names.
- Allow update installation to be retried after cancellation. Stop packaging when the driver fails to compile.
- Choose which microphones belong in the priority list and reorder them in Settings → Microphone priority. Included microphones take priority; other available microphones provide fallback when none are connected.
- New microphones stay outside the priority list until included. Unplugged microphones keep their place and saved sound. Choosing a microphone manually leaves the list unchanged.
- Other microphones lists only microphones that are connected now. The temporary "CADefaultDeviceAggregate" devices macOS creates while the app plays audio no longer appear or get saved.
- Connecting or disconnecting an excluded microphone keeps the current recording and audio engine running when the selected microphone remains available.
- Control membership with `nod mics include <name>` and `nod mics exclude <name>`, or order with `nod mics move <name> <place>`.
- Add full app menus and a larger Mute button in the sidebar.
- Choose shortcuts in Settings for menu commands. Mute and recording shortcuts can work in other apps.
- **Shortcut change:** there are no built-in mute or recording shortcuts. Existing explicitly saved shortcuts are preserved. If your settings never stored the old defaults, set Control–Option–Command–M and Control–Option–Command–R again if you want to keep using them.

The source is versioned as 0.1.2. The public installer and update feed remain on 0.1.1 until the [release checks](docs/release-checklist.md) are complete.

## 0.1.1

- Recover the audio engine after Core Audio restarts during installation.
- Reduce processor use with the editor open.
