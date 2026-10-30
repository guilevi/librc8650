/* SPDX-License-Identifier: GPL-3.0-or-later */
/* librc8650 --- implementation.  See rc8650.h for the API contract.
 *
 * This wraps the patched gdb-14.2 m32c simulator core (mem.c, reg.c,
 * srcdest.c, misc.c, int.c and the generated r8c.c/m32c.c) with:
 *   - an S-record loader, so bfd is not needed,
 *   - ring buffers hooked into the core's UART and D/A taps,
 *   - a pump that advances the CPU only as far as the caller's audio demand,
 *   - idle detection, so callers know when an utterance is finished.
 */

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "rc8650.h"
#include "rcdict/rcdict.h"
#include "cpu.h"
#include "mem.h"

/* From the simulator core.  decode_opcode is a function pointer selected by
   m32c_set_cpu(); cpu.h declares it, along with the CPU_* constants. */
extern void update_timer_b2 (void);
extern void m32c_set_cpu (int cpu);
extern void mem_put_blk (int address, const void *bufptr, int nbytes);
extern int m32c_baremetal, m32c_rc865x, m32c_p8_or, m32c_extflash_armed;
extern int (*rc865x_hook_rx) (unsigned char *);
extern void (*rc865x_hook_tx) (unsigned char);
extern void (*rc865x_hook_dac) (unsigned char);
extern int trace, verbose, enable_counting, m32c_p6_driven;

/* Instruction budgets.  These are generous ceilings, not expected costs: the
 * engine normally leaves each loop early on a real signal from the chip.
 * BOOT_CAP covers the BIOS's calibrated delay loops, THINK_CAP the gap
 * between swallowing text and the first sample (letter-to-sound translation
 * and dictionary lookup), and QUIET_INSNS is how much silence with the DMA
 * stopped counts as end-of-utterance.
 *
 * THINK_CAP is also what bounds the one case where the chip never answers at
 * all: text it decides not to speak.  Feed it a bare CR or a single space and
 * no D/A write ever happens, so the pump runs the full budget before
 * concluding there is nothing to say - the caller sees that as a dead stop.
 * The old 400M made that a 38-second freeze, which for a screen reader
 * driving this library is worse than any wrong answer.
 *
 * 8M is measured, not guessed.  Time-to-first-sample was sampled across the
 * inputs most likely to make the translator work: dictionary-hostile proper
 * names, a 45-letter unbroken pseudo-word, runs of bare consonants, mixed
 * case, digits and symbols, and a full 1.5 KB buffer of text.  The worst was
 * 42 ms, about 445k instructions; the rest were under 25 ms.  8M leaves ~18x
 * headroom over that worst case and caps the silent-input stall at under a
 * second.
 *
 * QUIET_INSNS is now only a guard against a stuck TS pin, not the way
 * utterances end.  It is safe in that role because once speech is under way
 * the D/A is written every 206 instructions without exception - measured
 * across sixty utterances covering every voice, both speed scales, all sixteen
 * punctuation modes, maximum word delay and reverb, comma-heavy and
 * sentence-heavy text: the longest gap between two samples anywhere was 206
 * instructions.  There is no such thing as a pause in the middle of speech.
 *
 * Quiet was never the right thing to END on, though, because the chip can go
 * quiet for a long time BEFORE it is finished starting: it emits a short burst
 * - 232 samples in the case that exposed this - and then spends up to 149k
 * instructions finishing its letter-to-sound work before the body arrives.
 * Any threshold small enough to be responsive is smaller than that, so an
 * utterance gets declared over during its own opening pause, and its speech
 * turns up glued to the front of the next one.
 *
 * What ends an utterance now is TS0, the chip's talk-status output - see
 * talk_status() and step_and_track().  It is exact at both ends, it stays low
 * across that opening burst, and it costs the caller nothing.  The Table 3
 * status messages are still recognised (see rc8650_set_status_messages) but
 * only so they can be kept out of the reply stream; they no longer decide when
 * output has stopped. */
#define BOOT_CAP    400000000UL
#define THINK_CAP     8000000UL
#define QUIET_INSNS    100000UL
/* How much audio an utterance must have produced before silence is allowed to
   end it, in samples.

   Neither of the rules below may act on a handful of samples, because a handful
   is what turns up when they are not this utterance's at all: the chip goes on
   writing for a moment after a Stop, so a caller that cancels and immediately
   writes the next utterance - a screen reader, all day - starts that utterance
   with the tail of the last one still trickling out.  Counted as "output has
   started", the think that follows reads as output that has stopped, and the
   utterance is declared over before it says anything.

   The chip's own opening burst is 231-387 samples, so 512 is above anything
   incidental and far below the shortest real utterance measured (1728 samples,
   for the single letter "a").  Under it, THINK_CAP is the backstop, which is
   what covers text the chip declines to speak. */
#define HEARD_ENOUGH      512UL

/* How long rc8650_read_serial keeps the CPU running for a reply that may still
 * be draining after the audio side has gone idle.  See rc8650_read_serial. */
#define SERIAL_GRACE   100000UL

/* How long rc8650_stop runs the CPU to get the Stop actually delivered.  A
 * stop is over in a few thousand instructions; this is a ceiling. */
#define STOP_CAP      2000000UL

