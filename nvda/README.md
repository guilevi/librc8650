# RC8650 (emulated) — NVDA add-on

An NVDA synthesizer driver for `librc8650`. The chip's real firmware runs on an
emulated Renesas M16C and the driver plays back the PCM its D/A converter would
have produced, so the voice and the text-to-speech are the chip's own — NVDA
just feeds it text and the `<CTRL+A>`*n*`<char>` commands a 1990s host would
have sent down a serial port.

## Building

1. Cross-compile the DLLs. NVDA 2025.2 and later run as a 64-bit process,
   earlier versions as a 32-bit one, so both are shipped:

       brew install mingw-w64          # or apt install mingw-w64
       make -C .. windows

   Each DLL depends only on `KERNEL32.dll` and the UCRT
   (`api-ms-win-crt-*`), which ship with Windows 10 and later — no mingw
   runtime for the user to install. Worth re-checking if you change the build:

       x86_64-w64-mingw32-objdump -p ../rc8650_64.dll | grep 'DLL Name'

2. Copy the DLLs and your firmware image into the driver directory:

       cp ../rc8650_64.dll ../rc8650_32.dll synthDrivers/rc8650/
       cp ../../rc8650_m4_valid.srec        synthDrivers/rc8650/

   The firmware is RC Systems' copyrighted code and is not distributed here.
   The driver looks for `rc8650_m4_valid.srec`, `rc8650.srec`, or either name
   with a `.gz` suffix — the S-record is about 900 KB of ASCII and gzips to a
   third of that, which is worth doing since it is the bulk of the package.

3. Package it (an `.nvda-addon` is a zip with `manifest.ini` at the root):

       ./build_addon.sh                  # no firmware bundled
       ./build_addon.sh --with-firmware  # personal build - do not distribute

4. Open the `.nvda-addon` on the Windows machine and pick **RC8650 (emulated)**
   in NVDA's synthesizer dialog. Without a firmware image the driver reports
   itself unavailable and will not appear in the list — that is the intended
   behaviour, not a failure.

`manifest.ini`'s `author` and `url` are placeholders. Set them before this goes
anywhere near another person.

## What is mapped

Every text-to-speech command the chip has, plus the two registers that affect
reading. Selecting a voice snaps the voice-linked settings to that voice's
firmware preset, and each is sent to the chip only when moved off it — so an
untouched voice sounds exactly like the firmware intends.

| NVDA setting | Command | Range | Voice-linked |
|---|---|---|---|
| Voice | `nO` | 0–7 | — |
| Rate | `nS`, `nG` | 20 rungs, ~116–395 wpm | no |
| Pitch | `nP` | 0–99 | yes |
| Inflection | `nE` (expression) | 0–9 | yes |
| Volume | `nV` | 0–9 | no |
| Tone | `nX` | bass / normal / treble | yes |
| Articulation | `nA` | 0–9 | yes |
| Formant frequency | `nF` | 0–9 | yes |
| Reverb | `nR` | 0–9 | yes |
| Word delay | `nT` | 0–15 | yes |
| Punctuation | `nB` bits 1–0 | all / most / some / none | no |
| Read numbers as numbers | `nB` bit 2 | on/off | no |
| Speak leading zeros | `nB` bit 3 | on/off | no |
| Four-digit numbers as years | `nB` bit 4 | on/off | no |
| Output filter | — (host side) | off, 2–4.8 kHz | no |

NVDA's speech indexes are the chip's index markers (`nI`) — see below.

Cancel sends the chip's own `CTRL+X`. Capital-letter pitch changes, and any
other prosody command NVDA emits, are sent as absolute `nP`/`nV`/`nS` values
computed from the base setting, so the reset afterwards restores the real value
without having to re-select the voice.

### Knowing when an utterance has ended

Every prefix sets STM, bit 0 of the Protocol Options Register, so the chip
transmits a one-byte message when its output starts and another when it stops
(datasheet Table 3). That is what `librc8650` ends an utterance on. The
alternative is inferring the end from silence, which is not sound: the chip can
go quiet for 149k instructions in the *middle* of starting an utterance, longer
than any threshold responsive enough to end one — see the library README for
what that cost. The stop message lands 64 instructions after the final sample,
so end-of-speech is reported 0.2 ms after the last audio instead of 10.8 ms.

Setting the bit changes nothing else: every rung of the rate ladder was re-timed
with it set and nineteen of the twenty came back identical to the sample, the
twentieth differing by two samples in 53875.

### Index marks are the chip's own

NVDA index marks are the chip's index markers (`nI`, Table 20), not something
the driver keeps on the side. An `<CTRL+A>`*n*`I` goes into the text wherever
NVDA puts an index; when the chip has spoken the text up to it, it transmits
the marker number, and `librc8650` timestamps that against the sample stream
(`rc8650_read_index_marks`). The driver then reports the index when the audio
chunk containing that position finishes *playing*, by hanging the notification
off that chunk's `WavePlayer.feed`, so an index is announced as its words are
heard rather than when the utterance ends.

Measured with a marker in front of each of five short sentences, against the
word onsets found in the audio itself: every marker arrived in the silence
before the word it marks — up to 137 ms ahead of it, never behind. Through the
driver, the five indexes were reported 0.10, 0.82, 1.53, 2.25 and 2.97 s into a
3.75 s utterance whose words start at 0.00, 0.76, 1.54, 2.30 and 3.02 s.

Two details worth knowing if you touch this:

- **The marker comes back as a binary byte, not an ASCII number.** The command
  takes a decimal string (`<CTRL+A>12I`), the reply is a single byte with the
  value 12. That is why marker numbers have to stay in 0–99, and why the
  library hands markers back through their own call rather than mixed into
  `rc8650_read_serial`.
