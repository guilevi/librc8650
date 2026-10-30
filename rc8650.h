/* SPDX-License-Identifier: GPL-3.0-or-later */
/* librc8650 --- RC8650/RC8660 speech synthesizer, emulated.
 *
 * Runs the real RC8650 firmware on an emulated Renesas M16C and returns the
 * PCM its D/A converter would have produced.  The text-to-speech, the voice
 * and the command protocol are the chip's own; this library only supplies the
 * processor, the peripherals and the plumbing.
 *
 * Typical use:
 *
 *     rc8650_t *e = rc8650_new("rc8650_m4_valid.srec", NULL);
 *     rc8650_say(e, "Hello, world.");
 *     unsigned char pcm[4096];
 *     size_t n;
 *     while ((n = rc8650_read(e, pcm, sizeof pcm, NULL)) > 0)
 *         fwrite(pcm, 1, n, out);
 *     rc8650_free(e);
 *
 * Audio is unsigned 8-bit mono at RC8650_SAMPLE_RATE.  rc8650_read_s16()
 * converts if your audio stack wants signed 16-bit.
 *
 * Threading: all calls on one instance must come from one thread at a time.
 * The emulator core keeps global state, so only ONE instance can exist per
 * process; a second rc8650_new() fails with an explanatory error.
 */