/* Table 3.  Which pair the chip uses depends on POR bit 7 (V86), which the
 * caller may be changing per utterance to pick a speed scale, so accept all
 * four rather than tracking which scale is in force. */
#define MSG_STARTED_V86  's'
#define MSG_STOPPED_V86  't'
#define MSG_STARTED_V8600 'B'
#define MSG_STOPPED_V8600 'E'
/* The other two Table 3 messages.  Nothing here acts on them, but they are
 * status rather than data and would otherwise turn up in the middle of a
 * caller's index-marker stream.  V86=1 only; the V8600 scale has no
 * equivalent. */
#define MSG_BUF_EMPTY    'e'
#define MSG_BUF_FULL     'f'

/* Queues.  Input starts at IN_CAP and grows on demand, because rc8650_write
 * promises to take all of len: text never comes near it (the chip's own
 * buffer is 2 KB), but tone-generator and recorded-audio data are streams the
 * chip consumes at its own pace, and a second of PCM is already over 10 KB.
 * Dropping the overflow would truncate them without a word.  The others are
 * bounded: audio can outrun the caller, so give it room for a couple of
 * seconds. */
#define IN_CAP  8192
#define SER_CAP 1024
#define PCM_CAP 32768
/* Index markers only accumulate between two reads, and the caller drains them
 * every chunk; even one marker per word could not fill this. */
#define MARK_CAP 64

struct rc8650
{
  unsigned char *in;		/* grows; see in_put */
  size_t in_cap, in_head, in_tail;

  unsigned char ser[SER_CAP];
  size_t ser_head, ser_tail;

  unsigned char pcm[PCM_CAP];
  size_t pcm_head, pcm_tail;

  rc8650_index_mark mark[MARK_CAP];
  size_t mark_head, mark_tail;

  uint64_t samples_out;		/* samples the D/A has produced */
  uint64_t samples_read;	/* samples handed to the caller */

  unsigned long since_sample;	/* instructions since the last D/A write */
  unsigned long thinking;	/* instructions since input was handed over */
  int work;			/* something queued that has not been spoken */
  int started;			/* TS has been seen asserted for this work */
  unsigned long heard;		/* samples produced for this work */
  int booted;

  int status_msgs;		/* caller has enabled STM; trust Table 3 */
  int talking;			/* a start message has arrived, no stop yet */
  int audio_pump;		/* inside rc8650_read, so tx bytes are status */
  int index_marks;		/* caller wants nI markers captured */

  rcdict_options dict;		/* pronunciation rules; profile always set */

  unsigned char *image;		/* decoded firmware, kept for reset */
  size_t image_len;
  unsigned char *image_srec;
  size_t image_srec_len;

  unsigned lowpass_hz;		/* 0 = bypass */
  double b0, b1, b2, a1, a2;	/* biquad coefficients */
  double x1, x2, y1, y2;	/* biquad state */
};

/* The core is full of file-scope state, so one engine per process. */
static rc8650_t *the_engine = NULL;

/* --- the output stage ---------------------------------------------------- */

/* Headroom before the biquad.  The D/A's excursion is not symmetric about
 * midscale (a spoken sentence measures 0..218 against a 128 idle level), so
 * (v - 128) << 8 already touches -32768 at the negative peak; a low-pass with
 * any ringing at all would clip there.  Backing off a little costs a fraction
 * of a dB and leaves room for the overshoot. */
#define OUT_GAIN 0.85

static void
biquad_reset (rc8650_t *e)
{
  e->x1 = e->x2 = e->y1 = e->y2 = 0.0;
}

/* Second-order Butterworth low-pass (RBJ cookbook, Q = 1/sqrt(2)) at the
 * D/A's own sample rate. */
static void
biquad_design (rc8650_t *e, unsigned hz)
{
  double w0, cw, sw, alpha, a0;

  if (!hz)
    {
      e->lowpass_hz = 0;
      biquad_reset (e);
      return;
    }
  if (hz < 500)
    hz = 500;
  if (hz > RC8650_MAX_LOWPASS_HZ)
    hz = RC8650_MAX_LOWPASS_HZ;

  w0 = 2.0 * 3.14159265358979323846 * hz / RC8650_SAMPLE_RATE;
  cw = cos (w0);
  sw = sin (w0);
  alpha = sw / (2.0 * 0.70710678118654752440);

  a0 = 1.0 + alpha;
  e->b0 = ((1.0 - cw) / 2.0) / a0;
  e->b1 = (1.0 - cw) / a0;
  e->b2 = e->b0;
  e->a1 = (-2.0 * cw) / a0;
  e->a2 = (1.0 - alpha) / a0;

  e->lowpass_hz = hz;
  biquad_reset (e);
}

/* One raw D/A sample (unsigned, midscale 128) to a signed 16-bit sample. */
static int16_t
out_sample (rc8650_t *e, unsigned char raw)
{
  double x = (raw - 128) * 256.0 * OUT_GAIN, y;

  if (e->lowpass_hz)
    {
      y = e->b0 * x + e->b1 * e->x1 + e->b2 * e->x2
	- e->a1 * e->y1 - e->a2 * e->y2;
      e->x2 = e->x1;
      e->x1 = x;
      e->y2 = e->y1;
      e->y1 = y;
    }
  else
    y = x;

  if (y > 32767.0)
    y = 32767.0;
  else if (y < -32768.0)
    y = -32768.0;
  return (int16_t) y;
}

