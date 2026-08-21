# The Siri Remote

Read this before changing anything under `Talkify/RemoteInput/`.

The remote is not one device to the Mac. It is three, reached three
different ways, and confusing them is the single most expensive mistake
available here — every one of them fails identically from the outside, as a
remote that does nothing.

| What | How it arrives | Where |
|---|---|---|
| Buttons | IOKit HID, public API | `SiriRemoteButtonMonitor` |
| Clickpad | `MultitouchSupport`, **private** | `SiriRemoteTouchpad` |
| Microphone | a root daemon decoding Bluetooth | `Voice/` and `helper/` |

## Adding a command

Spoken commands live in `Talkify/RemoteInput/Commands/`. Adding one is
usually a single line, and always a test.

**A fixed phrase.** Add to `RemoteCommandParser.phrases` in
`RemoteCommand.swift`:

```swift
("select all", .press(.command("a"))),
```

The table is matched longest phrase first, so `close this window` is found
before `close`. Use `.command`, `.commandShift`, `.modified` or `.plain` —
they take virtual key codes, which are *positions* on the keyboard, so ⌘C
still copies on a French layout.

**A phrase with a value in it**, like "tab two". These do not belong in the
table: write a small function beside `numberedTab(in:)` and call it from
`command(from:)` *before* the verb matching, because "go to tab two" starts
with a switching verb and would otherwise be read as an application called
"tab two". Spoken numbers are in the `numbers` table; a transcript says
"two" as often as "2".

**A window arrangement.** Add a case to `WindowArrangement`, its phrases,
its title, and its rectangle. `everyArrangementHasAPhrase` and
`nothingLandsOffScreen` will hold you to both.

**Something that is not a keystroke.** Add a case to `RemoteCommand`, give
it a `confirmation`, and handle it in `RemoteCommandRunner.run`.

Then add a test to `RemoteCommandTests`. The parser is pure, so a command
can be proven without a microphone or a remote in the room.

### What will not work, and why

**The window server ignores synthesised shortcuts.** Mission Control,
Spotlight, Show Desktop, screenshots and the rest of macOS's own shortcuts
do nothing when posted as key events, however faithfully the modifiers are
assembled — and they *are* assembled faithfully: each modifier goes down as
its own key event, paced, carrying the flags a real keyboard reports.
Ordinary application shortcuts work fine through the same code, which is
why ⌘W does and ⌃↑ does not.

Where a system app performs the action, open that instead — this is what
`RemoteWindowAction` does for Mission Control. Where there is none, the
command cannot be supported. Do not add it and hope: an option that
silently does nothing is worse than an absent one, which is why Application
Windows, Show Desktop and Spotlight were removed.

**Nothing destructive.** There is deliberately no "close everything".
Anything that throws away work the user cannot recover must not be one
mis-hearing away.

## The gesture

The Siri button does two jobs, decided in `RemoteCommandGesture`:

- **Hold** — dictate. Text goes into whatever was focused.
- **Tap, then hold** — speak a command. Two presses, the second held. The
  same gesture a trackpad uses for drag.

The second hold is not a style choice. **The remote's microphone only
transmits while the button is physically down** — the packet capture shows
audio starting when handle `0x0039` reports pressed and stopping on
release. Any design where the user speaks with the button up records
silence.

A remote session finishes on release rather than going through the session
machine's release rules, which latch a press shorter than 250 ms. That is
right for a key and wrong for a hold the gesture has already recognised.

## The microphone

macOS receives the remote's audio and does not expose it to any app. The
service is hidden from CoreBluetooth, the remote does not advertise while
paired, and no audio arrives on any HID interface. The only route is to
read the Bluetooth link, which needs root, which is why there is a daemon.

`talkify-remote-voiced` ships inside the app bundle and is installed by the
app itself through `SMAppService`. Two things about that are not obvious
and cost an evening each:

- **A development-signed app cannot install a daemon.** `SMAppService`
  fails with `Operation not permitted` and reports the helper as *missing
  from the bundle* beforehand, which sends you looking in the wrong place
  entirely. Sign with Developer ID.
- **launchd will not install a daemon from DerivedData.** The app has to be
  in `/Applications`, which is what `scripts/dev-build.sh` does.

The protocol is decoded in `Voice/SiriRemoteVoiceFrame.swift` and pinned by
tests against bytes from a real capture. Audio is on ATT handle `0x0035`,
the microphone button on `0x0039`. A notification does not fit one ACL
fragment, so reassembly is not optional.

libopus comes from Homebrew and is resolved at runtime. No libopus, no
dictation from the remote.

## Starting up

Both halves start on their own, and both are needed:

- The daemon is `RunAtLoad` and `KeepAlive`, so it starts at boot and comes
  back if it crashes.
- The app registers itself as a login item through `SMAppService.mainApp`,
  controlled by the **Start at login** setting.

A daemon without the app is not a working remote: the app is what reads the
buttons, moves the pointer and runs the commands. macOS may ask the user to
approve either of them under Login Items & Extensions the first time.

## When it stops working

```sh
../siri-remote-mic-spike/remote-doctor.sh
```

Checks all five links and names the broken one. Run it *first*: three times
in one evening the answer was "the app is not running".

To watch a press travel through the app:

```sh
/usr/bin/log stream --level debug \
  --predicate 'subsystem == "digital.chaotic.RemoteInput"'
```

Each press should produce a button line, a routing line, and an action
line. Whichever is missing names the layer at fault.

**Only one app may hold the buttons.** BetterTouchTool and the GoatRemote
app both seize the button interface, and while either holds it every other
app sees nothing. `opencheck` in the spike folder says whether it is free.

## Known gaps

- No multi-display command: "move to the other screen" is unimplemented.
- No "type this" command to dictate into a field from command mode.
- `RemoteCursor` and `RemoteVoiceInput` have no tests. Their pure parts —
  `RingScroll`, `WindowArrangement`, the parser, the gesture — do.
- The helper has no uninstall path in the UI.
