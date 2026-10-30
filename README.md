# librc8650

The RC8650 speech synthesizer as a linkable library. It runs the chip's real
firmware on an emulated Renesas M16C and hands back the PCM its D/A converter
would have produced, so the voice, the text-to-speech and the command
protocol are the chip's own.

Built for embedding: an NVDA add-on, a macOS `AVSpeechSynthesisProviderVoice`,
a SAPI5 voice, or anything else that can call C.

## Build

```
make                 # librc8650.a, librc8650.{dylib,so}, rc8650say
make install PREFIX=/usr/local
make windows         # rc8650_64.dll and rc8650_32.dll, via mingw-w64
```

The only build inputs are the patched simulator core, libc and libm — no bfd,
no libiberty, no gdb. `SIM` in the Makefile points at the simulator sources and
defaults to `../gdb-14.2/sim/m32c`.

### Getting the emulator core

The core is not vendored here — it is GDB's, and it is large. `sim/rc865x-sim.patch`
reconstructs it from a stock release:

```
curl -LO https://ftp.gnu.org/gnu/gdb/gdb-14.2.tar.xz
tar xf gdb-14.2.tar.xz
(cd gdb-14.2 && patch -p1 < ../librc8650/sim/rc865x-sim.patch)
make -C librc8650
```

Configuring and building GDB itself is *not* required. Two of the core's
sources, the R8C and M32C instruction decoders, are generated from `.opc` files
by `opc2c`, a build-time tool in the simulator tree; `make` builds it and runs
it into `build/gen/` on its own. Set `GEN=<dir>` to use decoders from an
existing GDB sim build directory instead.

The patch is what makes the stock simulator run this firmware: bare-metal
operation (the hosted-newlib syscall trap is a false positive on firmware),
the RC8650 board's peripheral stubs, the sample clock (timer A3) and the D/A
write tap, and two
CPU bugs the firmware trips over — `disp20[a0/a1]` addresses being truncated to
16 bits, and byte-size operations on `A0`/`A1`, which the M16C computes in 16
bits rather than 8.

The Windows cross build needs `mingw-w64` and nothing else; `win-compat/`
supplies the two things a Windows host lacks, both only so that dead
standalone-simulator scaffolding still compiles. The DLLs depend on
`KERNEL32.dll` and the UCRT alone. `nvda/` is an NVDA add-on built on them.

### Layout

```
rc8650.h  rc8650.c     the library
rc8650say.c            the CLI
stubs.c                stands in for the parts of the standalone simulator
                       that are not linked: main, the bfd loader, the CGEN
                       disassembler, the newlib syscall layer
defs.h  ansidecl.h     shims for two headers a GDB build tree would generate
sim/                   the patch that turns stock gdb-14.2/sim/m32c into the core
win-compat/            what a Windows host lacks, for the mingw-w64 cross build
nvda/                  the NVDA add-on, built on the two DLLs
macos/                 the macOS system voice (speech synthesis extension + app)
```

## CLI

```
rc8650say "Hello, world."             # speak to the speakers
rc8650say -o out.wav "Hello."         # write a WAV
echo "some text" | rc8650say          # read stdin
rc8650say --raw "hi" > raw.u8         # unsigned 8-bit PCM on stdout
rc8650say -c 9S "Fast."               # send a command first (9S = fastest)
rc8650say --chip-id                   # query the chip
```

The firmware image is found via `-f`, `$RC8650_FIRMWARE`, the working
directory, or next to the executable. Playback shells out to `afplay`,
`aplay`, `paplay` or `play`, so the CLI itself has no audio dependency;
embedders should pull PCM from the API instead.

## API

```c
#include <rc8650.h>

rc8650_t *e = rc8650_new("rc8650_m4_valid.srec", NULL);

rc8650_say(e, "Hello, world.");       /* queues text, appends CR */
rc8650_command(e, "5S");              /* <CTRL+A>5S<CR> */

uint8_t pcm[4096];
size_t n; int done;
while ((n = rc8650_read(e, pcm, sizeof pcm, &done)) > 0)
    consume(pcm, n);                  /* unsigned 8-bit mono @ 10017 Hz */

rc8650_free(e);
```

`rc8650_read_s16()` converts to signed 16-bit. `rc8650_read_serial()` returns
the chip's replies to query commands. `rc8650_stop()` sends CTRL+X and drops
pending audio. `rc8650_set_status_messages()` is how a caller that speaks should
be detecting the end of an utterance — see below. Full contract in `rc8650.h`.

### Following the text as it is spoken

Index markers (`<CTRL+A>`*n*`I`) are the chip's way of telling a host where in
the text it has got to, and they are what a screen reader's index marks map
onto. Call `rc8650_set_index_marks()`, plant markers in the text, and pull them
back with `rc8650_read_index_marks()` after each read:

```c
rc8650_set_index_marks(e, 1);
rc8650_say(e, "\x01" "1I" "One. " "\x01" "2I" "Two.");

rc8650_index_mark marks[16];
while ((n = rc8650_read_s16(e, pcm, 1024, NULL)) > 0) {
    size_t nm = rc8650_read_index_marks(e, marks, 16);
    /* marks[i].sample_pos is a position in the same stream
       rc8650_samples_read(e) counts, so it says whether the audio that
       marker refers to has been handed over yet. */
}
```

The chip transmits a marker's number — as a one-byte binary value, not an ASCII
number string — once it has spoken the text up to it, and the library
timestamps it there. Measured against word onsets in the audio: with a marker
in front of each of five short sentences, every marker arrived in the silence
before the word it marks, up to 137 ms ahead of it and never behind.

Unlike `rc8650_read_serial()`, which runs the CPU to give a query reply time to
arrive, `rc8650_read_index_marks()` never steps the chip, so it is safe to poll
from an audio loop. **Markers 66 and 69 do not survive
`rc8650_set_status_messages()`**: they are `B` and `E`, the V8600-scale
start/stop messages, which are consumed as status under either speed scale.

### Pronunciation dictionaries

`rcdict/` is a self-contained BSD-3-Clause layer that rewrites text on its way
to the chip: respellings, phonemes through the chip's own phoneme mode, or
embedded commands. It is shared byte-for-byte with `doubletalk-pc`, which is
why it is BSD-3 and depends on nothing but libc — that direction works, the
reverse never could.

```c
#include <rcdict.h>

rcdict *d = rcdict_new(&rcdict_rc8650);
rcdict_add_file(d, "my.dict", NULL, NULL);
rc8650_set_dictionary(e, d, /* inline [[...]] escapes */ 0);
rc8650_say(e, "I saw Sean use NVDA.");
```

Columns are tab-separated:

```
word		Sean	Shon
word		NVDA	[EH N V IY D IY EY]
word	C	US	[Y UW EH S]
regex		\bv([0-9]+)\.([0-9]+)\b	version \1 point \2
```

`rcdict/example.dict` is a worked example, and the test suite requires it to
parse without a diagnostic. Full format in `rcdict/rcdict.h`.

**A caller that splits long text into utterances must expand first**, with
`rc8650_expand()` — one word can become forty characters of phonemes plus the
mode switches, so splitting before expanding can push a piece past the chip's
2 KB input buffer, where the overflow is dropped silently.

The substitutions are shaped by measurement, not guesswork: a phoneme span
breaks the letter-to-sound stage's context on both sides of itself, so trailing
`.`/`,` is moved inside the span and a preceding article `a` is absorbed into
it. With both applied the audio is byte-identical to what text mode produces.
See `dict-lab/RESULTS.md`, and `make rcdict-test`, which checks that on the
chip and not just on paper.

Regex support is Remimu (CC0, vendored as `rcdict/remimu.h`), with its
backtracking budget capped — a runaway pattern is retired for the rest of the
utterance and reported, rather than being allowed to stall synthesis.

### The output stage

The 8-bit path is the bare D/A. The s16 path adds the output stage a finished
product would have had: `rc8650_set_lowpass_hz()` sets its reconstruction
filter, defaulting to the 3 kHz of the datasheet's own reference circuit
(Figure 7). The AO pins really are unfiltered, so 0 — the raw 10 kHz
sample-and-hold staircase, imaging hiss and all — is what they put out.

Rendering is pull-based: the CPU only advances as far as your audio demand,
so a real-time callback can drive it directly, and a file writer can drain it
as fast as the host allows.

**Short reads are normal and must not be papered over.** A read returns as soon
as the chip stops producing, rather than running the CPU on to fill the buffer
you asked for. That matters at the end of an utterance, where the final chunk is
always a short one; holding it back delayed it by 200 ms against 25 ms for every
other chunk — long enough for a streaming caller to run dry and play a gap just
before the last few samples. Loop until a read returns 0; that, not a short
read, is the end.

### Call rc8650_set_status_messages if you speak

Set STM (bit 0 of the Protocol Options Register, `1G`/`129G`) and tell the
library you have, and it will end utterances on the chip's own word rather than
on a guess. Do this. The chip transmits one byte when output starts and another
when it stops, and the stop lands 64 instructions after the final sample:
`done` becomes exact, with no latency.