void
rc8650_set_lowpass_hz (rc8650_t *e, unsigned hz)
{
  if (e)
    biquad_design (e, hz);
}

unsigned
rc8650_get_lowpass_hz (rc8650_t *e)
{
  return e ? e->lowpass_hz : 0;
}

/* --- status messages ----------------------------------------------------- */

void
rc8650_set_status_messages (rc8650_t *e, int on)
{
  if (!e)
    return;
  e->status_msgs = on ? 1 : 0;
  if (!on)
    e->talking = 0;
}

/* --- index markers ------------------------------------------------------- */

void
rc8650_set_index_marks (rc8650_t *e, int on)
{
  if (!e)
    return;
  e->index_marks = on ? 1 : 0;
  if (!on)
    e->mark_head = e->mark_tail = 0;
}

static void
mark_put (rc8650_t *e, unsigned char value)
{
  size_t next = (e->mark_head + 1) % MARK_CAP;
  if (next == e->mark_tail)
    return;			/* full: drop, rather than block the CPU */
  e->mark[e->mark_head].sample_pos = e->samples_out;
  e->mark[e->mark_head].value = value;
  e->mark[e->mark_head].reserved = 0;
  e->mark_head = next;
}

size_t
rc8650_read_index_marks (rc8650_t *e, rc8650_index_mark *marks, size_t max)
{
  size_t n = 0;

  if (!e || !marks)
    return 0;
  /* Deliberately does not step the CPU, unlike rc8650_read_serial.  A caller
     polls this between audio chunks; running the chip on here would render
     ahead of the audio the caller is pacing itself against, and with the pump
     flag down (see hook_tx) any marker produced would be filed as reply data
     rather than recognised. */
  while (n < max && e->mark_tail != e->mark_head)
    {
      marks[n++] = e->mark[e->mark_tail];
      e->mark_tail = (e->mark_tail + 1) % MARK_CAP;
    }
  return n;
}

uint64_t
rc8650_samples_read (rc8650_t *e)
{
  return e ? e->samples_read : 0;
}

/* --- ring helpers -------------------------------------------------------- */

#define RING_EMPTY(e, n) ((e)->n##_head == (e)->n##_tail)

/* Returns 1 if the byte was stored, 0 if the ring was full. */
static int
ring_put (unsigned char *buf, size_t cap, size_t *head, size_t tail,
	  unsigned char v)
{
  size_t next = (*head + 1) % cap;
  if (next == tail)
    return 0;			/* full: drop, rather than block the CPU */
  buf[*head] = v;
  *head = next;
  return 1;
}

static size_t
ring_get (const unsigned char *buf, size_t cap, size_t head, size_t *tail,
	  unsigned char *out, size_t max)
{
  size_t n = 0;
  while (n < max && *tail != head)
    {
      out[n++] = buf[*tail];
      *tail = (*tail + 1) % cap;
    }
  return n;
}

/* Queue one byte of input, doubling the ring when it is full.  Returns 1 if
 * stored, 0 only if memory ran out. */
static int
in_put (rc8650_t *e, unsigned char v)
{
  if ((e->in_head + 1) % e->in_cap == e->in_tail)
    {
      size_t cap = e->in_cap * 2, n = 0;
      unsigned char *in = malloc (cap);
      if (!in)
	return 0;
      while (e->in_tail != e->in_head)
	{
	  in[n++] = e->in[e->in_tail];
	  e->in_tail = (e->in_tail + 1) % e->in_cap;
	}
      free (e->in);
      e->in = in;
      e->in_cap = cap;
      e->in_tail = 0;
      e->in_head = n;
    }
  return ring_put (e->in, e->in_cap, &e->in_head, e->in_tail, v);
}

/* --- hooks called from the emulator core --------------------------------- */

static int
hook_rx (unsigned char *b)
{
  rc8650_t *e = the_engine;
  if (!e || RING_EMPTY (e, in))
    return 0;			/* nothing queued: not EOF, just idle */
  *b = e->in[e->in_tail];
  e->in_tail = (e->in_tail + 1) % e->in_cap;
  return 1;
}

