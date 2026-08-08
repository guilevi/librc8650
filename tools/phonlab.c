/* SPDX-License-Identifier: GPL-3.0-or-later */
/* phonlab --- a bench for the user-dictionary work.
 *
 * Two jobs, both of which rc8650say deliberately does not do:
 *
 *   1. Speak text containing arbitrary control bytes, so a mid-sentence
 *      <CTRL+A>D ... <CTRL+A>T phoneme span can be rendered and A/B'd against
 *      the same sentence in text mode.  Escapes (\xHH, \r, \n, \t, \\) are
 *      decoded from the argument, so the switches can be written on a shell
 *      command line without quoting games.
 *
 *   2. Dump the letter-to-sound stage's own output.  The translator does not
 *      emit bare phonemes; it emits a phoneme string with inline control codes
 *      into a buffer at 0x1036 (emitter 0x0A1BF6, limit 0x1098), which the
 *      synthesizer later copies to 0x10BC and consumes.  Watching the writes to
 *      that buffer is how you see what the chip actually decided to say -- the
 *      thing a dictionary author needs before they can correct anything.
 *
 * The dump rides on the simulator core's existing write-watch (m32c_watch_lo /
 * m32c_watch_hi in sim/m32c/mem.c), which logs to stderr.  stderr is captured
 * around the render and parsed back.  That is a scaffold, not the shipping
 * mechanism: a real rc8650_read_phonemes() wants a write hook in the core so
 * nothing has to go through a text format.  It costs no change to the sim,
 * which is what makes it the right thing to start with.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>

#include "rc8650.h"

/* sim/m32c/mem.c owns these; main.c sets them from $M32C_WATCH, and librc8650
 * does not link main.c, so the library's callers get to set them directly. */
extern int m32c_watch_lo, m32c_watch_hi;

#define PHON_BUF_LO 0x1034	/* 0x1034/0x1035 look like the emitter's cursor */
#define PHON_BUF_HI 0x1098	/* the limit named in the emitter at 0x0A1BF6 */

#define MAX_WRITES 8192

struct wr
{
  unsigned addr, val, pc;
};

/* --- text escapes -------------------------------------------------------- */

/* isxdigit without dragging in locale behaviour on the escape path */
static int
isxdigit_ (int c)
{
  return (c >= '0' && c <= '9') || ((c | 0x20) >= 'a' && (c | 0x20) <= 'f');
}

static size_t
unescape (const char *in, char *out, size_t cap)
{
  size_t n = 0;
  while (*in && n + 1 < cap)
    {
      if (*in != '\\')
	{
	  out[n++] = *in++;
	  continue;
	}
      in++;
      switch (*in)
	{
	case 'x':
	  {
	    int v = 0, d = 0;
	    in++;
	    while (d < 2 && isxdigit_ (*in))
	      {
		int c = *in;
		v = v * 16 + (c <= '9' ? c - '0' : (c | 0x20) - 'a' + 10);
		in++;
		d++;
	      }
	    out[n++] = (char) v;
	    break;
	  }
	case 'r':
	  out[n++] = '\r';
	  in++;
	  break;
	case 'n':
	  out[n++] = '\n';
	  in++;
	  break;
	case 't':
	  out[n++] = '\t';
	  in++;
	  break;
	case '0':
	  out[n++] = '\0';
	  in++;
	  break;
	case '\\':
	  out[n++] = '\\';
	  in++;
	  break;
	default:
	  out[n++] = '\\';
	  break;
	}
    }
  out[n] = 0;
  return n;
}

/* --- WAV ----------------------------------------------------------------- */

static void
put32 (FILE * f, unsigned long v)
{
  fputc (v & 255, f);
  fputc ((v >> 8) & 255, f);
  fputc ((v >> 16) & 255, f);
  fputc ((v >> 24) & 255, f);
}

static void
put16 (FILE * f, unsigned v)
{
  fputc (v & 255, f);
  fputc ((v >> 8) & 255, f);
}

static void
wav_header (FILE * f, unsigned long samples)
{
  unsigned long data = samples * 2;
  fwrite ("RIFF", 1, 4, f);
  put32 (f, 36 + data);
  fwrite ("WAVEfmt ", 1, 8, f);
  put32 (f, 16);
  put16 (f, 1);			/* PCM */
  put16 (f, 1);			/* mono */
  put32 (f, RC8650_SAMPLE_RATE);
  put32 (f, RC8650_SAMPLE_RATE * 2);
  put16 (f, 2);			/* block align */
  put16 (f, 16);		/* bits */
  fwrite ("data", 1, 4, f);
  put32 (f, data);
}

