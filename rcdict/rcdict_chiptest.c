/* SPDX-License-Identifier: BSD-3-Clause */
/* rcdict_chiptest --- does the expander's output actually sound the same?
 *
 * rcdict_test checks that the rewriting is what was intended.  This checks
 * that what was intended is right, by rendering both sides through the chip
 * and comparing the audio: for a word given the pronunciation the chip would
 * have chosen anyway, a substituted utterance must come back byte-identical to
 * the plain-text one.  That is the standard the absorption rules were derived
 * against (dict-lab/RESULTS.md), and the thing that would quietly regress if
 * someone "simplified" them.
 *
 * Needs librc8650 and a firmware image, so it is not part of the portable
 * module's own tests:
 *
 *   make -C librc8650 rcdict/rcdict_chiptest
 *   RC8650_FIRMWARE=rc8650_m4_valid.srec librc8650/rcdict/rcdict_chiptest
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Relative, because this test is librc8650's and not part of the portable
   module -- rcdict.c itself must never reach outside its own directory. */
#include "../rc8650.h"
#include "rcdict.h"

/* "computer", spelled the way the chip spells it itself. */
#define COMP "K AX M P YY UW DX ER"

struct pair
{
  const char *what;
  const char *with_span;
  const char *reference;
  int expect_identical;
};

static const struct pair pairs[] = {
  {"mid-sentence span",
   "the [[" COMP "]] is fast.",
   "the computer is fast.", 1},

  {"span before a period, article absorbed",
   "i bought a [[" COMP "]].",
   "i bought a computer.", 1},

  {"span before a period, mid-text",
   "i bought a [[" COMP "]]. it was fast.",
   "i bought a computer. it was fast.", 1},

  {"span before a comma",
   "the [[" COMP "]], and more.",
   "the computer, and more.", 1},

  {"span inside a question, not adjacent to the mark",
   "is the [[" COMP "]] fast?",
   "is the computer fast?", 1},

  {"span after \"the\", which is not absorbed",
   "the [[" COMP "]] today.",
   "the computer today.", 1},

  /* The known-lossy case, asserted as lossy so that it is noticed if it ever
     stops being: Table 5 has no pause phoneme for '?', so the rising terminal
     cannot be moved inside the span. */
  {"span immediately before a question mark (expected to differ)",
   "i bought a [[" COMP "]]?",
   "i bought a computer?", 0},
};

static unsigned long long
render (rc8650_t * e, const char *text, unsigned long *samples)
{
  unsigned long long h = 1469598103934665603ULL;	/* FNV-1a */
  int16_t pcm[4096];
  size_t n, i;

  rc8650_reset (e);
  rc8650_command (e, "1G");
  rc8650_set_status_messages (e, 1);
  rc8650_command (e, "5S");
  rc8650_write (e, text, strlen (text));
  rc8650_write (e, "\r", 1);

  *samples = 0;
  while ((n = rc8650_read_s16 (e, pcm, sizeof pcm / sizeof pcm[0], NULL)) > 0)
    {
      for (i = 0; i < n; i++)
	{
	  h ^= (unsigned long long) (unsigned short) pcm[i];
	  h *= 1099511628211ULL;
	}
      *samples += (unsigned long) n;
    }
  return h;
}

static void
complain (void *ctx, size_t off, const char *msg)
{
  int *n = ctx;
  (*n)++;
  (void) off;
  printf ("       %s\n", msg);
}

int
main (int argc, char **argv)
{
  const char *fw = getenv ("RC8650_FIRMWARE");
  const char *dictpath = getenv ("RCDICT_EXAMPLE");
  rc8650_t *e;
  char *err = NULL;
  rcdict_options opt;
  rcdict *dict;
  size_t k;
  int failures = 0, nerr = 0;

  if (argc > 1)
    fw = argv[1];
  if (!fw)
    fw = "rc8650_m4_valid.srec";
  if (!dictpath)
    dictpath = "rcdict/example.dict";

  rcdict_options_init (&opt, &rcdict_rc8650);
  opt.inline_phonemes = 1;

  /* The shipped example must parse without a single complaint, so that it
     cannot drift away from what the parser accepts. */
  dict = rcdict_new (&rcdict_rc8650);
  if (rcdict_add_file (dict, dictpath, complain, &nerr) <= 0 || nerr != 0)
    {
      failures++;
      printf ("FAIL %s: %d diagnostics, %lu rules\n", dictpath, nerr,
	      (unsigned long) rcdict_rule_count (dict));
    }
  else
    printf ("ok   %s parses cleanly (%lu rules)\n", dictpath,
	    (unsigned long) rcdict_rule_count (dict));
  rcdict_free (dict);

  e = rc8650_new (fw, &err);
  if (!e)
    {
      fprintf (stderr, "rcdict_chiptest: %s\n", err ? err : "no engine");
      return 1;
    }

  for (k = 0; k < sizeof pairs / sizeof pairs[0]; k++)
    {
      char expanded[1024];
      unsigned long ns = 0, nr = 0;
      unsigned long long hs, hr;
      int same;

      rcdict_expand (&opt, pairs[k].with_span, strlen (pairs[k].with_span),
		     expanded, sizeof expanded, NULL, NULL);

      hs = render (e, expanded, &ns);
      hr = render (e, pairs[k].reference, &nr);
      same = (hs == hr && ns == nr);

      if (same != pairs[k].expect_identical)
	{
	  failures++;
	  printf ("FAIL %s\n", pairs[k].what);
	}
      else
	printf ("ok   %s\n", pairs[k].what);
      printf ("       span %lu samples, text %lu samples, %s%s\n",
	      ns, nr, same ? "identical" : "differ",
	      pairs[k].expect_identical ? "" : " (expected)");
    }

  /* The same equivalence again, but reached through a dictionary rule rather
     than an inline escape: parse, match, template, absorption, the lot.  A
     word given the pronunciation the chip would have chosen anyway must leave
     the audio untouched. */
  {
    static const char *const src =
      "word computer = [K AX M P YY UW DX ER]\n";
    static const char *const cases[] = {
      "the computer is fast.",
      "i bought a computer.",
      "the computer, and more.",
      "is the computer fast?",
    };
    rcdict_options dopt;

    dict = rcdict_new (&rcdict_rc8650);
    nerr = 0;
    rcdict_add_text (dict, src, strlen (src), "inline", complain, &nerr);
    rcdict_options_init (&dopt, &rcdict_rc8650);
    dopt.dict = dict;

    for (k = 0; k < sizeof cases / sizeof cases[0]; k++)
      {
	char expanded[1024];
	unsigned long ns = 0, nr = 0;
	unsigned long long hs, hr;

	rcdict_expand (&dopt, cases[k], strlen (cases[k]), expanded,
		       sizeof expanded, NULL, NULL);
	hs = render (e, expanded, &ns);
	hr = render (e, cases[k], &nr);

	if (hs != hr || ns != nr)
	  {
	    failures++;
	    printf ("FAIL via dictionary rule: \"%s\"\n", cases[k]);
	  }
	else
	  printf ("ok   via dictionary rule: \"%s\"\n", cases[k]);
	printf ("       %lu samples both ways\n", ns);
      }
    rcdict_free (dict);
  }

  rc8650_free (e);
  printf ("%d failures\n", failures);
  return failures != 0;
}