static void
hook_tx (unsigned char b)
{
  rc8650_t *e = the_engine;
  if (!e)
    return;

  /* Status messages, when the caller has enabled them, are control signalling
     rather than data: they say when output starts and stops, which is what
     ends an utterance here.  Consume them - leaving them in the reply stream
     would put two stray bytes in front of every query.

     Only while pumping audio, though.  A query reply is pulled by
     rc8650_read_serial, and one of its bytes could easily happen to equal 's'
     or 'E'; restricting the interpretation to the audio path means a reply can
     never be mistaken for a status message, and status can never be mistaken
     for a reply. */
  if (e->status_msgs && e->audio_pump)
    switch (b)
      {
      case MSG_STARTED_V86:
      case MSG_STARTED_V8600:
	e->talking = 1;
	return;
      case MSG_STOPPED_V86:
      case MSG_STOPPED_V8600:
	/* TS0 ends the utterance now (see step_and_track), so this no longer
	   clears e->work - it only closes out e->talking.  The byte is still
	   consumed, which is the part that matters here: it would otherwise
	   sit in front of the next query reply. */
	e->talking = 0;
	return;
      case MSG_BUF_EMPTY:
      case MSG_BUF_FULL:
	return;
      default:
	break;
      }

  /* An index marker (Table 20): "the RC8650 transmits the marker number to the
     host via the TXD pin.  Note that this value is a binary number between 0
     and 99, not a literal ASCII number string as was used in the command to
     place the marker."  Nothing else the chip sends unbidden while it is
     speaking falls in that range, so during the audio pump a byte of 0..99 is
     a marker - and it is timestamped here, at the instruction that wrote it to
     U0TB, which is the moment the chip has spoken the text up to it.

     The same two conditions as above keep this from misreading data: a query
     reply is pulled by rc8650_read_serial with the pump flag down, and the
     range test leaves the Table 3 bytes to the switch above.  Markers 66 and
     69 are the exception - 'B' and 'E' are consumed by the switch whichever
     speed scale is in force - and are the caller's to avoid; see
     rc8650_set_index_marks.

     Measured: with a marker in front of each of five short sentences, every
     marker arrived in the silence between the previous sentence's last sample
     and its own first one - up to 137 ms ahead of the word it marks, never
     behind it. */
  if (e->index_marks && e->audio_pump && b <= RC8650_MAX_INDEX_MARK)
    {
      mark_put (e, b);
      return;
    }

  ring_put (e->ser, SER_CAP, &e->ser_head, e->ser_tail, b);
}

static void
hook_dac (unsigned char v)
{
  rc8650_t *e = the_engine;
  if (!e)
    return;
  /* Only a stored sample is counted.  samples_out is the clock index markers
     are timestamped against and samples_read chases it one delivery at a time,
     so a sample counted here but dropped by a full ring would leave every
     later marker permanently one sample out of reach. */
  if (ring_put (e->pcm, PCM_CAP, &e->pcm_head, e->pcm_tail, v))
    e->samples_out++;
  e->since_sample = 0;
  /* Audio is flowing, so this work item is alive whatever the pins say - that
     keeps THINK_CAP from expiring mid-utterance if TS is ever unavailable. */
  if (e->heard < HEARD_ENOUGH)
    e->heard++;
  e->thinking = 0;
}

/* --- S-record loading ---------------------------------------------------- */

static int
hexval (int c)
{
  if (c >= '0' && c <= '9')
    return c - '0';
  if (c >= 'a' && c <= 'f')
    return c - 'a' + 10;
  if (c >= 'A' && c <= 'F')
    return c - 'A' + 10;
  return -1;
}

static int
hexbyte (const char *p)
{
  int hi = hexval (p[0]), lo = hexval (p[1]);
  return (hi < 0 || lo < 0) ? -1 : (hi << 4) | lo;
}

/* Parse S1/S2/S3 records straight into simulator memory.  Returns 0 on
 * success, -1 on a malformed image. */
static int
load_srec (const char *text, size_t len)
{
  size_t i = 0;
  int loaded = 0;

  while (i < len)
    {
      size_t start = i, end;
      int type, count, addr_bytes, j, b;
      unsigned int addr = 0;
      unsigned char data[256];
      int ndata;

      while (end = i, i < len && text[i] != '\n' && text[i] != '\r')
	i++;
      while (i < len && (text[i] == '\n' || text[i] == '\r'))
	i++;
      end = i;
      while (end > start
	     && (text[end - 1] == '\n' || text[end - 1] == '\r'))
	end--;
      if (end - start < 4 || text[start] != 'S')
	continue;

      type = text[start + 1];
      if (type < '1' || type > '3')
	continue;		/* S0 header, S7/8/9 start address: skip */
      addr_bytes = type - '0' + 1;

      count = hexbyte (text + start + 2);
      if (count < 0)
	return -1;

      for (j = 0; j < addr_bytes; j++)
	{
	  b = hexbyte (text + start + 4 + 2 * j);
	  if (b < 0)
	    return -1;
	  addr = (addr << 8) | (unsigned) b;
	}

      ndata = count - addr_bytes - 1;	/* minus address, minus checksum */
      if (ndata < 0 || (size_t) ndata > sizeof data)
	return -1;
      if (start + 4 + 2 * (size_t) (addr_bytes + ndata) > end)
	return -1;

      for (j = 0; j < ndata; j++)
	{
	  b = hexbyte (text + start + 4 + 2 * (addr_bytes + j));
	  if (b < 0)
	    return -1;
	  data[j] = (unsigned char) b;
	}

      if (ndata)
	{
	  mem_put_blk ((int) addr, data, ndata);
	  loaded = 1;
	}
    }
  return loaded ? 0 : -1;
}

static void step (rc8650_t *e);

/* --- chip state ---------------------------------------------------------- */

/* DMA0 enable (DM0CON bit 3) is the firmware's own "playback in progress"
 * signal: it programs the channel when an utterance starts and disables it
 * when the sample ring has drained. */
static int
dma_active (void)
{
  return (mem_get_qi (0x2c) & 0x08) != 0;
}

