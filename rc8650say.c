/* SPDX-License-Identifier: GPL-3.0-or-later */
/* rc8650say --- speak text through the emulated RC8650.
 *
 *   rc8650say "Hello, world."          speak to the speakers
 *   rc8650say -o out.wav "Hello."      write a WAV instead
 *   echo hi | rc8650say                read the text from stdin
 *   rc8650say --raw "hi" > raw.u8      unsigned 8-bit PCM on stdout
 *   rc8650say --chip-id                query the chip (6?)
 *   rc8650say -c "5S" "Faster."        send a command first
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "rc8650.h"
#include "rcdict/rcdict.h"

#define DEFAULT_FIRMWARE "rc8650_m4_valid.srec"

/* A dictionary is a file the user edits, so say what is wrong with it rather
   than quietly dropping the line. */
static void
dict_complain (void *ctx, size_t off, const char *msg)
{
  (void) ctx;
  (void) off;
  fprintf (stderr, "rc8650say: %s\n", msg);
}

static void
usage (FILE *f)
{
  fprintf (f,
	   "usage: rc8650say [options] [text...]\n"
	   "\n"
	   "  -o FILE      write a WAV file instead of playing\n"
	   "  --raw        write unsigned 8-bit PCM to stdout\n"
	   "  -f FILE      firmware S-record (default: %s,\n"
	   "               or $RC8650_FIRMWARE)\n"
	   "  -c CMD       send <CTRL+A>CMD<CR> before speaking, e.g. -c 5S\n"
	   "               (repeatable; sent in order)\n"
	   "  -d FILE      load a pronunciation dictionary (repeatable)\n"
	   "  --phonemes   allow [[K AE T]] phoneme escapes in the text\n"
	   "  --chip-id    print the 6? chipset identification and exit\n"
	   "  -q           quiet: no progress on stderr\n"
	   "  -h, --help   this message\n"
	   "\n"
	   "With no text arguments the text is read from stdin.\n"
	   "Audio is unsigned 8-bit mono at %d Hz.\n", DEFAULT_FIRMWARE,
	   RC8650_SAMPLE_RATE);
}

/* --- WAV output ---------------------------------------------------------- */

static void
put_u32 (FILE *f, unsigned long v)
{
  fputc (v & 0xff, f);
  fputc ((v >> 8) & 0xff, f);
  fputc ((v >> 16) & 0xff, f);
  fputc ((v >> 24) & 0xff, f);
}

static void
put_u16 (FILE *f, unsigned v)
{
  fputc (v & 0xff, f);
  fputc ((v >> 8) & 0xff, f);
}

/* Canonical 8-bit mono PCM header.  Written with a placeholder length and
 * patched once the size is known, so we never have to buffer the audio. */
static void
wav_header (FILE *f, unsigned long nsamples, unsigned rate, unsigned bytes)
{
  fwrite ("RIFF", 1, 4, f);
  put_u32 (f, 36 + nsamples * bytes + (nsamples * bytes & 1));
  fwrite ("WAVEfmt ", 1, 8, f);
  put_u32 (f, 16);
  put_u16 (f, 1);		/* PCM */
  put_u16 (f, 1);		/* mono */
  put_u32 (f, rate);
  put_u32 (f, rate * bytes);	/* byte rate */
  put_u16 (f, bytes);		/* block align */
  put_u16 (f, 8 * bytes);	/* bits per sample */
  fwrite ("data", 1, 4, f);
  put_u32 (f, nsamples * bytes);
}

/* --- firmware discovery -------------------------------------------------- */

/* Look beside the executable and in the working directory, so the CLI works
 * from a build tree without configuration. */
static char *
find_firmware (const char *argv0)
{
  static char path[4096];
  const char *env = getenv ("RC8650_FIRMWARE");
  const char *slash;

  if (env && *env)
    {
      snprintf (path, sizeof path, "%s", env);
      return path;
    }
  if (access (DEFAULT_FIRMWARE, R_OK) == 0)
    {
      snprintf (path, sizeof path, "%s", DEFAULT_FIRMWARE);
      return path;
    }
  slash = argv0 ? strrchr (argv0, '/') : NULL;
  if (slash)
    {
      int dirlen = (int) (slash - argv0);
      snprintf (path, sizeof path, "%.*s/%s", dirlen, argv0,
		DEFAULT_FIRMWARE);
      if (access (path, R_OK) == 0)
	return path;
      snprintf (path, sizeof path, "%.*s/../%s", dirlen, argv0,
		DEFAULT_FIRMWARE);
      if (access (path, R_OK) == 0)
	return path;
    }
  return NULL;
}