/* --- phoneme-buffer decode ----------------------------------------------- */

/* Controls carry one operand byte (notes.md §12): 0x73 's' rate, 0x70 'p'
 * pitch, 0x76 'v' volume, 0x74 't' tone, 0x5B/0x5D stress.  0x2F '/' and 0x5C
 * '\' are inflection markers.  Everything below 42 is a phoneme code -- 42 is
 * the stride of the transition table at 0xB36A7 (table[prev*42 + cur]). */
static const char *
ctlname (unsigned v)
{
  switch (v)
    {
    case 0x73:
      return "rate";
    case 0x70:
      return "pitch";
    case 0x76:
      return "vol";
    case 0x74:
      return "tone";
    case 0x5b:
      return "stress[";
    case 0x5d:
      return "stress]";
    case 0x2f:
      return "rise";
    case 0x5c:
      return "fall";
    }
  return NULL;
}

static void
decode_string (const unsigned char *s, int n)
{
  int i = 0;
  while (i < n)
    {
      unsigned v = s[i];
      const char *name = ctlname (v);
      if (v == 0x2f || v == 0x5c)
	{
	  printf (" %s", name);
	  i++;
	}
      else if (name && i + 1 < n)
	{
	  printf (" %s=%u", name, s[i + 1]);
	  i += 2;
	}
      else if (v < 42)
	{
	  /* run-length the silence, which is how pauses are spelled */
	  int j = i;
	  while (j < n && s[j] == v)
	    j++;
	  if (v == 0 && j - i > 1)
	    printf (" sil*%d", j - i);
	  else if (j - i > 1)
	    printf (" p%02u*%d", v, j - i);
	  else
	    printf (" p%02u", v);
	  i = j;
	}
      else
	{
	  printf (" ?%02x", v);
	  i++;
	}
    }
  printf ("\n");
}

static void
report_writes (struct wr *w, int n, int verbose)
{
  unsigned char buf[PHON_BUF_HI - PHON_BUF_LO + 2];
  int i, len = 0, group = 0;
  unsigned prev = 0;

  for (i = 0; i < n; i++)
    {
      if (w[i].addr < 0x1036)	/* the cursor bytes, not the string */
	continue;
      if (len && w[i].addr <= prev)
	{
	  printf ("  [%d] len=%d :", group++, len);
	  for (int k = 0; k < len; k++)
	    printf (" %02x", buf[k]);
	  printf ("\n       decode:");
	  decode_string (buf, len);
	  len = 0;
	}
      if (len < (int) sizeof buf)
	buf[len++] = (unsigned char) w[i].val;
      prev = w[i].addr;
      if (verbose)
	fprintf (stderr, "    wr %06x = %02x  pc=%06x\n", w[i].addr, w[i].val,
		 w[i].pc);
    }
  if (len)
    {
      printf ("  [%d] len=%d :", group, len);
      for (int k = 0; k < len; k++)
	printf (" %02x", buf[k]);
      printf ("\n       decode:");
      decode_string (buf, len);
    }
}

/* --- main ---------------------------------------------------------------- */

static void
usage (void)
{
  fprintf (stderr,
	   "usage: phonlab [options] TEXT\n"
	   "  -o FILE     write a 16-bit WAV\n"
	   "  -f FILE     firmware S-record (default $RC8650_FIRMWARE)\n"
	   "  -c CMD      send <CTRL+A>CMD<CR> first (repeatable)\n"
	   "  --stm       set STM (1G) and tell the library, as a speaking\n"
	   "              caller should; makes the end of the utterance exact\n"
	   "  --dump      dump the letter-to-sound phoneme buffer\n"
	   "  --raw-dump  also print every write to it\n"
	   "TEXT understands \\xHH, \\r, \\n, \\t, \\0 and \\\\.\n");
}