/* TS0, the chip's own talk-status output.  The datasheet describes the pin as
 * "TALK STATUS: Indicates whether a voice channel is active", and says of the
 * tone generator's Play command that "the TS0 pin and TS flag are asserted at
 * this time, enabling the host to synchronize to the playing of the tone data.
 * TS becomes inactive after all of the data has been played."  Synchronising
 * to output is what the pin is for.
 *
 * On this firmware it is P9 bit 2.  RC Systems document the module pin, not
 * which M16C port drives it, so that mapping is established here rather than
 * quoted: the TS Pin Control command (nK, Table 16) drives this bit and only
 * this bit exactly as documented - 1K idles it low and raises it while
 * speaking, 3K forces it high, 2K forces it low, and 0K inverts the automatic
 * behaviour.  It is an output (PD9 bit 2 is set by the firmware at boot).
 *
 * Measured against the sample stream it is exact: high from the first sample
 * of an utterance through the last, with no dropouts in between, across
 * speech, the sinusoidal generator and the DTMF dialer. */
#define P9_ADDR 0x3f1
#define P9_TS   0x04

static int
talk_status (void)
{
  return (mem_get_qi (P9_ADDR) & P9_TS) != 0;
}

/* CTS# is P6_0 (0x03EC), driven low when the chip can accept data.  Waiting
 * for it is a precise "boot finished" signal, far better than a fixed delay. */
static int
chip_ready (void)
{
  return m32c_p6_driven && (mem_get_qi (0x3ec) & 0x01) == 0;
}

/* --- boot ---------------------------------------------------------------- */

static void
set_err (char **err, const char *msg)
{
  if (err)
    {
      *err = malloc (strlen (msg) + 1);
      if (*err)
	strcpy (*err, msg);
    }
}

static int
boot (rc8650_t *e, char **err)
{
  unsigned int reset;

  m32c_set_cpu (CPU_M16C);	/* the -m m16c mode of the standalone sim */

  /* The board configuration established in notes.md: bare-metal memory (no
   * newlib syscall traps), the RC865x peripheral set, and port 8 bit 4 tied
   * high for the companion-chip handshake. */
  m32c_baremetal = 1;
  m32c_rc865x = 1;
  m32c_p8_or = 0x10;
  trace = verbose = enable_counting = 0;

  m32c_extflash_armed = 0;
  if (load_srec ((const char *) e->image_srec, e->image_srec_len) != 0)
    {
      set_err (err, "firmware image contains no usable S-records");
      return -1;
    }
  m32c_extflash_armed = 1;	/* flash writes are command cycles from now on */

  /* Start where the reset vector points, exactly as the S-record path in the
   * standalone simulator does. */
  reset = mem_get_psi (0xffffc) & 0xfffff;
  if (reset == 0 || reset == 0xfffff)
    {
      set_err (err, "firmware image has no reset vector at 0xFFFFC");
      return -1;
    }
  put_reg (pc, reset);
  e->booted = 1;
  e->since_sample = 0;
  e->thinking = 0;
  e->work = e->started = e->talking = e->heard = 0;
  e->mark_head = e->mark_tail = 0;
  e->samples_out = e->samples_read = 0;

  /* Run the BIOS and firmware init through to the point where the chip
   * asserts CTS#, so callers get a device that is ready to be spoken to. */
  {
    unsigned long budget = BOOT_CAP;
    while (budget-- && !chip_ready ())
      step (e);
    if (!chip_ready ())
      {
	set_err (err, "firmware did not finish booting (CTS# never asserted)");
	e->booted = 0;
	return -1;
      }
  }
  return 0;
}

/* --- lifecycle ----------------------------------------------------------- */

rc8650_t *
rc8650_new_from_memory (const void *srec, size_t len, char **err)
{
  rc8650_t *e;

  if (the_engine)
    {
      set_err (err, "librc8650 supports one engine per process "
	       "(the emulator core keeps global state)");
      return NULL;
    }
  if (!srec || !len)
    {
      set_err (err, "no firmware image supplied");
      return NULL;
    }

  e = calloc (1, sizeof *e);
  if (!e)
    {
      set_err (err, "out of memory");
      return NULL;
    }
  e->image_srec = malloc (len);
  if (!e->image_srec)
    {
      free (e);
      set_err (err, "out of memory");
      return NULL;
    }
  memcpy (e->image_srec, srec, len);
  e->image_srec_len = len;
  e->in = malloc (IN_CAP);
  if (!e->in)
    {
      free (e->image_srec);
      free (e);
      set_err (err, "out of memory");
      return NULL;
    }
  e->in_cap = IN_CAP;
  biquad_design (e, RC8650_DEFAULT_LOWPASS_HZ);
  rcdict_options_init (&e->dict, &rcdict_rc8650);

  the_engine = e;
  rc865x_hook_rx = hook_rx;
  rc865x_hook_tx = hook_tx;
  rc865x_hook_dac = hook_dac;

  if (boot (e, err) != 0)
    {
      rc8650_free (e);
      return NULL;
    }
  return e;
}

