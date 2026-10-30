# RC8650 for macOS

The RC8650 as a system speech synthesizer: eight voices offered to
`AVSpeechSynthesizer` — and so to Spoken Content, Speak Selection and every app
that speaks — under the names **RC8650 Perfect Paul**, **RC8650 Vader**,
**RC8650 Big Bob**, **RC8650 Precise Pete**, **RC8650 Ricochet Randy**,
**RC8650 Biff**, **RC8650 Skip** and **RC8650 Robo Robert**.

Two products in one bundle:

- **RC8650Voices.appex** — an `AVSpeechSynthesisProviderAudioUnit` (audio unit
  type `ausp`). This is the synthesizer.
- **RC8650.app** — the container app. It carries the extension, edits the
  settings the extension speaks with, and is a bench for the chip: every
  command it accepts, the Interrogate reply it answers with, and a Speak button
  that goes straight to the emulator so it can be compared against the system
  path.

Both link librc8650 (the repository root, `..`), which runs the RC8650's real
firmware on an emulated Renesas M16C. The voice, the text-to-speech and the
command protocol are the chip's own.

## Build

```
./build.sh              # build into build/
./build.sh install      # build, install to /Applications, register
open /Applications/RC8650.app
```

Then look in **System Settings ▸ Accessibility ▸ Spoken Content ▸ System
Voice**. The extension is registered by LaunchServices when the app that
carries it is, which is why the app has to be opened once.

Needs `xcodegen` (`brew install xcodegen`); `project.yml` is the source of
truth and `RC8650.xcodeproj` is generated. `build-lib.sh` builds `librc8650`
as a universal static library first, from the same sources as the
repository's Makefile.

### Firmware

The RC8650 firmware image is RC Systems' copyrighted code and is **not**
distributed here. Supply your own Motorola S-record image, through the app's
**Install Firmware Image…** or by putting it at

```
~/Library/Group Containers/EC7L97XK6C.com.guilevi.rc8650/firmware.srec
```

`build.sh` copies `rc8650_m4_valid.srec` there if it finds one beside the
repository (`../../`). `.srec.gz` is accepted too — the app inflates it on
install.

### Signing, sandboxing and the App Group

macOS refuses to load an app extension that is not sandboxed — `pkd` says
*"Ignoring mis-configured plugin: plug-ins must be sandboxed"* and the voices
simply never appear. So the extension is sandboxed, and a sandboxed extension
cannot see `~/Library/Application Support`; the settings and the firmware live
in an App Group container instead, which both sides are entitled to.

That makes the team identifier load-bearing. To build this under a different
account, change both of these in `project.yml`:

```yaml
RC8650_APP_GROUP: EC7L97XK6C.com.guilevi.rc8650
DEVELOPMENT_TEAM: EC7L97XK6C
```

Ad-hoc signing (`CODE_SIGN_IDENTITY=-`) will build, but the App Group
entitlement needs a real team identity to be honoured.

## What the container app exposes

Everything the firmware will let a host set. Which command letter moves which
setting, and what each one clamps to, was established by sending
`<CTRL+A>n<letter>` to the emulated chip for every letter A-Z and diffing the
23-byte Interrogate reply (`12?`, datasheet Table 19) before and after — not
read off the datasheet prose.

| Tab | Settings |
|---|---|
| Voice | voice (`nO`), rate, pitch (`nP`), volume (`nV`), expression (`nE`), articulation (`nA`), formant (`nF`), reverb (`nR`), tone (`nX`), speech mode with its word or character delay (`nT` / `nC`) |
| Text | the four fields of the Punctuation Filter Register (`nB`), what a calling app's own rate/pitch/volume are allowed to do, and text sent around every utterance |
| Dictionaries | the pronunciation dictionaries the extension speaks with, in load order, with rule counts and parse errors; import, create, rename, duplicate and delete, and an editor window per file |
| Output | the modeled output stage's reconstruction filter — a switch to take it out of circuit entirely, seven named presets from 1.5 kHz to 8 kHz, and a free corner frequency |
| Advanced | Protocol Options Register (`nG`), Audio Control Register (`nN`), sleep (`nQ`), timeout (`nY`), TS pin control (`nK`), and the command stream it all compiles to |
| Diagnostics | firmware and voice-registration status, `6?` identification, the live `12?` Interrogate table, and a raw command console |

