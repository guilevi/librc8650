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
tools/                 rcstudio2srec.py (firmware images from RCStudio's files),
                       phonlab.c
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
instructions under the old clock and timing model — so there is no such thing as
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

**And it leaves the chip as if the cut-off sentence had ended.** A bare CTRL+X
stops the audio but leaves the text translator mid-sentence: the cancelled
sentence stays in its text window (0x08FB, upper-cased) and the next utterance
is read as its continuation, without the sentence-initial pitch reset and phrase
markers. "Hello there." after a cancel came back 500 samples longer and
different throughout, at every interrupt point tried. Whether the board does
this too is unknown. A full stop is what clears it, so when a stop actually
interrupts something, `rc8650_stop` hands the chip a `.` and CR, lets it run 256
samples into the silent pause that follows (the translator was measured to let
go within the first 64), and stops again. The silence is dropped. Across three
cut-off sentences, three follow-ups and eleven interrupt points each, 99 of 99
follow-on utterances matched a clean one byte for byte; the stop costs about
8 ms of host time on average and 16 ms at worst, and nothing on an idle chip.

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

### Instruction timing

The emulated CPU is charged what the M16C software manual says each instruction
costs - chapter 4's cycle count for that instruction and those addressing modes,
plus the extras its notes give for a branch taken, a shift count, a string
length or a register list, and 18 cycles to enter an interrupt (table 5.3.1).
The firmware runs the CPU at half the crystal (CM1 = 0x40, main clock divided
by two) while the timers count the full 7.3728 MHz, and the timers advance by
cycles times that divider. The simulator used to charge every instruction a flat
four timer cycles; for the musical generator's loop that was about half the
real cost.

Speech, DTMF and the sinusoidal generator render byte for byte as before: they
are computed into a buffer the DMA drains on the sample clock, so timing moves
only when things happen, not what is produced. What it does move: index markers
arrive a few samples later, the moment the firmware switches the sample clock
for a formant or playback-rate change shifts by a sample or so, and anything
the firmware times with code - the musical generator - is now in time.

Two things the counts leave out: the instruction queue, which a taken branch
empties and which the manual's counts assume is full, and the cycles a DMA
transfer takes from the CPU. Patterns the simulator does not implement
(LDCTX, STCTX) and the M32C decoder fall back to the old flat charge.

D/A writes the CPU makes itself are rendered by time: the D/A holds each level
until the next write, and an output sample is that level averaged over its
period. Only once such writes are sustained - sixteen without a DMA sample
between - since speech opens with two CPU writes before the DMA takes over, and
rendering the gap between them put nine samples of silence in front of every
first utterance.

### The A/D converter

`rc8650_set_analog_input()` sets the voltage on AN0-AN3 or AMPOUT, in 256ths of
AVREF, and `n$` converts it. The chip sends each result to the host as one byte
on its serial port, exactly as the datasheet's Figure 16 draws it - one byte for
a one-shot conversion, one per channel for a sweep (`9$` gives AN0 then AN1,
`11$` AN0 to AN3), and back to back in continuous mode until `128$` stops it.
With AMP set the converter reads AMPOUT instead of the multiplexer. Read the
bytes with `rc8650_read_serial()`.

```c
rc8650_set_analog_input(e, RC8650_AN0, 0x80);   /* half of AVREF */
rc8650_command(e, "0$");                        /* one-shot, AN0 */
uint8_t v;
rc8650_read_serial(e, &v, 1);                   /* 0x80 */
```

Underneath, the firmware converts with the M16C's own A/D (ADCON0/1/2, AD0-AD7),
waits for it, and hands the result to DMA channel 1, which copies it into UART0's
transmit register each time the transmitter is free. That is why the datasheet
puts the continuous sampling rate at a tenth of the baud rate, and the emulation
gets it: 640 f1 cycles a byte at 115200 baud, 11,500 readings a second. Before
the converter was modelled, `n$` with INH = 0 left the firmware polling for the
end of a conversion that never came.

**The emulated chip boots at 300 baud.** Its baud-rate select pins (BRS0-BRS2)
read low, and Table 2 makes LLL 300 baud. Nothing else notices - the library
hands bytes over without bit timing - but continuous conversions arrive at a
tenth of the rate, 30 a second. Send `10H` first for 115200 baud and 11,520 a
second (`5H` 9600, `9H` 57600). Tying the pins high instead would select
auto-detect, which times the host's first character on the BRD pin, and the
library has no bit timing to give it.

The serial buffer holds 16 KB, over a second of readings at 115200 baud; drain
it at least that often. Readings that arrive while `rc8650_read` is pumping
audio are subject to the same filters as any other byte: with index markers on,
one of 0-99 is taken for a marker, and with status messages on, the Table 3
bytes (`s`, `t`, `B`, `E`, `e`, `f`) are consumed as status.

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
- **The musical tone generator (`J`) plays about 2.5% sharp.** Middle C
  (Ki = 64) comes out at 268.5 Hz against the datasheet's 262; A at 451 against
  441; low C at 67.5 against 65.8. The generator is a cycle-counted loop running
  from RAM - three voice counters, a pulse written to the D/A when one runs out,
  a calibrated busy-wait - with one pass designed to take 1/16,768 s, which is
  where fi = 16,768 / Ki comes from. Its pitch and tempo are therefore only as
  good as the instruction timing (see "Instruction timing"), and what that leaves
  out is the instruction queue: the manual's counts assume it is full, and a
  taken branch empties it. That is the likeliest source of the 2.5%. It used to
  be silent and wedge the chip, because it checks SUSP0# (P7.7) in software and
  waits while it is low, and the emulation left the pin low; it is now tied high,
  as the datasheet asks of an unused one.
- **Digital audio output (`nN` with ACR.7 set) produces nothing.** The firmware
  points DMA0 at U1TB (`0x3AA`) with request source 15, UART1 transmit, which the
  simulator does not model, so speech stops at the first sample. The library
  hands you the digital stream anyway, so there is no reason to switch this on.
- **The A/D converter's hardware trigger (TRG, the ADTRG pin) is not
  modelled**: a conversion starts as soon as `n$` is written with INH = 0. The
  rest of the converter is - see "The A/D converter" below.
- **Prerecorded playback (`n&`)** needs a sound library downloaded with `223W`,
  which is untested.
- **Timers A0 and A1 are not modelled.** The firmware chains them into a slow
  timer - A0 overflows about every 130 ms and A1 counts 460 of those, about a
  minute - with A1's interrupt enabled. It is most likely behind the sleep or
  timeout features; nothing measured so far depends on it.

## Firmware images: the RC8650 builds and the RC8660

RC Systems' RCStudio ships six firmware sets, each a firmware container and a
BIOS container in `RCStudio/Bin` (the format, the XOR obfuscation and the
pairing are in the reverse-engineering notes, sections 2 and 3).
`tools/rcstudio2srec.py --all <RCStudio>/Bin -o <folder>` turns every known
pair into a loadable S-record named for what it is (`rc8650-v2.60-m4.srec`,
`rc8660-v3.44-m1.srec`); a later release's pair is converted by naming its two
files. The model-4 output is byte for byte the reference image. All six boot,
answer `6?` and `12?`, and speak.

The NVDA add-on and the Mac app both switch between images - see their
READMEs - and take every chip-specific thing from the library rather than from
a datasheet:

```c
rc8650_profile p;
rc8650_get_profile(e, &p);   /* voices + presets, formant and speed ranges,
                                rate ladder, 12? length, marker range */
rc8650_image_info(srec, len, &p);   /* chip, version, model, without booting */
```

`rc8650_get_profile` asks the firmware: it selects every voice and reads it back
with `12?`, binary-searches the speed and formant ranges the same way, and then
reinitialises the chip (`@`) - 85-150 ms of host time, once per engine. Voice
names and the rate ladder, which cannot be asked for, come from tables for the
two known families; unknown firmware gets "Voice n" and its power-on speed scale.
On the RC8660 only the V86 bit is touched while probing: its bit 4 is R50
(datasheet Table 19), and with it clear the chip emulates the RC8650. Its two speed
scales are not interleaved into one ladder the way the RC8650's are, because
clearing V86 on the RC8660 switches it into V8600 compatibility, where formant
runs 0-9 and `12?` is 23 bytes.

| `-m` | Containers | Firmware | `6?` | Factory defaults | Status |
|---|---|---|---|---|---|
| 1 | `m$195a22` + `m$11f9aa` | RC8650 v2.60 | `37 0e 01 04 27 02 60 02` | as model 4 | speech byte-identical to model 4 |
| 2 | `m$28a5f8` + `m$2a11b2` | RC8650 v2.60 | `… 02 04 … 60 02` | `5S`, POR `00` (V8600 speed scale) | identical to model 4 given `0G` `5S` |
| 4 | `m$4a95b2` + `m$4f8c6a` | RC8650 v2.60 | `… 04 04 … 60 02` | `1S`, POR `80` | the reference image, `rc8650_m4_valid.srec` |
| 7 | `m$4b39ca` + `m$4f92e7` | RC8650 v2.60 | `… 07 04 … 60 02` | as model 4 | speech byte-identical to model 4 |
| 8 | `m$29c1d3` + `m$2b71e1` | RC8650 v2.60 | `… 08 04 … 60 02` | as model 2 | speech byte-identical to model 2 |
| 8660 | `m$1a6c3f` + `m$12a73d` | **RC8660 v3.44** | `… 01 05 … 44 03` | `5S`, `50F`, POR `90` | see below |

What the model byte denotes physically is still open (notes, section 3); what it
changes in the firmware, as far as the emulation shows, is the factory
defaults. Models 2 and 8 differ from 1, 4 and 7 only in starting on the V8600
speed scale at rate 5: model 4 told `0G` and `5S` then speaks exactly as model 2
does out of the box, from the third sample on (the first two are the D/A's
boot-time level).

`rc8650_chip()` reports which family the loaded firmware is for, read from the
image header (byte 7, `0x04` or `0x05`).

### The RC8660

The RC8660 is the RC8650's successor: the same M16C, the same 7.3728 MHz
crystal, the same 10 kHz speech rate, the same DoubleTalk engine and voice
data, with a larger RAM, a larger command set and an on-chip recording file
system. Its firmware ran in the emulation only after **simulator bug #7** was
fixed: bit operands were masked as if they were byte addresses, so any at or
above byte `0x2000` wrapped. The RC8650 keeps its variables at `0x123E` and
never noticed; the RC8660 keeps them at `0x2A14`, so its "playback running"
flag landed on the wrong byte, the synthesizer lapped the sample ring and
"Hello there." stopped 1,690 samples in. With that fixed, its "Hello there."
at factory defaults is byte for byte model 2's.

Measured on the emulated RC8660 against its datasheet (User's Manual rev 11,
firmware v3.44):

| Feature | Status |
|---|---|
| Voices `0O`-`10O` (RC8650: 0-7) | all eleven speak, each distinct |
| Protocol Options `nG` | powers up at `144G`: V86 and bit 4, R50. Clear R50 - `129G` (V86 + STM, the RC8650's usual value) does - and the chip emulates the RC8650: `nO` wraps voices 8-10 onto 0-2, formant runs 0-9 and `12?` is 23 bytes. Both front ends sent `129G` before every utterance until this was found; they now build `nG` from `rc8650_profile.por_default` |
| Speed `0S`-`13S` (RC8650: 0-9) | monotonic, 25,180 down to 10,042 samples for one sentence |
| Formant `0F`-`99F` (RC8650: 0-9) | the sample clock again, seven f1 cycles a step: 1,087 cycles (6.8 kHz) at `0F`, 737 at `50F`, 394 (18.7 kHz) at `99F`. Above the 10 kHz output rate the library now averages rather than interpolates, and its floor on a believable period dropped from 512 cycles (which had silently pinned everything above about `84F` to the default) to 64 |
| Index markers `0I`-`255I` (RC8650: 0-99) | captured to 255 when the firmware is an RC8660; `rc8650_max_index_mark()` says which. With status messages on, markers 66, 69, 101, 102, 115 and 116 are consumed as status |
| `12?` | 27 bytes: the RC8650's 23, then free recording memory (16 bits, `FF FF` = -1, "RC8650 library present") and the number of files (16 bits) |
| Sinusoidal generator `nJaaaabbbb` | plays; `n` is the duration in 10 ms steps and `aaaa`/`bbbb` the two frequencies in Hz. The RC8650's `nJ` + three bytes form produces nothing, as the datasheet implies |
| Suspend / resume (CTRL+P, CTRL+R) | work. While suspended, `rc8650_read` reports the utterance done; writing CTRL+R re-arms it, and the rest arrives - 30,988 samples in all against 30,990 uninterrupted |
| Skip (CTRL+Y) | works, on both chips: the sentence in progress ends and the next CR-terminated one plays |
| A/D converter, DTMF, real-time PCM, musical generator | as on the RC8650 |
| **Recording memory** - record (`nL`), upload (`245L`), erase (`234L`), initialise (`214W`), repair (`218W`), download (`236W`, `223W`), data logging | **not emulated.** All of it lives in the external flash, and the emulation models only that chip's ID query: programs and erases are ignored, and `214W` sends no result code at all. The firmware erases through command cycles at `0xFFAAA`/`0xFF554` inside the CPU's `0x80000`-`0xFFFFF` window - the same 8 MB part that holds the firmware at flash `0x7A0000`, the window showing its top 512 KB - and switches banks through port 7 bits 3-5 (`0x80`, `0xA0`, `0xB0`, `0xB8` around an erase). Emulating it means the whole part: the array, the banking, program and erase, and status polling |

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