rc8650_t *
rc8650_new (const char *srec_path, char **err)
{
  FILE *f;
  long size;
  char *buf;
  rc8650_t *e;
  size_t got;

  if (!srec_path)
    {
      set_err (err, "no firmware path supplied");
      return NULL;
    }
  f = fopen (srec_path, "rb");
  if (!f)
    {
      char msg[512];
      snprintf (msg, sizeof msg, "cannot open firmware '%s'", srec_path);
      set_err (err, msg);
      return NULL;
    }
  if (fseek (f, 0, SEEK_END) != 0 || (size = ftell (f)) <= 0)
    {
      fclose (f);
      set_err (err, "cannot determine firmware size");
      return NULL;
    }
  rewind (f);
  buf = malloc ((size_t) size);
  if (!buf)
    {
      fclose (f);
      set_err (err, "out of memory");
      return NULL;
    }
  got = fread (buf, 1, (size_t) size, f);
  fclose (f);

  e = rc8650_new_from_memory (buf, got, err);
  free (buf);
  return e;
}

void
rc8650_free (rc8650_t *e)
{
  if (!e)
    return;
  if (the_engine == e)
    {
      rc865x_hook_rx = NULL;
      rc865x_hook_tx = NULL;
      rc865x_hook_dac = NULL;
      the_engine = NULL;
    }
  free (e->in);
  free (e->image_srec);
  free (e->image);
  free (e);
}

void
rc8650_reset (rc8650_t *e)
{
  if (!e)
    return;
  e->in_head = e->in_tail = 0;
  e->ser_head = e->ser_tail = 0;
  e->pcm_head = e->pcm_tail = 0;
  biquad_reset (e);
  boot (e, NULL);
}

/* --- input --------------------------------------------------------------- */

void
rc8650_write (rc8650_t *e, const void *data, size_t len)
{
  const unsigned char *p = data;
  size_t i;
  if (!e || !p)
    return;
  for (i = 0; i < len; i++)
    if (!in_put (e, p[i]))
      break;			/* out of memory: nothing better to do */
  e->work = 1;
  e->started = e->heard = 0;
  e->thinking = 0;
}

/* --- pronunciation dictionary ---------------------------------------------
 *
 * The rules live in rcdict/, which knows nothing about this library; all that
 * happens here is that rc8650_say runs its text through them.  See rcdict.h
 * for the file format, and dict-lab/RESULTS.md for why the substitutions are
 * shaped the way they are.
 */

void
rc8650_set_dictionary (rc8650_t *e, const rcdict *d, int inline_phonemes)
{
  if (!e)
    return;
  e->dict.dict = d;		/* borrowed: the caller keeps ownership */
  e->dict.inline_phonemes = inline_phonemes ? 1 : 0;
}

size_t
rc8650_expand (rc8650_t *e, const char *in, size_t inlen,
	       char *out, size_t outcap)
{
  if (!e || !in)
    return 0;
  return rcdict_expand (&e->dict, in, inlen, out, outcap, NULL, NULL);
}

void
rc8650_say (rc8650_t *e, const char *text)
{
  size_t len, need;
  char stackbuf[1024], *buf = NULL;

  if (!e || !text)
    return;
  len = strlen (text);

  /* No dictionary and no escape means nothing to do, which is the common
     case and stays allocation-free. */
  if (!e->dict.dict && !e->dict.inline_phonemes)
    {
      rc8650_write (e, text, len);
      rc8650_write (e, "\r", 1);	/* nothing is spoken until CR or NUL */
      return;
    }

  need = rcdict_expand (&e->dict, text, len, NULL, 0, NULL, NULL);
  buf = (need < sizeof stackbuf) ? stackbuf : malloc (need + 1);
  if (!buf)
    {				/* speak it unexpanded rather than not at all */
      rc8650_write (e, text, len);
      rc8650_write (e, "\r", 1);
      return;
    }
  rcdict_expand (&e->dict, text, len, buf, need + 1, NULL, NULL);
  rc8650_write (e, buf, need);
  rc8650_write (e, "\r", 1);
  if (buf != stackbuf)
    free (buf);
}

void
rc8650_command (rc8650_t *e, const char *cmd)
{
  unsigned char lead = RC8650_CTRL_A;
  if (!e || !cmd)
    return;
  rc8650_write (e, &lead, 1);
  rc8650_write (e, cmd, strlen (cmd));
  rc8650_write (e, "\r", 1);
}