Settings are **per voice**, because that is how the chip works: sending `nO`
reloads seven parameters from that voice's firmware preset, so "the pitch" is
not one number carried across voices. A parameter left at its preset is not
sent at all, which lets the preset show through exactly.

Six command letters — H, L, M, U, W and Z — move nothing in the Interrogate
reply. They are the dictionary, recording and programming commands, which have
state of their own; the raw console on the Diagnostics tab is how to reach
them.

## Pronunciation dictionaries

Every `.dict` file in the group container's `Dictionaries/` folder is loaded and
applied to text on its way to the chip: respellings, phonemes through the
chip's own phoneme mode, or embedded commands, matched by word, substring or
regular expression. This is `rcdict`, described in
[`../README.md`](../README.md#pronunciation-dictionaries),
with the format in `../rcdict/rcdict.h` and a worked example in
`../rcdict/example.dict`.

The Dictionaries tab manages the folder, and the Diagnostics tab still prints
its path. The folder is checked before every utterance — save a file and the
next thing spoken uses it, with nothing to restart. That check is a `readdir`
and a `stat` per file, alongside the one `SettingsStore` already does.

Files load in sorted order, and **order decides priority**: matching is
first-match-wins in load order, so `00-mine.dict` beats `50-shared.dict` and a
later file can only add to an earlier one, never override it. The tab numbers
the list for that reason, and renaming is how a file is moved earlier or later.

### Why importing copies, and why there is an editor

Leaving a dictionary where the user keeps it and symlinking it into the folder
would be the better design, and is what the NVDA add-ons do — they store a path
and never copy. It cannot be done here. Both halves of this project are
sandboxed (macOS will not load an extension that is not), and the extension's
entitlements carry the App Group and nothing else. The sandbox authorizes by
path *after* resolving symlinks, so a link pointing at `~/Documents/es.dict`
asks the extension to read `~/Documents/es.dict`, which it may not: the link
resolves, the open fails, and the dictionary silently does not apply.

The near-misses fail too. `com.apple.security.files.user-selected` is the app's
and not the extension's, and covers only what was picked in this launch; a
security-scoped bookmark is scoped to the bundle identifier that created it, so
the app cannot hand one to the extension. A hard link would survive the sandbox
— same inode, no path to authorize — but not the first edit, since an editor
that saves atomically writes a temporary file and renames it over the original,
leaving the link on the old inode.

So the copy is forced, and a copy goes stale the moment the original is edited
somewhere else. The editor is what fixes that: it edits the copy in place, which
makes the copy the document rather than a snapshot of one. It is a separate
window rather than a sheet so it can stay open while the main window speaks —
write a rule, save, Speak, listen, adjust — and it shows the rule count, the
parse errors with their line numbers, and what the rules as they stand do to a
line of text, with the chip's control bytes shown as `⌃A` so the phoneme-mode
switches are visible.

Expansion happens before the text is split into chip-sized utterances, not
after. One word can become forty characters of phonemes plus the two mode
switches, so splitting first can push a piece past the chip's 2 KB input
buffer, where the overflow is dropped without a word.

## How it fits together

```
synthesizeSpeechRequest   parse the SSML, work out the chip parameters,
                          start a SpeechStream, return
SpeechStream              run the emulator on its own thread, put its output
                          through the output stage, fill a ring buffer
internalRenderBlock       copy out of the ring; that is all it does
```

### The output stage

The chip's D/A runs at 10017 Hz (7.3728 MHz crystal / 8 / 92), which is not a
rate anything else on a Mac wants. `OutputStage` bridges it with a windowed-sinc
interpolator and then applies the reconstruction filter at the output rate;
librc8650's own filter is switched off at boot and stays off.

The reference for how this should sound is `rc8650say -o out.wav` played with
afplay — the bare 8-bit D/A path at 10017 Hz, reconstructed by the system's own
converter, which is bandlimited. Two wrong answers were tried first. Band energy
over one utterance, as a share of the total:

| | 0-1k | 1-3k | 3-4.2k | 4.2-5k | 5-8k | 8-14k | 14-24k |
|---|---|---|---|---|---|---|---|
| REFERENCE unfiltered @10017 | 88.66% | 9.38% | **1.94%** | 0.02% | 0.00% | 0.00% | 0.00% |
| Catmull-Rom to 48k | 90.97% | 7.71% | 1.20% | 0.02% | 0.07% | 0.02% | 0.01% |
| sample-and-hold to 48k | 90.11% | 7.23% | 1.16% | 0.03% | 0.47% | 0.61% | 0.38% |
| windowed sinc to 48k | 90.31% | 7.91% | **1.72%** | 0.02% | 0.02% | 0.01% | 0.01% |

Catmull-Rom is a smoothing interpolator: it took nearly 40% out of 3-4.2 kHz,
which is exactly the band the reconstruction filter exists to control, so
switching the filter on and off barely changed what you heard.

A zero-order hold is what the D/A pin really does, and it puts the converter's
imaging back — a real part of what unfiltered hardware sounds like. But it is
not what the reference sounds like, and it is not free either: the hold's own
sinc rolloff took the same 40% out of 3-4.2 kHz while adding 1.5% of energy
above 5 kHz that afplay would never have produced.

The windowed sinc is closest to the reference in the band that matters. It also
keeps the filter switch fully audible: 1.72% unfiltered against 0.46% at 3 kHz,
the same 3.7:1 the reference has.

**The kernel has to be long enough**, which took a second pass. A resampler's
anti-imaging filter must get from passband to stopband between the highest
frequency worth keeping and the bottom of the first image — here between about
4.6 kHz and 5009 Hz — and how narrow that transition can be is set by the
kernel's length. At 16 taps it was nowhere near: sweeping single tones through
it, a 4600 Hz tone came out 1.37 dB down with its image only **29 dB** below it,
at 5417 Hz. Since 10017 Hz material cannot have anything above 5008 Hz at all,
that image sat in a band that is otherwise perfectly empty — which is exactly
where added hiss gets noticed, and it was audible as high-end noise that the
reference does not have.

96 taps at a 0.475 cutoff is flat to 0.00 dB up to 4600 Hz — a *wider* passband
than the short kernel managed — with the image 48 dB down. The kernel is a
512-phase table with the two rows either side blended, because quantising the
phase to the nearest row is timing jitter, and jitter alone put a flat −77 dB
floor across the spectrum. It costs 0.9% of a core per second of audio.

Measured against the same utterance through `rc8650say`, normalised on the
0–3 kHz band with the analysis bandwidth matched at both rates:

| | 300 | 1000 | 2000 | 3000 | 4000 | 5008 | 6000 | 8000 |
|---|---|---|---|---|---|---|---|---|
| rc8650say @10017 | -2.8 | -4.1 | -13.1 | -14.1 | -17.3 | -36.5 | . | . |
| 16 taps @48000 | -2.9 | -4.0 | -12.7 | -14.3 | -17.0 | -37.6 | **-55.2** | -99.9 |
| 96 taps @48000 | -2.9 | -4.0 | -12.7 | -14.3 | -17.0 | -37.6 | . | . |

Every band the chip occupies agrees within 0.4 dB. One caveat for anyone
repeating this: match the analysis bandwidth. A fixed frame length at both rates
is a 4.8x difference in resolution, and that alone fakes a 2 dB tilt across the
consonant bands.

The output bus runs at 48 kHz. Both the extension and the container app's Speak
button use this same code at the same rate, so the bench and the system voice
are the same signal.

**One engine per process.** The emulator core keeps file-scope state and
`librc8650` refuses a second instance, so `RC8650Engine` is a singleton behind
a lock. Two audio unit instances wanting to speak at once serialise: there is
one chip, and it says one thing at a time.

## Three bugs this shook out

**Two in librc8650, now fixed there** rather than worked around here. The pump
ended an utterance on silence while the chip was still thinking: the chip emits
a couple of hundred samples with TS low, spends up to 149k instructions on
letter-to-sound, and only then raises TS, and the quiet rule was being applied
to a counter that had been running throughout that think. When the think ran
past the 100k threshold — 109,623 instructions, the first time a given command
set is parsed — the utterance ended at the exact moment the chip announced it
was about to speak. The caller got 231-387 samples, and the text still in the
input ring turned up glued to the front of the next utterance. That is what
"the next utterance is a repeat of part of the current one" was.

The second form appeared under cancel-then-speak: TS could still be high from
the previous utterance, so the new one was declared started and then finished
before it said anything. Both are in `librc8650/README.md`, with the
measurements.

**One here.** A speech synthesis host is not a real-time audio device: it drains
the whole utterance as fast as the unit will hand it over and then plays what it
collected, so returning silence from the render block while the emulator catches
up does not paper over a glitch — it *inserts* silence into the recording. The
first version returned about 9.5 seconds of zeroes while a 1-second utterance
was rendering, and the host duly played all of it. `SpeechStream.render` waits
instead.

## Reading the request

The obvious way to read an SSML request — `AVSpeechUtterance(ssmlRepresentation:)`
— throws away everything that makes it SSML. Measured against the real thing:

```
in   <speak><prosody pitch="+50.0%" rate="340.0%">Hello.</prosody></speak>
out  speechString "Hello.", rate 0.5, pitchMultiplier 1.0, volume 1.0

in   <speak>First phrase.<break time="400ms"/>Second phrase.</speak>
out  speechString "First phrase.Second phrase."
```

Every prosody attribute comes back at its default whatever the markup says, and
a break is dropped so completely that the text either side is run together
without even a space. **That is why VoiceOver's rate did nothing**: VoiceOver
sets it, `AVSpeechSynthesizer` duly writes it into the SSML, and the parser
drops it on the floor.

`SSML.swift` reads the markup instead:

| markup | what it does |
|---|---|
| `<prosody rate>` | scales the rate, by matching against measured rung durations rather than a words-per-minute label |
| `<prosody pitch>` | scales `nP`; percentages, semitones and the named steps |
| `<prosody volume>` | scales `nV`; decibels, percentages and the named steps |
| `<break time>` / `<break strength>` | real silence in the stream, since the chip has no pause command |
| `<say-as interpret-as="characters">` | the chip's own character mode (`nC`) |
| `<p>` | a 300 ms pause at the end |

Each scale is relative to the user's settings for that voice, so a request with
no prosody comes through as exactly what the container app shows. It also means
the extremes saturate, which is honest rather than broken: the chip's whole
range is 116 to 400 wpm — 1.7x slower to 2x faster than its own default — while
`AVSpeechUtterance.rate` spans 12.5% to 400%. A screen reader set to its slowest
or fastest lands on the end of the ladder and stays there. Moving the base rate
in the container app is what shifts where the usable middle sits. Verified end
to end: `volume="-12dB"` gives a peak of 0.127 against 0.517 (−12.2 dB),
`time="700ms"` adds 706 ms of silence, `strength="strong"` adds 406 ms, and
`rate="200%"` halves the duration.

## What is missing

**Word-level highlighting.** `AVSpeechSynthesizer`'s
`willSpeakRangeOfSpeechString` needs per-word markers, and this provides only a
sentence-scoped one. The chip *can* do it — send `<CTRL+A>nI` between words and
the index numbers come back in time with the speech, measured — but
`rc8650_read_serial` runs the emulated CPU forward when its queue is empty, so
a caller cannot tell which sample a marker arrived at. A non-blocking
`rc8650_read_serial_pending()` in the library would be enough to make real
markers possible; estimating positions from character counts would produce
highlighting that is confidently wrong, which is worse than none.

## Licensing

`librc8650`'s emulator core is GPL-3.0-or-later (it derives from GDB's
`sim/m32c`), so everything here inherits that, and **App Store distribution is
not viable**. The firmware image is RC Systems' copyrighted code and is loaded
at runtime from a file you supply.