Without it the library has only silence to work from, and silence is ambiguous
in a way that is easy to get wrong. Once speech is running the D/A is written
on every tick of the sample clock without exception — measured across sixty
utterances covering every voice, both speed scales, all sixteen punctuation
modes, maximum word delay and reverb, as a gap of never more than 206
instructions under the old clock model; under timer A3 a tick is 737 cycles, 184
instructions at the simulator's four cycles each — so there is no such thing as
a pause in the middle of speech. But the chip can pause for up to 149k instructions in the middle of
*starting*: it emits a short burst, then finishes its letter-to-sound work, then
speaks the body. Any quiet threshold responsive enough to end an utterance is
shorter than that pause, so the utterance gets declared over during its own
opening and its speech surfaces glued to the front of the next one. Raising the
threshold only trades that for latency on everything.

The tone, DTMF and recorded-audio generators send no Table 3 status, but they
do drive TS0, and that is what ends their output - measured exact for the
sinusoidal generator and the DTMF dialer; recorded-audio playback has not been
measured. The quiet heuristic is left for text the chip declines to speak, and
for TS held high with nothing coming out (the pin forced high with `3K`).

The idle budget must not wait for the input queue to drain. After the musical
tone generator's Quit frame the chip holds CTS# high until it has played its
buffer, and while the emulation left SUSP0# low it never did: the last bytes
stayed queued, TS stayed high, only 128 samples arrived, and with the queue as a
condition no rule could end the read - `rc8650_read` never returned. A byte
taken from the queue now counts as progress just as a sample does, so a chip
that will not finish is given up on after about 0.8 s, and one that is still
reading its input never is.

`rc8650_read` returns early when DMA0 goes idle, since for speech that means the
firmware's sample ring has drained - but only once DMA has run for the work in
hand. The musical tone generator writes the D/A from code and never starts DMA,
and taking its idle channel as the end returned one sample per read; TS falling
ends it instead.

Tone-generator and recorded-audio data go in through `rc8650_write`, which takes
all of it however long it is: the input queue grows rather than dropping what
the chip has not collected yet.

**Fixed 2026-08-01: utterances that came back as nothing but the opening
burst.** The chip emits a couple of hundred samples with TS still low, spends up
to 149k instructions on letter-to-sound, and only then raises TS. The quiet rule
- "TS is high but no sample has come out for QUIET_INSNS" - was being applied to
a `since_sample` that had been counting throughout that think, so when the think
ran longer than the 100k threshold (measured at 109,623 instructions the first
time a given command set is parsed) it fired on the very first step with TS
high. The utterance ended at the exact moment the chip announced it was about to
speak: the caller got 231-387 samples and nothing else, and the text still
sitting in the input ring surfaced glued to the front of whatever was spoken
next.

A second form of the same mistake showed up under cancel-then-speak, which is
what a screen reader does all day. TS belongs to the chip, not to the current
call, and the chip goes on writing for a moment after a Stop — so the next
utterance could start with the pin still asserted and the tail of the last one
still trickling out. That was read as "this utterance has started", the think
that followed as "and now it has finished", and the utterance was lost whole.
Both rules now require `HEARD_ENOUGH` (512) samples for *this* work before
silence or a TS release may end it: above anything incidental, and far below the
1728 samples of the shortest real utterance there is, a single spoken letter.
Interrupting a sentence at twelve different points and immediately speaking
another: 2 of 12 wrong before, 0 of 12 after.

It was reproducible from a cold boot and worst wherever the parse is slowest -
the first utterance after boot, the first one carrying a command the chip had
not been given before (`<CTRL+A>0N` will do it), and the one after a
`rc8650_stop`. That last one is why a caller could not paper over it by
retrying: with a Stop between attempts the retry loop went 231, 0, 231 and never
recovered. `step_and_track` now clears `since_sample` on TS's rising edge, since
what it counted up to that point was the chip thinking rather than its output
stopping. Twenty repetitions of one sentence: 1 truncated before, 0 after, and
every rung of both rate scales now stable across three consecutive utterances.

**`rc8650_stop` delivers the stop before returning.** Queuing it is not enough
if the caller cancels and immediately queues the next utterance — the new text
goes into the queue behind a stop the chip has not seen yet, and is lost. This
is what makes cancel-then-speak safe.

### Sample rate

`RC8650_SAMPLE_RATE` is 10017 Hz, and everything the library returns is at that
one rate. Resample if your output device needs something else.

The chip's own D/A rate is not fixed. Its sample clock is timer A3, which the
firmware reprograms: the 7.3728 MHz crystal divided by 737 for speech at the
default formant and for the tone and DTMF generators, by 812 down to 677 across
the formant settings `0F` to `9F`, and by whatever real-time playback (`n#`,
`n%`) asks for, from 4 to 11 kHz. The library resamples that to the fixed output
rate by linear interpolation, using each sample's real duration. At the default
divider it is a straight copy, so speech at `5F` comes out byte for byte as the
D/A wrote it.