void
rc8650_stop (rc8650_t *e)
{
  unsigned char ctrl_x = 0x18;
  unsigned long budget;

  if (!e)
    return;

  /* Drop what the host queued but the chip has not collected yet, then hand
     over the chip's own Stop. */
  e->in_head = e->in_tail = 0;
  in_put (e, ctrl_x);

  /* Deliver it, here and now.  Queuing the byte is not enough: the CPU only
     advances inside a read, and a caller that cancels goes on to write the
     NEXT utterance before it reads anything.  The stop would then still be
     sitting in the queue in front of that text, and two separate things go
     wrong when the pump finally runs.

     The chip is still playing the old utterance, so the new text is written
     while the DMA is up; end-of-utterance detection latches onto that and then
     ends the "utterance" the moment the stop takes effect - before the new
     text has produced a sample.  And with status messages on, the stop the
     chip reports for the cancelled utterance is the first one the new
     utterance sees, which ends it just as dead.  Either way the text is gone,
     and it surfaces glued to the front of whatever is spoken next.

     So run the CPU until the chip has taken the byte and gone quiet.  It costs
     a few thousand instructions and it makes cancel mean what it says. */
  if (e->booted)
    {
      budget = STOP_CAP;
      while (budget-- && (!RING_EMPTY (e, in) || dma_active ()))
	step (e);
      /* Let the stop message out, so it cannot be mistaken for the end of the
         next utterance.  hook_tx swallows it: audio_pump is what marks these
         bytes as status rather than reply data. */
      if (e->status_msgs)
	{
	  budget = SERIAL_GRACE;
	  e->audio_pump = 1;
	  while (budget-- && e->talking)
	    step (e);
	  e->audio_pump = 0;
	}
    }

  e->work = e->started = e->talking = e->heard = 0;
  e->since_sample = e->thinking = 0;
  /* The audio being dropped here was counted as produced, and the markers
     pointing into it are now meaningless.  Drop them and close the gap, so
     samples_read stays a position in the same stream that later markers are
     timestamped against instead of trailing it forever by whatever a cancel
     happened to throw away. */
  e->mark_head = e->mark_tail = 0;
  e->samples_read = e->samples_out;
  e->pcm_head = e->pcm_tail = 0;
  /* Whatever the filter was ringing on has just been dropped; carrying its
     state into the next utterance would start it with a click. */
  biquad_reset (e);
}

/* --- the pump ------------------------------------------------------------ */

/* Advance the CPU one instruction, keeping the peripherals in step.  This is
 * the body of the standalone simulator's main loop, minus the tracing. */
static void
step (rc8650_t *e)
{
  decode_opcode ();
  update_timer_b2 ();
  e->since_sample++;
  e->thinking++;
}

/* Advance one instruction and re-evaluate whether the chip still owes us
 * anything.  Work finishes either when playback has run and then stopped, or
 * when the chip swallowed the input without ever starting to speak (a query
 * command, or text that produced nothing). */
static void
step_and_track (rc8650_t *e)
{
  step (e);

  /* TS0 decides this now.  It is what the chip itself uses to tell a host when
     output starts and stops, it needs no caller opt-in, and unlike the Table 3
     status messages it also covers the tone, DTMF and recorded-audio paths,
     which report no status at all.  It is also the only signal that gets the
     opening burst right: the chip emits a couple of samples and then spends up
     to 149k instructions on letter-to-sound before real speech begins, and TS
     stays low across that, where a quiet timeout cannot tell it from the end.

     The previous STM/Table 3 path is kept below, disabled.  hook_tx still
     consumes the status bytes when the caller has enabled them - that is not
     end-of-utterance logic, it is keeping two stray bytes out of the reply
     stream - it just no longer drives e->work.

  if (e->status_msgs)
    {
      if (dma_active ())
	{
	  e->started = 1;
	  e->thinking = 0;
	}
      else if (!e->talking && e->thinking > THINK_CAP)
	e->work = 0;
      return;
    }
  */

  if (talk_status ())
    {
      /* TS has just risen.  Whatever since_sample counted up to this moment
         was the chip *thinking*, not its output stalling, so it must not be
         carried into the quiet rule below - which is about output that has
         stopped coming.

         This is what used to lose an utterance outright.  The chip emits a
         couple of hundred samples with TS still low, spends up to 149k
         instructions on letter-to-sound, and only then raises TS.  When that
         think took longer than QUIET_INSNS - measured at 109,623 instructions
         the first time a given command set is parsed - since_sample was
         already over the threshold on the very first step with TS high, so the
         rule below fired immediately and ended the utterance at the exact
         moment the chip announced it was about to speak.  The caller got the
         233-sample opening burst and nothing else, and the text still sitting
         in the input ring surfaced glued to the front of whatever was spoken
         next.

         Reproducible from a cold boot, and worst wherever the parse is
         slowest: the first utterance after boot, the first one carrying a
         command the chip has not been given before, and the one after a Stop. */
      if (!e->started)
	e->since_sample = 0;
      e->started = 1;
      /* Only once audio has actually been produced does TS being asserted mean
         "still talking".  Before that it is just a pin that happens to be
         high, and treating it as liveness would let anything holding it there
         - the Forced High mode of the nK command, say - stall the pump
         indefinitely.  Leaving THINK_CAP running until the first sample keeps
         that case bounded. */
      if (e->heard >= HEARD_ENOUGH)
	{
	  e->thinking = 0;
	  /* Stuck asserted with nothing coming out.  The musical tone
	     generator has been seen to leave TS high after its Quit frame, and
	     a forced-high pin never falls at all.  This costs nothing during
	     real output, where the D/A is written every 206 instructions
	     without exception. */
	  if (e->since_sample > QUIET_INSNS)
	    e->work = 0;
	  return;
	}
    }
  else if (e->started && e->heard >= HEARD_ENOUGH)
    {
      /* Asserted, then released: the utterance is over, exactly.

         Only once a sample has come out, though.  TS belongs to the chip, not
         to the current call, and it can still be high from the utterance
         before: a caller that cancels part-way and immediately writes the next
         one - which is what a screen reader does all day - can start that
         utterance with the pin still asserted.  Without this guard the pump
         took that stale high as "this utterance has started", the fall that
         followed as "and now it has finished", and returned zero samples for
         text the chip went on to speak into the next read.

         e->heard is exactly the right test because rc8650_write clears it, so
         it means "a sample has been produced since the caller last wrote". */
      e->work = 0;
      return;
    }

  if (RING_EMPTY (e, in) && e->thinking > THINK_CAP)
    e->work = 0;
}

