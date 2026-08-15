/* SPDX-License-Identifier: BSD-3-Clause */
/* rcdict_test --- unit tests for the expander.
 *
 * These check the rewriting only.  That the rewriting is the *right*
 * rewriting is a separate question, answered by measurement against the chip
 * in dict-lab/ and re-checked end to end by rcdict_chiptest.
 *
 *   cc -I. -o rcdict_test rcdict_test.c rcdict.c && ./rcdict_test
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "rcdict.h"

static int failures, checks;

/* Render control bytes visibly, so a diff is readable.  Rotates between
   buffers so that several calls in one printf do not all show the last one. */
static const char *
show (const char *s, size_t n)
{
  static char bufs[3][512];
  static int which;
  char *buf = bufs[which = (which + 1) % 3];
  size_t i, j = 0;
  for (i = 0; i < n && j + 5 < sizeof bufs[0]; i++)
    {
      unsigned char c = (unsigned char) s[i];
      if (c == 0x01)
	{
	  memcpy (buf + j, "<A>", 3);
	  j += 3;
	}
      else if (c < 0x20 || c > 0x7e)
	j += (size_t) snprintf (buf + j, sizeof bufs[0] - j, "<%02x>", c);
      else
	buf[j++] = (char) c;
    }
  buf[j] = 0;
  return buf;
}

static void
diag (void *ctx, size_t off, const char *msg)
{
  int *n = ctx;
  (*n)++;
  (void) off;
  (void) msg;
}

/* Build a dictionary from source text, counting the diagnostics it produced. */
static rcdict *
mkdict (const char *src, int *nerr)
{
  rcdict *d = rcdict_new (&rcdict_rc8650);
  *nerr = 0;
  rcdict_add_text (d, src, strlen (src), "test.dict", diag, nerr);
  return d;
}

static void
check (const char *what, const rcdict_options *o,
       const char *in, const char *want, int want_diags)
{
  char got[512];
  size_t need;
  int ndiag = 0;

  checks++;
  need = rcdict_expand (o, in, strlen (in), got, sizeof got, diag, &ndiag);

  if (need != strlen (want) || strcmp (got, want) != 0)
    {
      failures++;
      printf ("FAIL %s\n  in   %s\n  want %s\n  got  %s\n", what,
	      show (in, strlen (in)), show (want, strlen (want)),
	      show (got, strlen (got)));
      return;
    }
  if (want_diags >= 0 && ndiag != want_diags)
    {
      failures++;
      printf ("FAIL %s: expected %d diagnostics, got %d\n", what,
	      want_diags, ndiag);
      return;
    }
  /* The sizing call must agree with the real one. */
  if (rcdict_expand (o, in, strlen (in), NULL, 0, NULL, NULL) != need)
    {
      failures++;
      printf ("FAIL %s: sizing call disagrees\n", what);
    }
}