- **Markers 66 and 69 are unusable here**, so the driver rolls through 0–63
  instead. They are `B` and `E`, the V8600-scale start/stop status messages,
  and because the driver switches speed scales per utterance (see the rate
  ladder) the library has to recognise both scales' messages at all times —
  which means those two bytes are consumed as status before they can be read
  back as markers. Confirmed by sending both numbers under either scale and
  getting nothing back.

An index that the chip never reports — text it declines to speak, or an index
in a sequence with no speech in it at all — is still reported when the
utterance finishes, in order. That backstop is not cosmetic: Say All advances
on these notifications, so an index that goes unreported does not merely cost
highlighting, it stops the reading.

### Two ordering rules the datasheet does not mention

**`nG` is emitted before `nO`, not after.** In the datasheet's own order — voice
first — this firmware emits a 232-sample burst, about 23 ms peaking at 5% of
full scale, and only then settles down and speaks. That is an audible blip in
front of every utterance. Putting the register first is safe: the ordering rule
is about the parameters `nO` reloads, and interrogating the chip after an `nO`
shows the Protocol Options Register untouched.

> An earlier version of this file claimed the two commands in that order made
> the firmware *swallow* the utterance. They do not. What swallowed it was the
> pause that follows the burst while the chip finishes parsing: the library read
> that pause as the end of the utterance and stopped, so the speech turned up
> attached to the front of the next one. It was text-dependent because the pause
> length is, which is what made it look like a firmware quirk. The library fix
> is above; the ordering is still worth keeping, for the blip.

**Utterances are terminated with NUL, not CR.** The two are interchangeable as
terminators, but with the punctuation filter set to *All* the chip speaks CR, LF
and space — including the CR that ends the utterance, which measured as an extra
half-second of speech on every one. NUL is not in that set.

### The rate ladder

The chip has *two* speech-rate scales, chosen by bit 7 (V86) of the Protocol
Options Register. Its power-on default runs `nS` 0–9 over about 173–395 wpm;
clearing the bit makes it emulate RC Systems' earlier V8600 module, where the
same `nS` 0–9 runs about 116–242 wpm. The driver merges both into one monotonic
twenty-rung ladder covering 116–395 wpm, so the rate slider is both wider and
finer than either scale alone, and one arrow key is one rung.

This is only sound because V86 changes nothing else the driver uses:
interrogating all eight voices with the bit set and clear returns identical
presets, and its only other documented effect is on status messages, which stay
off in both. Every rung was timed on the same sentence.

### What the chip does *not* get used for

Character mode (`C`), phoneme mode (`D`), the musical tone and DTMF generators,
recorded-audio playback, the A/D converter, sleep and timeout timers, baud rate
and TS-pin control, and downloadable exception dictionaries and greeting
messages. None of them have a screen reader's use for them; the commands are
all still reachable through `librc8650` directly.

## Known limitations

- **Index marks resolve to one audio chunk, not to the sample.** The chip's
  markers are exact, but the driver reports an index when the ~102 ms chunk
  holding its position has played, so the notification can be up to that late.
  Set against the marker's own ≤137 ms lead on the word it marks, the two
  roughly cancel; a smaller `SAMPLES_PER_CHUNK` would tighten both ends at the
  cost of more calls into the emulator.

  (An earlier version of this file said the firmware transmits each marker when
  it *parses* it, so markers carried no timing and could not be used. That was
  measured through the broken end-of-utterance detection that caused everything
  else here, and it is wrong — see above.)
- **One engine per process.** The emulator core keeps file-scope state and
  refuses a second engine. The driver unloads the DLL on terminate so that
  switching synthesizers away and back works.
- **Rendering costs real CPU.** Speech is produced roughly 2–4x faster than
  real time on a modern machine, and the first sample of an utterance arrives
  in 10–25 ms. Both are comfortable, but this is an instruction-level CPU
  emulator: it is not free the way a table-driven synthesizer is.
- **Cancel is synchronous.** `cancel()` runs the chip's Stop through to the
  chip before returning, rather than queuing it, because NVDA queues the next
  utterance immediately afterwards and it must not go in behind an undelivered
  stop. That was what lost the utterance after an interruption. Cancelling
  therefore costs a few thousand instructions of emulated CPU on NVDA's main
  thread — microseconds, but not free.
- **Long utterances are split.** The chip's input buffer is 2 KB, so text
  longer than that is broken at a space and sent as several utterances. The
  seam costs a sentence boundary's worth of prosody.

## Testing

The driver's logic and its command streams were verified against the real
emulator outside NVDA: the harness stubs NVDA's API, loads the driver against
`librc8650.dylib`, speaks, and then asks the chip what its settings actually
are with the Interrogate command (`12?`) — so every mapping in the table above
is checked against the chip rather than against the datasheet's prose. The
voice presets in the driver were read out of the firmware the same way.

The index-marker path was checked the same way, driving the real `speak()` and
synthesis thread with a stub `WavePlayer` that records what was notified and
how much audio had been fed at the time: indexes reported in order and at the
right positions for one index per sentence and for a single trailing index;
an index in a sequence with no speech reported immediately; a cancel
mid-utterance leaving no stale index to surface in the next one; sixty-eight
consecutive utterances to take the rolling marker number past its wrap-around;
seventy more queued in one burst, so the numbers wrap while earlier utterances
are still waiting to be spoken; and both speed scales, the V8600 one being
where the `B`/`E` collision would show up.

That burst is why the marker-to-index map lives on the queued utterance rather
than on the driver: with one shared map, a number handed out again while its
first owner is still playing resolves to the wrong index, and NVDA acts on
these — a wrong index in Say All jumps the reading to the wrong place.

It has **not** yet been run inside NVDA itself; `lastTestedNVDAVersion` is set
so it installs on current versions, not because it has been through them.