/* --- playback ------------------------------------------------------------ */

/* Hand the WAV to the platform's own player.  That keeps the CLI free of any
 * audio-library dependency; an embedder wanting low latency should use
 * rc8650_read() directly rather than this. */
static int
play_file (const char *wav)
{
  const char *players[] = { "afplay", "aplay", "paplay", "play", NULL };
  int i;
  for (i = 0; players[i]; i++)
    {
      char cmd[4200];
      snprintf (cmd, sizeof cmd, "command -v %s >/dev/null 2>&1",
		players[i]);
      if (system (cmd) == 0)
	{
	  snprintf (cmd, sizeof cmd, "%s '%s' >/dev/null 2>&1", players[i],
		    wav);
	  return system (cmd) == 0 ? 0 : -1;
	}
    }
  fprintf (stderr,
	   "rc8650say: no audio player found (tried afplay, aplay, paplay,"
	   " play);\n            use -o FILE to write a WAV instead\n");
  return -1;
}

int
main (int argc, char **argv)
{
  const char *out_path = NULL, *fw = NULL;
  const char *dicts[8], *precmds[32];
  int ndicts = 0, nprecmds = 0, inline_phonemes = 0;
  rcdict *dict = NULL;
  int raw = 0, chip_id = 0, quiet = 0;
  int s16 = 0, order = 0;
  long out_rate = -1, dac_rate = -1, lowpass = -1;
  unsigned rate = RC8650_SAMPLE_RATE, bytes = 1;
  int16_t pcm[4096];
  char text[8192];
  size_t textlen = 0;
  char *err = NULL;
  rc8650_t *e;
  FILE *out = NULL;
  char tmpl[] = "/tmp/rc8650sayXXXXXX.wav";
  int playing = 0;
  unsigned long total = 0;
  uint8_t buf[4096];
  size_t n;
  int done = 0, i;

  for (i = 1; i < argc; i++)
    {
      if (!strcmp (argv[i], "-h") || !strcmp (argv[i], "--help"))
	{
	  usage (stdout);
	  return 0;
	}
      else if (!strcmp (argv[i], "-o") && i + 1 < argc)
	out_path = argv[++i];
      else if (!strcmp (argv[i], "-f") && i + 1 < argc)
	fw = argv[++i];
      else if (!strcmp (argv[i], "-c") && i + 1 < argc)
	{
	  if (nprecmds < (int) (sizeof precmds / sizeof precmds[0]))
	    precmds[nprecmds++] = argv[++i];
	  else
	    i++;
	}
      else if (!strcmp (argv[i], "-d") && i + 1 < argc)
	{
	  if (ndicts < (int) (sizeof dicts / sizeof dicts[0]))
	    dicts[ndicts++] = argv[++i];
	  else
	    i++;
	}
      else if (!strcmp (argv[i], "--phonemes"))
	inline_phonemes = 1;
      else if (!strcmp (argv[i], "--raw"))
	raw = 1;
      else if (!strcmp (argv[i], "--chip-id"))
	chip_id = 1;
      else if (!strcmp (argv[i], "--rate") && i + 1 < argc)
	out_rate = atol (argv[++i]), s16 = 1;
      else if (!strcmp (argv[i], "--dac-rate") && i + 1 < argc)
	dac_rate = atol (argv[++i]);
      else if (!strcmp (argv[i], "--lowpass") && i + 1 < argc)
	lowpass = atol (argv[++i]), s16 = 1;
      else if (!strcmp (argv[i], "--order") && i + 1 < argc)
	order = atoi (argv[++i]), s16 = 1;
      else if (!strcmp (argv[i], "--bookport"))
	{
	  out_rate = 48000, dac_rate = 10486, lowpass = 3600, order = 1;
	  s16 = 1;
	}
      else if (!strcmp (argv[i], "-q"))
	quiet = 1;
      else if (argv[i][0] == '-' && argv[i][1] && !out_path)
	{
	  fprintf (stderr, "rc8650say: unknown option '%s'\n", argv[i]);
	  usage (stderr);
	  return 2;
	}
      else
	{
	  size_t l = strlen (argv[i]);
	  if (textlen && textlen + 1 < sizeof text)
	    text[textlen++] = ' ';
	  if (textlen + l < sizeof text)
	    {
	      memcpy (text + textlen, argv[i], l);
	      textlen += l;
	    }
	}
    }
  text[textlen] = 0;

  if (!fw)
    fw = find_firmware (argv[0]);
  if (!fw)
    {
      fprintf (stderr,
	       "rc8650say: cannot find %s -- pass -f PATH or set "
	       "RC8650_FIRMWARE\n", DEFAULT_FIRMWARE);
      return 1;
    }

  if (!textlen && !chip_id && !isatty (0))
    textlen = fread (text, 1, sizeof text - 1, stdin);
  text[textlen] = 0;
  while (textlen && (text[textlen - 1] == '\n' || text[textlen - 1] == '\r'))
    text[--textlen] = 0;

  if (!textlen && !chip_id)
    {
      usage (stderr);
      return 2;
    }

  e = rc8650_new (fw, &err);
  if (!e)
    {
      fprintf (stderr, "rc8650say: %s\n", err ? err : "cannot start engine");
      free (err);
      return 1;
    }

  if (chip_id)
    {
      uint8_t id[8];
      int rc = rc8650_chip_id (e, id);
      if (rc == 0)
	{
	  printf ("chipset id :");
	  for (i = 0; i < 8; i++)
	    printf (" %02x", id[i]);
	  printf ("\n");
	  printf ("flash id   : %02x %02x\n", id[0], id[1]);
	  printf ("model      : %u  family: %u\n", id[2], id[3]);
	  printf ("BIOS       : %x.%02x\n", id[5], id[4]);
	  printf ("firmware   : %x.%02x\n", id[7], id[6]);
	}
      else
	fprintf (stderr, "rc8650say: chip did not answer 6?\n");
      rc8650_free (e);
      return rc == 0 ? 0 : 1;
    }

  if (raw)
    out = stdout;
  else if (out_path)
    {
      out = fopen (out_path, "wb");
      if (!out)
	{
	  fprintf (stderr, "rc8650say: cannot write '%s'\n", out_path);
	  rc8650_free (e);
	  return 1;
	}
    }
  else
    {
      int fd = mkstemps (tmpl, 4);
      if (fd < 0 || !(out = fdopen (fd, "wb")))
	{
	  fprintf (stderr, "rc8650say: cannot create a temporary file\n");
	  rc8650_free (e);
	  return 1;
	}
      out_path = tmpl;
      playing = 1;
    }

  if (s16)
    {
      if (order)
	rc8650_set_lowpass_order (e, (unsigned) order);
      if (out_rate >= 0)
	rc8650_set_output_rate (e, (unsigned) out_rate);
      if (dac_rate >= 0)
	rc8650_set_dac_rate (e, (unsigned) dac_rate);
      if (lowpass >= 0)
	rc8650_set_lowpass_hz (e, (unsigned) lowpass);
      rate = rc8650_get_output_rate (e);
      bytes = 2;
    }

  if (!raw)
    wav_header (out, 0, rate, bytes);	/* patched below */

  if (ndicts || inline_phonemes)
    {
      dict = rcdict_new (&rcdict_rc8650);
      for (i = 0; i < ndicts; i++)
	rcdict_add_file (dict, dicts[i], dict_complain, NULL);
      rc8650_set_dictionary (e, dict, inline_phonemes);
    }

  for (int i = 0; i < nprecmds; i++)
    rc8650_command (e, precmds[i]);
  rc8650_say (e, text);

  if (!quiet && !raw)
    fprintf (stderr, "rc8650say: synthesizing...\r");

  for (;;)
    {
      if (s16)
	{
	  size_t k;
	  n = rc8650_read_s16 (e, pcm, sizeof pcm / sizeof pcm[0], &done);
	  for (k = 0; k < n; k++)	/* little-endian whatever the host */
	    put_u16 (out, (uint16_t) pcm[k]);
	}
      else
	{
	  n = rc8650_read (e, buf, sizeof buf, &done);
	  fwrite (buf, 1, n, out);
	}
      if (n == 0)
	break;
      total += n;
      if (!quiet && !raw)
	fprintf (stderr, "rc8650say: synthesizing... %.2fs\r",
		 (double) total / rate);
    }

  if (!raw)
    {
      if (total * bytes & 1)	/* RIFF chunks are word aligned */
	fputc (0, out);
      fseek (out, 0, SEEK_SET);
      wav_header (out, total, rate, bytes);
    }
  if (out != stdout)
    fclose (out);

  if (!quiet && !raw)
    fprintf (stderr, "rc8650say: %.2f s of audio (%lu samples at %u Hz)\n",
	     (double) total / rate, total, rate);

  rc8650_free (e);
  rcdict_free (dict);

  if (playing)
    {
      int rc = play_file (out_path);
      remove (out_path);
      return rc == 0 ? 0 : 1;
    }
  return 0;
}