#ifndef RC8650_H
#define RC8650_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Sample rate of everything the library returns.  The chip's own D/A rate
 * moves with the formant setting (nF) and real-time playback (n#, n%); the
 * library resamples it to this one.  The default D/A rate is the 7.3728 MHz
 * crystal divided by 737, 10003.8 Hz, so this nominal figure is 0.14% high -
 * see "Sample rate" in README.md. */
#define RC8650_SAMPLE_RATE 10017

/* The same value, for callers that reach the library through a shared object
 * and cannot see the macro (ctypes bindings, FFI wrappers). */
unsigned rc8650_sample_rate (void);

/* The command lead-in byte.  The chip's protocol is
 * <CTRL+A><number string><command character>, and nothing is spoken until a
 * CR or NUL arrives.  rc8650_say() and rc8650_command() handle this for you. */
#define RC8650_CTRL_A 0x01

typedef struct rc8650 rc8650_t;

/* --- lifecycle ---------------------------------------------------------- */

/* Create an engine from a firmware image in Motorola S-record form.  On
 * failure returns NULL and, if err is non-NULL, stores a malloc'd message
 * there for the caller to free(). */
rc8650_t *rc8650_new (const char *srec_path, char **err);

/* Same, from an in-memory S-record image (so the firmware can be embedded). */
rc8650_t *rc8650_new_from_memory (const void *srec, size_t len, char **err);

void rc8650_free (rc8650_t *e);

/* Cold-boot the chip again, discarding queued input and undrained audio. */
void rc8650_reset (rc8650_t *e);

/* --- input -------------------------------------------------------------- */

/* Queue raw bytes exactly as they would arrive on the serial port.  All of
 * len is accepted (queued internally); the emulated UART then consumes it at
 * the rate the firmware's CTS# flow control allows. */
void rc8650_write (rc8650_t *e, const void *data, size_t len);

/* Queue text and terminate it with CR so the chip starts speaking.  Embedded
 * command sequences are passed through untouched, and the pronunciation
 * dictionary (if one is set) is applied first. */
void rc8650_say (rc8650_t *e, const char *text);

/* --- pronunciation dictionary -------------------------------------------- */

/* Substitute pronunciations into text on its way to the chip: respellings,
 * phonemes through the chip's own phoneme mode, or embedded commands.  The
 * rules, the file format and the loaders are rcdict's; include rcdict.h to
 * build one.  Everything here is optional and off until asked for.
 *
 * The dictionary is BORROWED.  It must outlive the engine, or be replaced with
 * NULL before it is freed.  inline_phonemes switches on the "[[K AE T]]"
 * escape in ordinary text, which is off by default because "[[" is wiki link
 * syntax and a user reading a wiki must not lose text to it. */
typedef struct rcdict rcdict;
void rc8650_set_dictionary (rc8650_t *e, const rcdict *d, int inline_phonemes);

/* Run the dictionary over text WITHOUT speaking it, returning the number of
 * bytes the result needs (not counting a terminating NUL), so a return value
 * >= outcap means it was truncated and the call should be repeated bigger.
 *
 * This exists for callers that split long text into utterances themselves: a
 * word can expand to forty characters of phonemes plus the mode switches, so
 * splitting first and expanding after can push a piece past the chip's 2 KB
 * input buffer, where the overflow is dropped without a word.  Expand, then
 * split. */
size_t rc8650_expand (rc8650_t *e, const char *in, size_t inlen,
		      char *out, size_t outcap);

/* Send a command such as "6?" or "5S" as <CTRL+A>cmd<CR>. */
void rc8650_command (rc8650_t *e, const char *cmd);

/* Stop speaking immediately (CTRL+X) and drop pending audio.  The stop is
 * delivered to the chip before this returns, not merely queued, so a caller
 * may write the next utterance straight afterwards.  When it interrupts
 * something it also ends the cut-off sentence for the chip's text translator,
 * so the next utterance is spoken exactly as it would be after a clean finish;
 * that costs about 10 ms of host time.  On an idle chip it costs nothing. */
void rc8650_stop (rc8650_t *e);

/* --- knowing when an utterance has ended --------------------------------- */

/* Tell the library you have set STM (bit 0 of the Protocol Options Register,
 * the nG command), so that the one-byte Table 3 status messages are recognised
 * for what they are.
 *
 * Calling this is now OPTIONAL, and it no longer affects when an utterance is
 * reported as finished.  Utterances end on TS0, the chip's own talk-status
 * output ("TALK STATUS: Indicates whether a voice channel is active"), which
 * the library reads directly.  TS0 is exact at both ends, needs no opt-in, and
 * unlike Table 3 it also covers the sinusoidal and DTMF generators, which
 * transmit no status at all.
 *
 * What this flag still does is keep the status bytes out of your data: when
 * set, the start/stop/buffer messages are consumed rather than delivered to
 * rc8650_read_serial, where they would otherwise appear in front of query
 * replies.  Only bytes arriving during rc8650_read are treated this way, so
 * query replies pulled with rc8650_read_serial are never affected, whatever
 * they contain.  If you have enabled STM on the chip, set this; if you have
 * not, leave it alone and nothing is filtered.
 *
 * This only tells the library what to expect; sending the nG command that
 * actually enables the messages is up to you. */
void rc8650_set_status_messages (rc8650_t *e, int on);

/* --- output ------------------------------------------------------------- */

/* Render up to max_samples of unsigned 8-bit PCM, running the CPU as needed.
 * Returns the number of samples written, which is 0 once the chip has spoken
 * everything queued.  If done is non-NULL it is set to 1 when the engine has
 * gone idle with nothing left to say. */
size_t rc8650_read (rc8650_t *e, uint8_t *pcm, size_t max_samples, int *done);

/* As rc8650_read(), converted to signed 16-bit host-endian and passed through
 * the modeled output stage (see rc8650_set_lowpass_hz).  The 8-bit path above
 * stays raw, since reconstruction filtering needs more than 8 bits to be worth
 * doing. */
size_t rc8650_read_s16 (rc8650_t *e, int16_t *pcm, size_t max_samples,
			int *done);

/* Reconstruction low-pass corner, in Hz, for the s16 path.
 *
 * AO0/AO1 are unfiltered D/A outputs: the datasheet calls an external low-pass
 * "highly recommended" and its own reference circuit (Figure 7) is a 3 kHz
 * filter/amplifier, so the filter is part of what the chip sounds like in a
 * finished product rather than a effect added on top.  Without it you hear the
 * bare 10 kHz sample-and-hold staircase.
 *
 * Default RC8650_DEFAULT_LOWPASS_HZ.  0 selects the unfiltered staircase.
 * Anything else is clamped to 500..RC8650_MAX_LOWPASS_HZ - the ceiling is
 * below the 5008 Hz Nyquist frequency, above which the biquad is not stable. */
#define RC8650_DEFAULT_LOWPASS_HZ 3000
#define RC8650_MAX_LOWPASS_HZ     4800
void rc8650_set_lowpass_hz (rc8650_t *e, unsigned hz);
unsigned rc8650_get_lowpass_hz (rc8650_t *e);

/* Bytes the chip has sent back on its serial port: replies to query commands
 * such as 6? and 12?, and programming result codes.  Returns bytes copied.
 *
 * This one RUNS THE CPU if nothing is waiting - a reply has to be given time
 * to arrive - so it is not something to poll from an audio loop.  For index
 * markers, which arrive unbidden in the middle of speech, use the non-blocking
 * rc8650_read_index_marks() below. */
size_t rc8650_read_serial (rc8650_t *e, void *buf, size_t len);

/* --- index markers ------------------------------------------------------- */

/* Index markers (<CTRL+A>nI, Table 20) are non-speaking bookmarks placed in
 * the text.  When the chip has spoken the text up to one, it transmits the
 * marker number - as a one-byte binary value, not an ASCII number string.
 * That is how a caller follows where in the text the audio has got to.
 *
 * The library timestamps each marker with the D/A sample count at the instant
 * the chip transmitted it, which is what makes the markers usable for
 * synchronisation: compare sample_pos against rc8650_samples_read() to know
 * whether the audio a marker refers to has been handed over yet.
 *
 * Only useful with a caller that opts in, because capturing markers means
 * deciding that a byte is a marker rather than data - see
 * rc8650_set_index_marks.
 *
 * The RC8650 numbers markers 0..99, the RC8660 0..255; rc8650_max_index_mark
 * says which the loaded firmware does.  RC8650_MAX_INDEX_MARK is the RC8650's
 * and stays as it was. */
#define RC8650_MAX_INDEX_MARK 99
#define RC8660_MAX_INDEX_MARK 255

typedef struct rc8650_index_mark
{
  uint64_t sample_pos;		/* samples produced before the marker */
  uint32_t value;		/* marker number, 0..rc8650_max_index_mark() */
  uint32_t reserved;
} rc8650_index_mark;

/* Capture index markers.  Off by default; when on, a byte in the chip's
 * marker range (0..99 on the RC8650, 0..255 on the RC8660) that the chip
 * transmits while rc8650_read is pumping audio is taken to be a marker,
 * timestamped, and kept out of rc8650_read_serial's stream.
 *
 * The two conditions are what make that safe.  Restricting it to the audio
 * pump means a query reply, which is pulled with rc8650_read_serial, can never
 * be eaten as a marker however its bytes happen to fall.  Restricting it to
 * 0..99 leaves every Table 3 status byte alone.
 *
 * One caveat, and it is the caller's to handle: MARKERS 66 AND 69 DO NOT
 * SURVIVE rc8650_set_status_messages.  They are 'B' and 'E', the V8600-scale
 * start and stop messages, and since the caller may switch speed scales
 * between utterances the library recognises both scales' messages at all times
 * - so those two bytes are consumed as status before they ever reach the
 * marker test, whichever scale is in force.  Nothing else collides: the other
 * status bytes ('e', 'f', 's', 't', 'p', 'l') are all above 99.  Verified by
 * sending both numbers under either scale and getting no marker back.
 *
 * On the RC8660, whose markers run to 255, all six Table 3 messages fall
 * inside the range: with status messages on, markers 66, 69, 101, 102, 115
 * and 116 ('B', 'E', 'e', 'f', 's', 't') are consumed as status.  The standby
 * and baud-lock confirmations ('S', 'p', 'L', 'l') are sent whatever STM says,
 * but not while the chip is speaking, so they do not meet the marker test. */
void rc8650_set_index_marks (rc8650_t *e, int on);
unsigned rc8650_max_index_mark (rc8650_t *e);

/* Markers the chip has reached, oldest first.  Returns how many were copied.
 * Never runs the CPU: it drains what the last rc8650_read produced, so it is
 * safe to call after every chunk. */
size_t rc8650_read_index_marks (rc8650_t *e, rc8650_index_mark *marks,
				size_t max);

/* Samples handed to the caller by rc8650_read/rc8650_read_s16 since boot.
 * This is the clock marker positions are quoted against.  rc8650_stop drops
 * undelivered audio and advances this over the gap, so the two stay in step
 * across a cancel; nothing else moves it. */
uint64_t rc8650_samples_read (rc8650_t *e);

/* Non-zero while there is queued input or undelivered audio. */
int rc8650_is_speaking (rc8650_t *e);

/* --- the A/D converter --------------------------------------------------- */

/* The voltage on one of the chip's analog inputs, for its A/D converter (the
 * n$ command, ADC Control Register, Table 9).  value is in 256ths of AVREF -
 * what the chip's 8-bit conversion of that voltage would read.  All inputs
 * start at 0.
 *
 * The chip sends conversion results to the host on its serial port, one byte
 * per conversion, as Figure 16 shows: one byte for a one-shot conversion, one
 * per channel for a sweep, and back to back in continuous mode, at a tenth of
 * the baud rate, until the register is written with INH set.  Read them with
 * rc8650_read_serial.  If index markers are on, a reading of 0-99 that
 * arrives while rc8650_read is pumping audio is taken for a marker.
 *
 * Hardware triggering (TRG, the ADTRG pin) is not modelled: a conversion
 * starts as soon as the register is written with INH = 0. */
enum
{
  RC8650_AN0, RC8650_AN1, RC8650_AN2, RC8650_AN3,
  RC8650_AMPOUT			/* converted instead of ANn when AMP is set */
};
void rc8650_set_analog_input (rc8650_t *e, unsigned channel, uint8_t value);

/* --- misc --------------------------------------------------------------- */

/* Which chip the loaded firmware is for: 8650 or 8660, from the family byte
 * of its image header (0x04 or 0x05), or 0 if it is neither.  The RCStudio
 * images are five RC8650 v2.60 builds and one RC8660 v3.44, and the library
 * runs all of them; see "Firmware images" in README.md for what differs. */
unsigned rc8650_chip (rc8650_t *e);

/* Chip identification, as returned by the 6? command: 8 bytes into buf.
 * Returns 0 on success, -1 if the chip did not answer. */
int rc8650_chip_id (rc8650_t *e, uint8_t buf[8]);

const char *rc8650_version (void);

#ifdef __cplusplus
}
#endif

#endif /* RC8650_H */