**The formant setting is a clock change, and nothing else.** That is how the
chip moves every formant at once: `0F` to `9F` produce the same samples, played
at 9.08 to 10.89 kHz. So a higher setting is also slightly faster and
higher-pitched, 9% for `9F` against `5F`. The firmware compensates for neither,
and the emulation does not either.

**10017 Hz is 0.14% high.** It was taken from timer B5, which the BIOS runs at
f8/92 for its delay loop and which was long mistaken for the sample clock. The
real clock divides by 737, so at the default formant the chip runs at
10,003.8 Hz. That is far below anything audible, so the constant stays as it is
documented; output samples are spaced at the real default period, and a caller
that wants to be exact can treat the stream as 10,003.8 Hz.

### Limits worth knowing

- **One engine per process.** The emulator core keeps file-scope state, so a
  second `rc8650_new()` fails with an explanatory message rather than
  corrupting the first. De-globalising the core is the work required to lift
  this, and it is the main thing standing between this and a general-purpose
  multi-voice backend.
- **Not thread-safe.** Serialise calls on the engine.
- **Synthesis is faster than real time** but not free: on an M-series Mac a
  sentence renders at roughly 2–4x real time, with the first sample out in
  10–25 ms and a cold boot in about 5 ms. Render ahead if you need smooth
  streaming.
- **Text the chip declines to speak costs a beat.** A bare CR or a lone space
  produces no D/A activity and no status message either, so there is no signal
  to end on and the pump runs out its idle budget — about 0.7 s — before
  reporting nothing. Filter empty input rather than paying it.

### What the emulation does not cover

Measured on `rc8650_m4_valid.srec` against the RC8650 datasheet. Speech, the
DTMF dialer (button 1: 699.5 and 1213 Hz against 697 and 1209), the sinusoidal
generator (`95J` dial tone: 445 and 352 Hz against 442 and 351.5; `40J` correct
too), the formant setting and real-time PCM playback all come out right. A 500 Hz
tone sent with `78#` comes back at 499.5 Hz; until the sample clock was found
(see "Sample rate") the playback rate was ignored and it came back at 625. These
do not:
- **The musical tone generator (`J`) plays, but at the wrong pitch and tempo.**
  It used to be silent and wedge the chip, because it checks SUSP0# (P7.7) in
  software and waits while it is low, and the emulation left the pin low; it is
  now tied high, as the datasheet asks of an unused one. The generator itself is
  a cycle-counted loop running from RAM: three voice counters, a pulse written to
  the D/A when one runs out, and a calibrated busy-wait, with one pass designed
  to take 1/16,768 s, about 440 cycles - which is where the datasheet's
  fi = 16,768 / Ki comes from. Two things stand between that and the right
  pitch. The simulator charges every instruction four cycles, so a pass of 62
  instructions costs 248 cycles instead of 440; and the library spaces D/A
  writes by the sample clock, which is right for DMA output and wrong for writes
  made from code, whose pulses are a few dozen microseconds wide. The fix is
  per-instruction cycle counts (the software manual's chapter 4 lists them) and
  rendering the D/A by time rather than by write.
- **Digital audio output (`nN` with ACR.7 set) produces nothing.** The firmware
  points DMA0 at U1TB (`0x3AA`) with request source 15, UART1 transmit, which the
  simulator does not model, so speech stops at the first sample. The library
  hands you the digital stream anyway, so there is no reason to switch this on.
- **The A/D converter (`n$`) is not modelled** and answers nothing, and there is
  no API to feed it a signal, so recording has nothing to record.
- **Prerecorded playback (`n&`)** needs a sound library downloaded with `223W`,
  which is untested.
- **Timers A0 and A1 are not modelled.** The firmware chains them into a slow
  timer - A0 overflows about every 130 ms and A1 counts 460 of those, about a
  minute - with A1's interrupt enabled. It is most likely behind the sleep or
  timeout features; nothing measured so far depends on it.

## Licensing — read before shipping

The emulator core is GPL-3.0-or-later (it derives from GDB's `sim/m32c`), so
anything linking `librc8650` inherits that, and this repository is
GPL-3.0-or-later throughout — full text in `LICENSE`. Two practical
consequences:

- **NVDA** add-ons are GPL-2.0-or-later, which is compatible with GPL-3 only
  if the add-on is distributed as GPL-3-or-later. Check before publishing.
- **App Store distribution is not viable** for a GPL-3 binary.

The RC8650 firmware image is RC Systems' copyrighted code and is **not**
included here. It is loaded at runtime from a file you supply; anyone using
this needs their own copy.

Replacing the GPL core with a clean-room M16C interpreter would remove both
constraints, and is the other significant piece of work if this is ever meant
to ship broadly.