int
main (int argc, char **argv)
{
  const char *out_path = NULL, *fw = getenv ("RC8650_FIRMWARE");
  const char *precmd[8];
  int nprecmd = 0, dump = 0, rawdump = 0, stm = 0, i;
  char text[8192], raw[8192];
  size_t textlen = 0;
  rc8650_t *e;
  char *err = NULL;
  FILE *out = NULL;
  unsigned long total = 0;
  int done;
  int16_t pcm[4096];
  size_t n;
  struct wr *writes = NULL;
  int nwrites = 0;
  int saved_err = -1;
  FILE *cap = NULL;
  struct timespec t0, t1;

  raw[0] = 0;
  for (i = 1; i < argc; i++)
    {
      if (!strcmp (argv[i], "-o") && i + 1 < argc)
	out_path = argv[++i];
      else if (!strcmp (argv[i], "-f") && i + 1 < argc)
	fw = argv[++i];
      else if (!strcmp (argv[i], "-c") && i + 1 < argc && nprecmd < 8)
	precmd[nprecmd++] = argv[++i];
      else if (!strcmp (argv[i], "--dump"))
	dump = 1;
      else if (!strcmp (argv[i], "--raw-dump"))
	dump = rawdump = 1;
      else if (!strcmp (argv[i], "--stm"))
	stm = 1;
      else if (!strcmp (argv[i], "-h") || !strcmp (argv[i], "--help"))
	{
	  usage ();
	  return 0;
	}
      else
	{
	  if (raw[0])
	    strncat (raw, " ", sizeof raw - strlen (raw) - 1);
	  strncat (raw, argv[i], sizeof raw - strlen (raw) - 1);
	}
    }
  if (!raw[0])
    {
      usage ();
      return 2;
    }
  if (!fw)
    fw = "rc8650_m4_valid.srec";
  textlen = unescape (raw, text, sizeof text);

  e = rc8650_new (fw, &err);
  if (!e)
    {
      fprintf (stderr, "phonlab: %s\n", err ? err : "cannot start engine");
      return 1;
    }

  if (out_path)
    {
      out = fopen (out_path, "wb");
      if (!out)
	{
	  fprintf (stderr, "phonlab: cannot write '%s'\n", out_path);
	  return 1;
	}
      wav_header (out, 0);
    }

  if (stm)
    {
      rc8650_command (e, "1G");
      rc8650_set_status_messages (e, 1);
    }
  for (i = 0; i < nprecmd; i++)
    rc8650_command (e, precmd[i]);

  /* The watch has to go on after the boot and any setup commands, or the
     dump is full of whatever the firmware does on its way up. */
  if (dump)
    {
      cap = tmpfile ();
      if (cap)
	{
	  fflush (stderr);
	  saved_err = dup (2);
	  dup2 (fileno (cap), 2);
	  m32c_watch_lo = PHON_BUF_LO;
	  m32c_watch_hi = PHON_BUF_HI;
	}
    }

  rc8650_write (e, text, textlen);
  rc8650_write (e, "\r", 1);

  clock_gettime (CLOCK_MONOTONIC, &t0);
  while ((n = rc8650_read_s16 (e, pcm, sizeof pcm / sizeof pcm[0], &done)) > 0)
    {
      if (out)
	fwrite (pcm, 2, n, out);
      total += n;
    }
  clock_gettime (CLOCK_MONOTONIC, &t1);

  if (dump && cap)
    {
      char line[256];
      m32c_watch_lo = 0;
      m32c_watch_hi = -1;
      fflush (stderr);
      dup2 (saved_err, 2);
      close (saved_err);
      rewind (cap);
      writes = calloc (MAX_WRITES, sizeof *writes);
      while (writes && nwrites < MAX_WRITES && fgets (line, sizeof line, cap))
	{
	  unsigned a, v, pc;
	  if (sscanf (line, "WR %x = %x from pc=%x", &a, &v, &pc) == 3)
	    {
	      writes[nwrites].addr = a;
	      writes[nwrites].val = v;
	      writes[nwrites].pc = pc;
	      nwrites++;
	    }
	}
      fclose (cap);
    }

  if (out)
    {
      fseek (out, 0, SEEK_SET);
      wav_header (out, total);
      fclose (out);
    }

  printf ("samples: %lu  (%.3f s at %d Hz)   render %.0f ms\n", total,
	  (double) total / RC8650_SAMPLE_RATE, RC8650_SAMPLE_RATE,
	  (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6);
  if (dump)
    {
      printf ("phoneme buffer: %d writes in [%04x,%04x]\n", nwrites,
	      PHON_BUF_LO, PHON_BUF_HI);
      if (writes)
	report_writes (writes, nwrites, rawdump);
      free (writes);
    }

  rc8650_free (e);
  return 0;
}