static size_t
pcm_available (rc8650_t *e)
{
  return (e->pcm_head + PCM_CAP - e->pcm_tail) % PCM_CAP;
}

size_t
rc8650_read (rc8650_t *e, uint8_t *pcm, size_t max_samples, int *done)
{
  size_t n;

  if (done)
    *done = 0;
  if (!e || !pcm || !max_samples || !e->booted)
    {
      if (done)
	*done = 1;
      return 0;
    }

  /* Run until we can satisfy the request, or the chip finishes.
   *
   * The early break is what keeps the tail of an utterance playable.  Ending
   * an utterance can only be *concluded*, never observed: it takes QUIET_INSNS
   * of silence to tell "finished" from "pausing between phrases", and the last
   * chunk is by definition a short one.  Without the break, the audio already
   * sitting in the ring stays there for the whole of that quiet period -
   * measured at 210 ms against 25 ms for every other chunk of the same
   * utterance - and a caller streaming to an audio device runs dry and plays a
   * gap just before the final few samples.
   *
   * DMA0 going inactive is the firmware's own signal that its sample ring has
   * drained, so at that moment everything it has produced is already in ours:
   * returning it costs nothing and waiting cannot add to it.  The caller gets
   * a short read, which the contract has always permitted, and the quiet
   * period is then waited out on the *next* call - by which time the audio is
   * playing rather than queued behind it. */
  e->audio_pump = 1;		/* tx bytes are status messages, not replies */
  while (pcm_available (e) < max_samples && e->work)
    {
      step_and_track (e);
      if (e->started && !dma_active () && pcm_available (e) > 0)
	break;
    }
  e->audio_pump = 0;

  n = ring_get (e->pcm, PCM_CAP, e->pcm_head, &e->pcm_tail, pcm,
		max_samples);
  e->samples_read += n;

  if (done && n == 0 && !e->work)
    *done = 1;
  return n;
}

size_t
rc8650_read_s16 (rc8650_t *e, int16_t *pcm, size_t max_samples, int *done)
{
  uint8_t tmp[1024];
  size_t total = 0;
  int d = 0;

  /* tmp is a conversion window, not a buffering policy: this loop exists to
     convert in slices, and must not turn rc8650_read's short read back into a
     blocking one by going round again to top the caller's buffer up.  Doing
     that was worth 200 ms of dead air at the end of every utterance - the
     short read is precisely the signal that nothing more is ready yet. */
  while (total < max_samples)
    {
      size_t want = max_samples - total;
      size_t n, i;

      if (want > sizeof tmp)
	want = sizeof tmp;
      n = rc8650_read (e, tmp, want, &d);
      for (i = 0; i < n; i++)
	pcm[total + i] = out_sample (e, tmp[i]);
      total += n;
      if (n < want)
	break;
    }
  if (done)
    *done = d;
  return total;
}

size_t
rc8650_read_serial (rc8650_t *e, void *buf, size_t len)
{
  if (!e || !buf || !len)
    return 0;
  /* Give the CPU a chance to answer a freshly queued query.
   *
   * e->work alone is the wrong condition to run on: it tracks *audio*, and a
   * reply keeps trickling out of the UART after the chip has finished making
   * any.  A 12? interrogation is 23 bytes that arrive one every ~25
   * instructions, starting ~1400 after the command is queued; stopping the
   * moment work clears truncates it, and the caller cannot tell a short reply
   * from a finished one.  That was survivable only while work happened to
   * outlast the reply, which is not something the audio path should be
   * responsible for guaranteeing.
   *
   * So keep stepping while there is work OR while a small grace budget lasts.
   * SERIAL_GRACE is ~9 ms, thousands of times the observed inter-byte gap and
   * six times the wait for the first byte, and it bounds what a caller polling
   * a chip that has nothing to say can lose. */
  if (RING_EMPTY (e, ser))
    {
      unsigned long budget = THINK_CAP, grace = SERIAL_GRACE;
      while (budget-- && RING_EMPTY (e, ser) && (e->work || grace--))
	step_and_track (e);
    }
  return ring_get (e->ser, SER_CAP, e->ser_head, &e->ser_tail, buf, len);
}

int
rc8650_is_speaking (rc8650_t *e)
{
  if (!e)
    return 0;
  return e->work || pcm_available (e) > 0;
}

int
rc8650_chip_id (rc8650_t *e, uint8_t buf[8])
{
  size_t n;
  if (!e || !buf)
    return -1;
  rc8650_command (e, "6?");
  n = rc8650_read_serial (e, buf, 8);
  while (n < 8)
    {
      size_t more = rc8650_read_serial (e, buf + n, 8 - n);
      if (!more)
	break;
      n += more;
    }
  return n == 8 ? 0 : -1;
}

unsigned
rc8650_sample_rate (void)
{
  return RC8650_SAMPLE_RATE;
}

const char *
rc8650_version (void)
{
  return "librc8650 0.1 (RC8650 firmware on an emulated Renesas M16C)";
}