int
main (void)
{
  rcdict_options off, on;

  rcdict_options_init (&off, &rcdict_rc8650);
  rcdict_options_init (&on, &rcdict_rc8650);
  on.inline_phonemes = 1;

  /* --- the escape is off by default, because "[[" is wiki link syntax --- */
  check ("escape off by default", &off,
	 "see [[Wikipedia]] for more",
	 "see [[Wikipedia]] for more", -1);

  /* --- the basic substitution --- */
  check ("plain text untouched", &on, "the computer is fast.",
	 "the computer is fast.", 0);
  check ("simple span", &on,
	 "the [[K AX M P YY UW DX ER]] is fast.",
	 "the \x01" "D K AX M P YY UW DX ER \x01" "T is fast.", 0);
  check ("lowercase accepted", &on,
	 "the [[k ax m]] is fast.",
	 "the \x01" "D k ax m \x01" "T is fast.", 0);
  check ("empty span emits nothing but the switches", &on,
	 "a[[]]b", "a\x01" "D \x01" "Tb", 0);

  /* --- right edge: '.' and ',' move inside, measured exact --- */
  check ("period absorbed", &on,
	 "i bought a [[K AX M]].",
	 "i bought \x01" "D AX K AX M . \x01" "T", 0);
  check ("comma absorbed", &on,
	 "the [[K AX M]], and more",
	 "the \x01" "D K AX M , \x01" "T and more", 0);
  check ("period absorbed across whitespace", &on,
	 "the [[K AX M]]  .",
	 "the \x01" "D K AX M . \x01" "T", 0);
  check ("period mid-text absorbed, following sentence intact", &on,
	 "i bought a [[K AX M]]. it was fast.",
	 "i bought \x01" "D AX K AX M . \x01" "T it was fast.", 0);

  /* --- right edge: the punctuation with no Table 5 phoneme --- */
  check ("question mark reported, not absorbed", &on,
	 "the [[K AX M]]?",
	 "the \x01" "D K AX M \x01" "T?", 1);
  check ("exclamation reported", &on,
	 "the [[K AX M]]!",
	 "the \x01" "D K AX M \x01" "T!", 1);

  /* --- left edge: only the article "a" --- */
  check ("article absorbed", &on,
	 "i saw a [[K AX M]] today",
	 "i saw \x01" "D AX K AX M \x01" "T today", 0);
  check ("\"an\" is not absorbed", &on,
	 "i saw an [[K AX M]] today",
	 "i saw an \x01" "D K AX M \x01" "T today", 0);
  check ("\"the\" is not absorbed", &on,
	 "i saw the [[K AX M]] today",
	 "i saw the \x01" "D K AX M \x01" "T today", 0);
  check ("article at the very start", &on,
	 "a [[K AX M]] today",
	 "\x01" "D AX K AX M \x01" "T today", 0);
  check ("no whitespace means no article", &on,
	 "sea[[K AX M]]",
	 "sea\x01" "D K AX M \x01" "T", 0);
  check ("both edges at once", &on,
	 "i bought a [[K AX M]].",
	 "i bought \x01" "D AX K AX M . \x01" "T", 0);

  /* --- command atoms are opaque --- */
  check ("index marker preserved before a span", &on,
	 "the \x01" "1I[[K AX M]] is fast.",
	 "the \x01" "1I\x01" "D K AX M \x01" "T is fast.", 0);
  check ("a marker blocks article absorption", &on,
	 "a \x01" "1I[[K AX M]]",
	 "a \x01" "1I\x01" "D K AX M \x01" "T", 0);
  check ("a span may not cross a command", &on,
	 "[[K AX \x01" "1I M]]",
	 "[[K AX \x01" "1I M]]", 1);
  check ("commands elsewhere pass through", &on,
	 "\x01" "5S\x01" "3P text \x01" "1I more",
	 "\x01" "5S\x01" "3P text \x01" "1I more", 0);
  check ("doubled command char is literal", &on,
	 "a \x01\x01 b", "a \x01\x01 b", 0);

  /* --- utterance boundaries --- */
  check ("a span may not cross a CR", &on,
	 "[[K AX\rM]]", "[[K AX\rM]]", 1);
  check ("CR passes through", &on, "one\rtwo", "one\rtwo", 0);

  /* --- Zap: after it the chip speaks commands instead of obeying them --- */
  check ("no mode switch is emitted under Zap", &on,
	 "\x01" "Z the [[K AX M]] is fast.",
	 "\x01" "Z the [[K AX M]] is fast.", 0);
  check ("CTRL+^ restores it", &on,
	 "\x01" "Z one \x1e" "the [[K AX M]]",
	 "\x01" "Z one \x1e" "the \x01" "D K AX M \x01" "T", 0);

  /* --- a changed command character is followed --- */
  check ("command character change is tracked", &on,
	 "\x01\x04" "\x04" "1I the [[K AX M]]",
	 "\x01\x04" "\x04" "1I the \x01" "D K AX M \x01" "T", 0);

  /* --- failing loudly --- */
  check ("unknown symbol falls back to text", &on,
	 "the [[K AX BOGUS]] is fast.",
	 "the K AX BOGUS is fast.", 1);
  check ("unterminated escape is passed through", &on,
	 "the [[K AX M is fast.",
	 "the [[K AX M is fast.", 1);

  /* --- Table 6 modifiers attach to phonemes, they are not separate words --- */
  check ("modifiers accepted inline", &on,
	 "[[70H AW -/D>/EH R]]",
	 "\x01" "D 70H AW -/D>/EH R \x01" "T", 0);
  check ("pause symbols accepted inside", &on,
	 "[[K AX M , R]]",
	 "\x01" "D K AX M , R \x01" "T", 0);

  /* ================= the dictionary ================= */
  {
    rcdict_options d;
    rcdict *dict;
    int nerr;

    /* --- parsing --- */
    dict = mkdict ("#!rcdict 1\n"
		   "; a comment line\n"
		   "\n"
		   "word  NVDA  = [EH N V IY DX AY]\n"
		   "word  Sean  = Shon\n"
		   "text  Mbps  = megabits per second\n", &nerr);
    checks++;
    if (rcdict_rule_count (dict) != 3 || nerr != 0)
      {
	failures++;
	printf ("FAIL parse: %lu rules, %d errors\n",
		(unsigned long) rcdict_rule_count (dict), nerr);
      }
    rcdict_options_init (&d, &rcdict_rc8650);
    d.dict = dict;

    check ("word rule with phonemes", &d,
	   "NVDA is good",
	   "\x01" "D EH N V IY DX AY \x01" "T is good", 0);
    check ("word rule respelling, no phonemes at all", &d,
	   "hello Sean", "hello Shon", 0);
    check ("case-insensitive by default", &d,
	   "nvda and NvDa",
	   "\x01" "D EH N V IY DX AY \x01" "T and "
	   "\x01" "D EH N V IY DX AY \x01" "T", 0);
    check ("word rules need whole words", &d,
	   "NVDAX and XNVDA", "NVDAX and XNVDA", 0);
    check ("text rules match inside words", &d,
	   "xMbpsx", "xmegabits per secondx", 0);
    check ("absorption still applies through a rule", &d,
	   "i saw a NVDA.",
	   "i saw \x01" "D AX EH N V IY DX AY . \x01" "T", 0);
    check ("no match, nothing changes", &d, "plain text", "plain text", 0);
    rcdict_free (dict);

    /* --- first match wins, in load order.  This is the datasheet's own trap
       for its exception dictionaries, where (RAT) placed before (RATING) means
       (RATING) is never reached, and it is inherited here along with the
       first-match-wins rule. --- */
    dict = mkdict ("text RAT    = [R AE T]\n"
		   "text RATING = [R EY T IH NG]\n", &nerr);
    d.dict = dict;
    check ("loose rule first swallows the specific one", &d,
	   "RATING", "\x01" "D R AE T \x01" "TING", 0);
    rcdict_free (dict);

    dict = mkdict ("text RATING = [R EY T IH NG]\n"
		   "text RAT    = [R AE T]\n", &nerr);
    d.dict = dict;
    check ("specific first is what works", &d,
	   "RATING", "\x01" "D R EY T IH NG \x01" "T", 0);
    rcdict_free (dict);

    /* word does not have the problem in the first place, which is the reason
       to reach for it before text. */
    dict = mkdict ("word RAT    = [R AE T]\n"
		   "word RATING = [R EY T IH NG]\n", &nerr);
    d.dict = dict;
    check ("word matching is immune to the ordering trap", &d,
	   "RATING", "\x01" "D R EY T IH NG \x01" "T", 0);
    rcdict_free (dict);

    /* --- case flags --- */
    dict = mkdict ("word:C US = [Y UW EH S]\n"
		   "word:c iOS = [AY OW EH S]\n", &nerr);
    d.dict = dict;
    check ("caps-only matches capitals", &d,
	   "the US today", "the \x01" "D Y UW EH S \x01" "T today", 0);
    check ("caps-only leaves lowercase alone", &d,
	   "between us", "between us", 0);
    check ("caps-only leaves title case alone", &d,
	   "Us and them", "Us and them", 0);
    check ("case-sensitive matches exactly", &d,
	   "on iOS", "on \x01" "D AY OW EH S \x01" "T", 0);
    check ("case-sensitive rejects other casings", &d,
	   "on IOS and ios", "on IOS and ios", 0);
    rcdict_free (dict);

    /* --- file-level default --- */
    dict = mkdict ("#!case sensitive\n" "word Sean = Shon\n", &nerr);
    d.dict = dict;
    check ("#!case sensitive applies to later rules", &d,
	   "Sean and sean", "Shon and sean", 0);
    rcdict_free (dict);

    /* --- templates --- */
    dict = mkdict ("word ASAP  = {2S}[EY EH S EY P IY]{5S}\n"
		   "word Dr     = [D AA K T ER] \\0\n"
		   "word silent = \n"
		   "word eq     = a \\= b\n", &nerr);
    d.dict = dict;
    check ("raw command escape", &d,
	   "ASAP",
	   "\x01" "2S\x01" "D EY EH S EY P IY \x01" "T\x01" "5S", 0);
    check ("mixed phonemes and backref", &d,
	   "Dr", "\x01" "D D AA K T ER \x01" "T Dr", 0);
    check ("empty output is silence", &d, "say silent now", "say  now", 0);
    check ("escaped separator in the output", &d, "eq", "a = b", 0);
    check ("a trailing text segment blocks punctuation absorption", &d,
	   "Dr.", "\x01" "D D AA K T ER \x01" "T Dr.", 0);
    rcdict_free (dict);

    /* --- patterns may contain spaces and punctuation --- */
    dict = mkdict ("text New York = [N UW Y AA R K]\n"
		   "word C\\=D = see equals dee\n", &nerr);
    d.dict = dict;
    check ("multi-word pattern", &d,
	   "in New York today",
	   "in \x01" "D N UW Y AA R K \x01" "T today", 0);
    check ("escaped separator in the pattern", &d,
	   "C=D", "see equals dee", 0);
    rcdict_free (dict);

    /* --- rewriting still respects the boundaries --- */
    dict = mkdict ("text abc = xyz\n", &nerr);
    d.dict = dict;
    check ("a match may not cross a command atom", &d,
	   "ab\x01" "1I" "c", "ab\x01" "1I" "c", 0);
    check ("a match may not cross a CR", &d, "ab\rc", "ab\rc", 0);
    check ("a rule adjacent to a marker still fires", &d,
	   "\x01" "1I" "abc", "\x01" "1I" "xyz", 0);
    check ("no rewriting under Zap", &d,
	   "\x01" "Z abc", "\x01" "Z abc", 0);
    check ("and it comes back after CTRL+^", &d,
	   "\x01" "Z abc \x1e abc", "\x01" "Z abc \x1e xyz", 0);
    rcdict_free (dict);

    /* --- word boundaries at a run edge --- */
    dict = mkdict ("word cat = [K AE T]\n", &nerr);
    d.dict = dict;
    check ("a command atom counts as a word boundary", &d,
	   "\x01" "1I" "cat", "\x01" "1I\x01" "D K AE T \x01" "T", 0);
    check ("but a letter does not", &d, "scat", "scat", 0);
    rcdict_free (dict);

    /* --- a bad line costs one rule, never the file --- */
    dict = mkdict ("word good1 = one\n"
		   "banana     = nope\n"		/* unknown matcher */
		   "word noseparator\n"
		   "word bad   = [K NOTAPHONEME]\n"
		   "word unclosed = [K AE\n"
		   "word good2 = two\n", &nerr);
    checks++;
    if (rcdict_rule_count (dict) != 2 || nerr != 4)
      {
	failures++;
	printf ("FAIL error recovery: %lu rules kept, %d errors\n",
		(unsigned long) rcdict_rule_count (dict), nerr);
      }
    d.dict = dict;
    check ("rules around the bad ones still work", &d,
	   "good1 and good2", "one and two", 0);
    check ("the rejected rule is simply absent", &d, "bad", "bad", 0);
    rcdict_free (dict);

    /* --- layering: later files add, they do not override --- */
    dict = rcdict_new (&rcdict_rc8650);
    rcdict_add_text (dict, "word x = first\n", 15, "a.dict", NULL, NULL);
    rcdict_add_text (dict, "word x = second\n", 16, "b.dict", NULL, NULL);
    d.dict = dict;
    check ("the earlier file wins", &d, "x", "first", 0);
    rcdict_free (dict);

    /* --- tab-separated columns, the preferred spelling --- */
    dict = mkdict ("word\tNVDA\t[EH N V IY D IY EY]\n"
		   "word\tSean\tShon\n"
		   "text\tMbps\tmegabits per second\n", &nerr);
    checks++;
    if (rcdict_rule_count (dict) != 3 || nerr != 0)
      {
	failures++;
	printf ("FAIL tab form: %lu rules, %d errors\n",
		(unsigned long) rcdict_rule_count (dict), nerr);
      }
    d.dict = dict;
    check ("three tab columns", &d,
	   "NVDA and Sean",
	   "\x01" "D EH N V IY D IY EY \x01" "T and Shon", 0);
    rcdict_free (dict);

    dict = mkdict ("word\tC\tUS\t[Y UW EH S]\n"
		   "word\t\tplain\tordinary\n", &nerr);
    checks++;
    if (rcdict_rule_count (dict) != 2 || nerr != 0)
      {
	failures++;
	printf ("FAIL four-column form: %lu rules, %d errors\n",
		(unsigned long) rcdict_rule_count (dict), nerr);
      }
    d.dict = dict;
    check ("flags in their own column", &d,
	   "the US and us", "the \x01" "D Y UW EH S \x01" "T and us", 0);
    check ("an empty flags column means the defaults", &d,
	   "plain PLAIN", "ordinary ordinary", 0);
    rcdict_free (dict);

    dict = mkdict ("word:C\tUS\t[Y UW EH S]\n", &nerr);
    d.dict = dict;
    check ("flags may still ride on the type in the tab form", &d,
	   "the US and us", "the \x01" "D Y UW EH S \x01" "T and us", 0);
    rcdict_free (dict);

    /* Tabs make the fussy escaping unnecessary: no ' = ' to avoid, and a
       pattern may hold spaces, '=' and ';' with nothing to quote. */
    dict = mkdict ("text\tNew York\t[N UW Y AA R K]\n"
		   "text\tC = D\tsee equals dee\n"
		   "text\t;-)\tsmiley\n", &nerr);
    checks++;
    if (rcdict_rule_count (dict) != 3 || nerr != 0)
      {
	failures++;
	printf ("FAIL tab patterns: %lu rules, %d errors\n",
		(unsigned long) rcdict_rule_count (dict), nerr);
      }
    d.dict = dict;
    check ("a pattern with spaces needs no escaping", &d,
	   "in New York", "in \x01" "D N UW Y AA R K \x01" "T", 0);
    check ("a pattern containing ' = ' needs no escaping", &d,
	   "C = D", "see equals dee", 0);
    check ("a pattern starting with ';' is not a comment", &d,
	   "hi ;-)", "hi smiley", 0);
    rcdict_free (dict);

    dict = mkdict ("word\tsilent\n", &nerr);
    d.dict = dict;
    check ("two columns means a silent match", &d,
	   "say silent now", "say  now", 0);
    rcdict_free (dict);

    /* A stray tab in the pattern would otherwise be read as a flags column,
       so it is caught and named. */
    dict = mkdict ("word\tNew\tYork\t[N UW Y AA R K]\n"
		   "word\ta\tb\tc\td\te\n", &nerr);
    checks++;
    if (rcdict_rule_count (dict) != 0 || nerr != 2)
      {
	failures++;
	printf ("FAIL tab misuse: %lu rules, %d errors\n",
		(unsigned long) rcdict_rule_count (dict), nerr);
      }
    rcdict_free (dict);

    /* ---------------- regex ---------------- */

    dict = mkdict ("regex\t\\bv([0-9]+)\\.([0-9]+)\\b\tversion \\1 point \\2\n"
		   "regex\t([0-9]+)%\t\\1 percent\n", &nerr);
    checks++;
    if (rcdict_rule_count (dict) != 2 || nerr != 0)
      {
	failures++;
	printf ("FAIL regex parse: %lu rules, %d errors\n",
		(unsigned long) rcdict_rule_count (dict), nerr);
      }
    d.dict = dict;
    check ("captures reach the output", &d,
	   "see v2.14 now", "see version 2 point 14 now", 0);
    check ("a second capture rule", &d, "up 40% today",
	   "up 40 percent today", 0);
    check ("no match leaves the text alone", &d, "version two", "version two",
	   0);
    check ("\\b is honoured", &d, "xv2.14", "xv2.14", 0);
    rcdict_free (dict);

    /* \\0 is the whole match, for any matcher */
    dict = mkdict ("regex\t[0-9]+\tnumber \\0\n", &nerr);
    d.dict = dict;
    check ("\\0 is the whole match", &d, "code 42 here", "code number 42 here",
	   0);
    rcdict_free (dict);

    /* first-match-wins has to hold ACROSS the literal and regex lists, which
       are searched separately */
    dict = mkdict ("text\tcat\tLITERAL\n" "regex\tca[tn]\tREGEX\n", &nerr);
    d.dict = dict;
    check ("literal first beats a later regex", &d, "cat", "LITERAL", 0);
    rcdict_free (dict);

    dict = mkdict ("regex\tca[tn]\tREGEX\n" "text\tcat\tLITERAL\n", &nerr);
    d.dict = dict;
    check ("regex first beats a later literal", &d, "cat", "REGEX", 0);
    rcdict_free (dict);

    /* regex is case-sensitive whatever the file default says, because
       lowercasing a pattern would turn \\W into \\w */
    dict = mkdict ("#!case insensitive\n" "regex\tNVDA\tscreen reader\n",
		   &nerr);
    checks++;
    if (nerr != 0)
      {
	failures++;
	printf ("FAIL regex default case: %d errors (expected none)\n", nerr);
      }
    d.dict = dict;
    check ("regex matches case-sensitively by default", &d,
	   "NVDA and nvda", "screen reader and nvda", 0);
    rcdict_free (dict);

    dict = mkdict ("regex:i\tNVDA\tscreen reader\n", &nerr);
    checks++;
    if (nerr != 1)
      {
	failures++;
	printf ("FAIL asking for :i on a regex should be reported once, "
		"got %d\n", nerr);
      }
    rcdict_free (dict);

    /* the caps-only flag is a post-filter, so it does work on a regex */
    dict = mkdict ("regex:C\t[A-Za-z]+\tCAPS\n", &nerr);
    d.dict = dict;
    check ("caps-only filters a regex match", &d, "ABC and abc", "CAPS and abc",
	   0);
    rcdict_free (dict);

    /* the run copy is what bounds a regex: it must not see past a command
       atom, and ^ $ must anchor to the run rather than to the buffer */
    dict = mkdict ("regex\ta.c\tMATCHED\n", &nerr);
    d.dict = dict;
    check ("a regex may not match across a command atom", &d,
	   "ab\x01" "1I" "c", "ab\x01" "1I" "c", 0);
    check ("but it matches happily within a run", &d, "abc", "MATCHED", 0);
    rcdict_free (dict);

    dict = mkdict ("regex\t^abc$\tWHOLE\n", &nerr);
    d.dict = dict;
    check ("^ and $ anchor to the run, not the buffer", &d,
	   "\x01" "1I" "abc", "\x01" "1I" "WHOLE", 0);
    check ("and do not match a run with more in it", &d, "abcd", "abcd", 0);
    rcdict_free (dict);

    /* a zero-length match would leave the scanner where it was */
    dict = mkdict ("regex\tx*\tZERO\n", &nerr);
    d.dict = dict;
    check ("a zero-length match is refused, not spun on", &d,
	   "abc", "abc", 0);
    check ("but a non-empty one still fires", &d, "axxc", "aZEROc", 0);
    rcdict_free (dict);

    /* catastrophic backtracking must give up rather than hang.  Without the
       iteration limit this test does not finish. */
    dict = mkdict ("regex\t(a+)+b\tNEVER\n", &nerr);
    d.dict = dict;
    check ("a catastrophic pattern gives up, and says so once", &d,
	   "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa!",
	   "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa!", 1);
    rcdict_free (dict);

    /* a pattern that will not compile costs its own line and nothing else */
    dict = mkdict ("regex\t[unclosed\tnope\n" "word\tfine\tok\n", &nerr);
    checks++;
    if (rcdict_rule_count (dict) != 1 || nerr != 1)
      {
	failures++;
	printf ("FAIL bad regex: %lu rules, %d errors\n",
		(unsigned long) rcdict_rule_count (dict), nerr);
      }
    d.dict = dict;
    check ("the rule after a bad regex still works", &d, "fine", "ok", 0);
    rcdict_free (dict);

    /* a regex whose output is a phoneme span gets the absorption rules too */
    dict = mkdict ("regex\t\\bcomp[a-z]+\t[K AX M P YY UW DX ER]\n", &nerr);
    d.dict = dict;
    check ("absorption applies to a regex match as well", &d,
	   "i bought a computer.",
	   "i bought \x01" "D AX K AX M P YY UW DX ER . \x01" "T", 0);
    rcdict_free (dict);

    /* --- the inline escape and a dictionary coexist --- */
    dict = mkdict ("word cat = [K AE T]\n", &nerr);
    d.dict = dict;
    d.inline_phonemes = 1;
    check ("both in one utterance", &d,
	   "the cat and [[D AA G]].",
	   "the \x01" "D K AE T \x01" "T and \x01" "D D AA G . \x01" "T", 0);
    d.inline_phonemes = 0;
    rcdict_free (dict);
  }

  /* --- the rule matcher: L(F)R, RC8650 datasheet "Exception Syntax" ------ */
  {
    rcdict_options d;
    rcdict *dict;
    int nerr;

    rcdict_options_init (&d, &rcdict_rc8650);

    /* The datasheet's own two worked examples. */
    dict = mkdict ("rule\t\tC(O)N\t[AA]\n", &nerr);
    d.dict = dict;
    check ("left and right context, the datasheet's C(O)N", &d,
	   "icon", "ic\x01" "D AA \x01" "Tn", 0);
    check ("context that does not hold is not matched", &d, "cot", "cot", 0);
    rcdict_free (dict);

    dict = mkdict ("rule\t\t$R(H)\t\n", &nerr);
    d.dict = dict;
    check ("$ is the start of the run, and a silent rule", &d,
	   "rhyme", "ryme", 0);
    check ("$ does not match mid-word", &d, "abrhyme", "abrhyme", 0);
    rcdict_free (dict);

    /* Each single-character class from Table 22. */
    dict = mkdict ("rule\t\t(a)#\t[AY]\n"
		   "rule\t\t(b)+\t[B B]\n"
		   "rule\t\t(c)^\t[K K]\n"
		   "rule\t\t(d)?\t[D D]\n"
		   "rule\t\t(e)\\\t[EH EH]\n"
		   "rule\t\t(f)`\t[F F]\n", &nerr);
    d.dict = dict;
    check ("# is a vowel", &d, "ao", "\x01" "D AY \x01" "To", 0);
    check ("# is not a consonant", &d, "ax", "ax", 0);
    check ("+ is a front vowel", &d, "be", "\x01" "D B B \x01" "Te", 0);
    check ("+ is not a back vowel", &d, "bo", "bo", 0);
    check ("^ is a consonant", &d, "ct", "\x01" "D K K \x01" "Tt", 0);
    check ("? is a voiced consonant", &d, "dz", "\x01" "D D D \x01" "Tz", 0);
    check ("? is not a voiceless one", &d, "dt", "dt", 0);
    check ("backslash is a digit", &d, "e7", "\x01" "D EH EH \x01" "T7", 0);
    check ("backtick is any character", &d, "f%", "\x01" "D F F \x01" "T%", 0);
    check ("but it still needs a character", &d, "f", "f", 0);
    rcdict_free (dict);

    /* The variable-width ones. */
    dict = mkdict ("rule\t\t(a)*x\t[AA]\n"
		   "rule\t\t(b):x\t[B]\n"
		   "rule\t\t(c)|x\t[K]\n"
		   "rule\t\t(d)~x\t[D]\n"
		   "rule\t\t(k)%\t[K]\n", &nerr);
    d.dict = dict;
    check ("* is one or more consonants", &d, "astx",
	   "\x01" "D AA \x01" "Tstx", 0);
    check ("* needs at least one", &d, "ax", "ax", 0);
    check (": allows none", &d, "bx", "\x01" "D B \x01" "Tx", 0);
    check (": allows several", &d, "bstx", "\x01" "D B \x01" "Tstx", 0);
    check ("| is one or more digits", &d, "c123x",
	   "\x01" "D K \x01" "T123x", 0);
    check ("| ignores commas", &d, "c1,234x", "\x01" "D K \x01" "T1,234x", 0);
    check ("~ is one or more non-printing characters", &d, "d  x",
	   "\x01" "D D \x01" "T  x", 0);
    check ("% is a suffix followed by a non-letter", &d, "ked ",
	   "\x01" "D K \x01" "Ted ", 0);
    check ("% needs the non-letter after it", &d, "kedy", "kedy", 0);
    check ("% takes a longer suffix too", &d, "king ",
	   "\x01" "D K \x01" "Ting ", 0);
    rcdict_free (dict);

    /* Classes with two-character members, in both directions. */
    dict = mkdict ("rule\t\t(x)@\t[K S]\n" "rule\t\t&(y)\t[YY]\n", &nerr);
    d.dict = dict;
    check ("@ matches a two-character member", &d, "xch",
	   "\x01" "D K S \x01" "Tch", 0);
    check ("@ matches a one-character member", &d, "xd",
	   "\x01" "D K S \x01" "Td", 0);
    check ("@ rejects a non-member", &d, "xb", "xb", 0);
    check ("& works looking backwards too", &d, "shy",
	   "sh\x01" "D YY \x01" "T", 0);
    rcdict_free (dict);

    /* Rule precedence is the datasheet's own warning: (RAT) before (RATING)
       means (RATING) is never reached. */
    dict = mkdict ("rule\t\t(rat)\t[R AE T]\n"
		   "rule\t\t(rating)\t[R EY T IH NG]\n", &nerr);
    d.dict = dict;
    check ("first match wins, so (rat) shadows (rating)", &d,
	   "rating", "\x01" "D R AE T \x01" "Ting", 0);
    rcdict_free (dict);
    dict = mkdict ("rule\t\t(rating)\t[R EY T IH NG]\n"
		   "rule\t\t(rat)\t[R AE T]\n", &nerr);
    d.dict = dict;
    check ("the other order reaches both", &d,
	   "rating", "\x01" "D R EY T IH NG \x01" "T", 0);
    rcdict_free (dict);

    /* Consecutive matches are one span, not one span each.  This is what
       makes a whole letter-to-sound dictionary affordable. */
    dict = mkdict ("rule\t\t(o)\t[OW]\n"
		   "rule\t\t(l)\t[L]\n"
		   "rule\t\t(a)\t[AA]\n" "rule\t\t(h)\t\n", &nerr);
    d.dict = dict;
    check ("adjacent spans are joined", &d,
	   "ola", "\x01" "D OW L AA \x01" "T", 0);
    check ("a silent rule does not break the span", &d,
	   "hola", "\x01" "D OW L AA \x01" "T", 0);
    check ("unmatched text does break it", &d,
	   "oza", "\x01" "D OW \x01" "Tz\x01" "D AA \x01" "T", 0);
    rcdict_free (dict);

    /* A null text fragment: the datasheet's "()=" placed last, so that
       anything unmatched is silent instead of reaching the built in rules. */
    dict = mkdict ("rule\t\t(a)\t[AA]\n" "rule\t\t()\t\n", &nerr);
    d.dict = dict;
    check ("()= swallows what nothing else matched", &d,
	   "abc", "\x01" "D AA \x01" "T", 0);
    rcdict_free (dict);

    /* --- #!class: the same rules, a different alphabet ------------------- */
    {
      static const char es[] =
	"#!class # a e i o u y \xc3\xa1 \xc3\xa9 \xc3\xad\n"
	"#!class ^ b c d f g h j k l m n \xc3\xb1 p q r s t v w x y z\n"
	"rule\t\t$(m)$\t[EH M EH]\n"
	"rule\t\t(m)\t[M]\n" "rule\t\t(\xc3\xa1)\t[AA]\n"
	"rule\t\t(a)\t[AA]\n" "rule\t\t(s)\t[S]\n";
      /* The same file with the class lines taken out. */
      static const char en[] =
	"rule\t\t$(m)$\t[EH M EH]\n"
	"rule\t\t(m)\t[M]\n" "rule\t\t(\xc3\xa1)\t[AA]\n"
	"rule\t\t(a)\t[AA]\n" "rule\t\t(s)\t[S]\n";

      dict = mkdict (es, &nerr);
      d.dict = dict;
      check ("a declared alphabet makes the accented letter a letter", &d,
	     "m\xc3\xa1s", "\x01" "D M AA S \x01" "T", 0);
      check ("and a real single letter still spells itself", &d,
	     "m", "\x01" "D EH M EH \x01" "T", 0);
      check ("uppercase accented input folds to the pattern", &d,
	     "M\xc3\x81S", "\x01" "D M AA S \x01" "T", 0);
      rcdict_free (dict);

      dict = mkdict (en, &nerr);
      d.dict = dict;
      check ("without it the letter-naming rule fires mid-word", &d,
	     "m\xc3\xa1s", "\x01" "D EH M EH AA S \x01" "T", 0);
      rcdict_free (dict);
    }

    /* Two dictionaries with different alphabets in one rcdict: each rule
       keeps the classes it was loaded under. */
    {
      dict = rcdict_new (&rcdict_rc8650);
      nerr = 0;
      rcdict_add_text (dict, "#!class # a\nrule\t\t(z)#\t[Z]\n",
		       strlen ("#!class # a\nrule\t\t(z)#\t[Z]\n"),
		       "one.dict", diag, &nerr);
      rcdict_add_text (dict, "#!class # e\nrule\t\t(q)#\t[K]\n",
		       strlen ("#!class # e\nrule\t\t(q)#\t[K]\n"),
		       "two.dict", diag, &nerr);
      d.dict = dict;
      check ("the first file's vowel is a", &d, "za", "\x01" "D Z \x01" "Ta",
	     0);
      check ("and is not e", &d, "ze", "ze", 0);
      check ("the second file's vowel is e", &d, "qe", "\x01" "D K \x01" "Te",
	     0);
      check ("and is not a", &d, "qa", "qa", 0);
      rcdict_free (dict);
    }

    /* Malformed input is reported and skipped, never silently dropped. */
    {
      int n = 0;
      dict = mkdict ("rule\t\tno parentheses here\t[AA]\n"
		     "rule\t\t(a)\t[AA]\n", &n);
      checks++;
      if (n != 1 || rcdict_rule_count (dict) != 1)
	{
	  failures++;
	  printf ("FAIL malformed rule: %d diagnostics, %lu rules\n", n,
		  (unsigned long) rcdict_rule_count (dict));
	}
      rcdict_free (dict);

      n = 0;
      dict = mkdict ("#!class $ a b c\n" "#!class # \n"
		     "#!class ? a\n" "rule\t\t(a)?\t[AA]\n", &n);
      checks++;
      if (n != 2)		/* $ is structural; # was given no members */
	{
	  failures++;
	  printf ("FAIL bad #!class: expected 2 diagnostics, got %d\n", n);
	}
      rcdict_free (dict);
    }

    /* A rule may not reach across a command atom or an utterance boundary. */
    dict = mkdict ("rule\t\t(ab)\t[AA B]\n", &nerr);
    d.dict = dict;
    check ("a rule may not span a command", &d,
	   "a\x01" "2Ib", "a\x01" "2Ib", 0);
    check ("nor a CR", &d, "a\rb", "a\rb", 0);
    check ("$ sees the command as the edge of the run", &d,
	   "\x01" "2Iab", "\x01" "2I\x01" "D AA B \x01" "T", 0);
    rcdict_free (dict);

    /* Rules and the other matchers settle by load order, as they do among
       themselves. */
    dict = mkdict ("word\t\tcat\t[K AE T]\n" "rule\t\t(c)\t[S]\n", &nerr);
    d.dict = dict;
    check ("an earlier word rule beats a later exception", &d,
	   "cat", "\x01" "D K AE T \x01" "T", 0);
    rcdict_free (dict);
    dict = mkdict ("rule\t\t(c)\t[S]\n" "word\t\tcat\t[K AE T]\n", &nerr);
    d.dict = dict;
    check ("and the other way round", &d,
	   "cat", "\x01" "D S \x01" "Tat", 0);
    rcdict_free (dict);
  }

  /* --- truncation reports what was needed, and never overruns --- */
  {
    char small[8];
    const char *in = "the [[K AX M]] is fast.";
    size_t need = rcdict_expand (&on, in, strlen (in), small, sizeof small,
				 NULL, NULL);
    checks++;
    if (need <= sizeof small || strlen (small) != sizeof small - 1)
      {
	failures++;
	printf ("FAIL truncation: need=%zu len=%zu\n", need, strlen (small));
      }
  }

  printf ("%d checks, %d failures\n", checks, failures);
  return failures != 0;
}
