# RC8650 (emulated) synth driver for NVDA.
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Drives librc8650 (rc8650_64.dll / rc8650_32.dll) as an NVDA speech
# synthesizer. The library runs the RC8650's real firmware on an emulated
# Renesas M16C and returns the PCM the chip's D/A converter would have
# produced, so the voice, the text-to-speech and the command protocol are the
# chip's own - this driver only translates NVDA's settings into the chip's
# <CTRL+A>n<char> commands and pumps the audio into WavePlayer.
#
# NVDA's speech indexes are the chip's own index markers (nI, Table 20): the
# marker is planted in the text, the chip transmits its number once it has
# spoken the text up to it, and librc8650 timestamps that against the sample
# stream - so an index is reported as its words play, not when the utterance
# ends. See speak() and _synthLoop.
#
# Files expected next to this __init__.py:
#   rc8650_64.dll         - `make win64` (NVDA 2025.2+ is a 64-bit process)
#   rc8650_32.dll         - `make win32` (older, 32-bit NVDA)
#   rc8650_m4_valid.srec  - the RC8650 firmware image, in Motorola S-record
#                           form (.srec.gz is also accepted). RC Systems'
#                           copyrighted code: not distributed with the add-on,
#                           supply your own.
#
# Command reference throughout is the RC8650 datasheet ("RC8650 Commands,
# Firmware v2.60"); table numbers cited in comments are its own. Everything
# stated here about which command does what to the chip was verified against
# the emulated firmware with the Interrogate command (12?, Table 19), not
# assumed from the prose.

import ctypes
# Unmaps the DLL on terminate - ctypes itself never does, so without this each
# switch to this synth bumps the loader refcount again and nothing brings it
# back down. It matters more here than for most drivers: the emulator core
# keeps file-scope state and refuses a second engine per process, so unloading
# is what guarantees the next instance starts from a clean core.
# Private CPython API, but the public spelling (windll.kernel32.FreeLibrary)
# truncates the HMODULE on 64-bit unless its argtypes are set by hand.
from _ctypes import FreeLibrary
import gzip
import os
import re
import threading
import queue

import config
import nvwave
from autoSettingsUtils.driverSetting import (
	BooleanDriverSetting,
	DriverSetting,
	NumericDriverSetting,
)
from autoSettingsUtils.utils import StringParameterInfo
from synthDriverHandler import (
	SynthDriver,
	VoiceInfo,
	synthDoneSpeaking,
	synthIndexReached,
)
from speech.commands import IndexCommand, PitchCommand, RateCommand, VolumeCommand
from logHandler import log

_DIR = os.path.dirname(__file__)

# 1024 samples is ~102 ms at the chip's 10017 Hz. The renderer runs about 2-4x
# faster than real time, so a chunk costs ~30 ms to produce: small enough that
# speech starts promptly, large enough that the per-call overhead is noise.
SAMPLES_PER_CHUNK = 1024

# Longest run of bytes handed to the chip as one utterance. The chip's own
# input buffer is 2 KB and librc8650's queue drops what does not fit rather
# than blocking the CPU, so anything longer is split (see _split) instead of
# being silently truncated mid-sentence.
MAX_UTTERANCE_BYTES = 1900

# How many index-marker numbers the driver cycles through.
#
# The chip's nI command takes 0-99 (Table 20), but 66 and 69 are unusable here:
# they are 'B' and 'E', the V8600-scale start/stop status messages, and since
# this driver switches speed scales per utterance (see _RATE_LADDER) librc8650
# recognises both scales' messages at all times and consumes those two bytes
# before they can be read back as markers. 0-63 is a clean rolling space well
# clear of both, and 64 markers in flight is far more than one utterance from
# NVDA ever carries.
MARKER_COUNT = 64

# How many markers to collect from the library per audio chunk. A chunk is
# ~102 ms and markers come one per index, so this is only ever a ceiling.
MARKERS_PER_READ = 16

# The firmware image, in the order tried. The name librc8650's own CLI uses
# comes first; the .gz forms are accepted because the S-record is ~900 KB of
# ASCII that compresses to about a tenth of that.
_FIRMWARE_NAMES = (
	"rc8650_m4_valid.srec",
	"rc8650_m4_valid.srec.gz",
	"rc8650.srec",
	"rc8650.srec.gz",
)


def _dllName():
	# NVDA 2025.2+ runs as a 64-bit process; earlier versions are 32-bit.
	return "rc8650_64.dll" if ctypes.sizeof(ctypes.c_void_p) == 8 else "rc8650_32.dll"


class _Rc8650IndexMark(ctypes.Structure):
	# rc8650.h's rc8650_index_mark: an index marker the chip has reached, and
	# the D/A sample count at the instant it transmitted it.
	#
	# The 64-bit field is deliberately first, with the two 32-bit ones after
	# it, so the layout is 16 bytes at offsets 0/8/12 with no padding to
	# disagree about - the same under ctypes here and under both mingw targets
	# the DLLs are built with. A {uint8, uint64} pair would have left the
	# 32-bit build's alignment of the 64-bit member to the compiler.
	_fields_ = [
		("sample_pos", ctypes.c_uint64),
		("value", ctypes.c_uint32),
		("reserved", ctypes.c_uint32),
	]


def _findFirmware():
	for name in _FIRMWARE_NAMES:
		path = os.path.join(_DIR, name)
		if os.path.isfile(path):
			return path
	return None


class _Rc8650DLL:
	def __init__(self):
		self.lib = ctypes.cdll.LoadLibrary(os.path.join(_DIR, _dllName()))
		lib = self.lib
		lib.rc8650_new_from_memory.restype = ctypes.c_void_p
		lib.rc8650_new_from_memory.argtypes = [
			ctypes.c_char_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_char_p)]
		lib.rc8650_free.argtypes = [ctypes.c_void_p]
		lib.rc8650_write.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t]
		lib.rc8650_stop.argtypes = [ctypes.c_void_p]
		lib.rc8650_read_s16.restype = ctypes.c_size_t
		lib.rc8650_read_s16.argtypes = [
			ctypes.c_void_p, ctypes.POINTER(ctypes.c_int16), ctypes.c_size_t,
			ctypes.POINTER(ctypes.c_int)]
		lib.rc8650_read_serial.restype = ctypes.c_size_t
		lib.rc8650_read_serial.argtypes = [
			ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t]
		lib.rc8650_is_speaking.restype = ctypes.c_int
		lib.rc8650_is_speaking.argtypes = [ctypes.c_void_p]
		lib.rc8650_set_status_messages.argtypes = [ctypes.c_void_p, ctypes.c_int]
		# Index markers: the chip transmits a marker's number once it has
		# spoken the text up to it, and the library timestamps each one with
		# the sample count it arrived at. rc8650_samples_read is the clock
		# those timestamps are quoted against - see _synthLoop.
		lib.rc8650_set_index_marks.argtypes = [ctypes.c_void_p, ctypes.c_int]
		lib.rc8650_read_index_marks.restype = ctypes.c_size_t
		lib.rc8650_read_index_marks.argtypes = [
			ctypes.c_void_p, ctypes.POINTER(_Rc8650IndexMark), ctypes.c_size_t]
		lib.rc8650_samples_read.restype = ctypes.c_uint64
		lib.rc8650_samples_read.argtypes = [ctypes.c_void_p]
		# Reconstruction filter of the modeled output stage. AO0/AO1 are
		# unfiltered D/A pins; the datasheet's own reference circuit (Figure 7)
		# is a 3 kHz low-pass, so this is part of the hardware's sound.
		lib.rc8650_set_lowpass_hz.argtypes = [ctypes.c_void_p, ctypes.c_uint]
		lib.rc8650_sample_rate.restype = ctypes.c_uint
		lib.rc8650_sample_rate.argtypes = []
		lib.rc8650_version.restype = ctypes.c_char_p
		lib.rc8650_version.argtypes = []
		# Pronunciation dictionary. rcdict is its own BSD-3 module inside the
		# DLL, so these are its symbols rather than the library's; only
		# set_dictionary and expand belong to librc8650.
		lib.rcdict_new.restype = ctypes.c_void_p
		lib.rcdict_new.argtypes = [ctypes.c_void_p]
		lib.rcdict_free.argtypes = [ctypes.c_void_p]
		lib.rcdict_add_file.restype = ctypes.c_int
		lib.rcdict_add_file.argtypes = [
			ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p]
		lib.rcdict_rule_count.restype = ctypes.c_size_t
		lib.rcdict_rule_count.argtypes = [ctypes.c_void_p]
		lib.rc8650_set_dictionary.argtypes = [
			ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int]
		lib.rc8650_expand.restype = ctypes.c_size_t
		lib.rc8650_expand.argtypes = [
			ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t,
			ctypes.c_char_p, ctypes.c_size_t]
		# rcdict_rc8650 is a struct, not a pointer to one, so what is wanted
		# is its address; in_dll on a pointer type would read its first field.
		self.rcdict_rc8650 = ctypes.addressof(
			ctypes.c_char.in_dll(lib, "rcdict_rc8650"))

		# Unload again if the firmware is missing or bad: that is the one
		# failure every user without an image hits, and it is retried on every
		# attempt to select the synth, so a DLL left mapped here is a refcount
		# that climbs each time - and, because the emulator core allows only
		# one engine per process, a stale mapping is also what would make the
		# *next* attempt fail for a different and much more confusing reason.
		self.handle = None
		try:
			path = _findFirmware()
			if not path:
				raise RuntimeError(
					"no RC8650 firmware image next to the driver (looked for %s)"
					% ", ".join(_FIRMWARE_NAMES))
			opener = gzip.open if path.endswith(".gz") else open
			with opener(path, "rb") as f:
				srec = f.read()
			err = ctypes.c_char_p()
			self.handle = lib.rc8650_new_from_memory(srec, len(srec), ctypes.byref(err))
			if not self.handle:
				# The message is malloc'd by the library for the caller to
				# free. There is no portable way to reach that allocator's
				# free() from here, so it is left: it happens only on a failed
				# load, and it is tens of bytes.
				raise RuntimeError(
					"rc8650_new_from_memory failed: %s"
					% (err.value.decode("utf-8", "replace") if err.value else "unknown"))
			# Every prefix sets STM (see _prefix), so the chip reports the
			# start and end of its own output and the library never has to
			# infer the end of an utterance from silence.
			lib.rc8650_set_status_messages(self.handle, 1)
			# Capture the nI markers this driver plants in the text, rather
			# than letting them fall through to the query-reply stream.
			lib.rc8650_set_index_marks(self.handle, 1)
			self.sample_rate = lib.rc8650_sample_rate()
			log.debug("rc8650: %s at %d Hz, firmware %s"
				% (lib.rc8650_version().decode("utf-8", "replace"),
					self.sample_rate, os.path.basename(path)))
		except Exception:
			self.close()
			raise

	def close(self, unload=True):
		# Free the engine first: unloading the DLL out from under a live handle
		# would call rc8650_free into unmapped code.
		if self.handle:
			self.lib.rc8650_free(self.handle)
			self.handle = None
		# self.lib is dropped so a second close() cannot free the same HMODULE
		# twice - that underflows the loader refcount, and if Windows has since
		# recycled the handle value it unloads someone else's module.
		# unload=False leaves the image mapped (see terminate): leaking it is
		# always better than pulling it out from under a running thread.
		if unload and self.lib:
			FreeLibrary(self.lib._handle)
			self.lib = None


class SynthDriver(SynthDriver):
	name = "rc8650"
	description = "RC8650 (emulated)"

	# --- how the chip's settings are presented -------------------------------
	#
	# Rate, pitch, volume and inflection are NVDA's own settings and must run
	# 0-100, so they are mapped (see _mapRate, _mapPitch, _map0to9). The
	# chip-specific ones below are NOT: they keep the card's native range, so
	# the number NVDA announces in the settings ring is the number in the
	# datasheet, and one arrow key is one card step by construction rather than
	# by arithmetic. minStep/normalStep are both set to 1 for those, because
	# the settings ring steps by normalStep while the sliders in the Voice
	# Settings dialog step by minStep.

	supportedSettings = (
		SynthDriver.VoiceSetting(),
		# Rate is a 20-position ladder, not the chip's bare 0-9 speed; see
		# _RATE_LADDER for why and what the extra ten positions are.
		SynthDriver.RateSetting(minStep=5),
		SynthDriver.PitchSetting(),
		# Inflection is the chip's Expression (nE 0-9): 0 is a monotone, 9 is
		# very animated. Ten slider stops for ten card values (see _map0to9).
		SynthDriver.InflectionSetting(minStep=10),
		SynthDriver.VolumeSetting(minStep=10),
		# nX tone: bass (0X), normal (1X, the default), treble (2X) - the
		# datasheet likens it to a stereo's bass/treble controls.
		DriverSetting("tone", "&Tone", availableInSettingsRing=True, defaultVal="1"),
		# nA 0-9. Low values slur the voice, high values make it choppy.
		NumericDriverSetting("articulation", "&Articulation",
			availableInSettingsRing=True, defaultVal=5,
			minVal=0, maxVal=9, minStep=1, normalStep=1, largeStep=3),
		# nF 0-9: the synthesizer's overall frequency response (vocal-tract
		# formant frequencies). Retunes the voice type rather than its speed.
		NumericDriverSetting("formant", "&Formant frequency",
			availableInSettingsRing=True, defaultVal=5,
			minVal=0, maxVal=9, minStep=1, normalStep=1, largeStep=3),
		# nR 0-9: 0 is dry, higher values lengthen the reverb.
		NumericDriverSetting("reverb", "Re&verb",
			availableInSettingsRing=True, defaultVal=0,
			minVal=0, maxVal=9, minStep=1, normalStep=1, largeStep=3),
		# nT 0-15: extra pause between words. The datasheet offers it as an
		# intelligibility aid for listeners new to synthetic speech.
		NumericDriverSetting("worddelay", "&Word delay",
			availableInSettingsRing=True, defaultVal=0,
			minVal=0, maxVal=15, minStep=1, normalStep=1, largeStep=5),
		# The four fields of the Punctuation Filter Register (nB, Table 8),
		# split into the four independent things it actually controls.
		DriverSetting("punctuation", "&Punctuation",
			availableInSettingsRing=True, defaultVal="2"),
		BooleanDriverSetting("numbers", "Read &numbers as numbers",
			availableInSettingsRing=True, defaultVal=True),
		BooleanDriverSetting("leadingzeros", "Speak &leading zeros",
			availableInSettingsRing=True, defaultVal=True),
		BooleanDriverSetting("years", "Read four-digit numbers as &years",
			availableInSettingsRing=True, defaultVal=True),
		# Reconstruction filter of the modeled output stage (not a chip
		# command). See _filters.
		DriverSetting("filter", "Output &filter",
			availableInSettingsRing=True, defaultVal="3000"),
	)
	supportedCommands = {IndexCommand, PitchCommand, RateCommand, VolumeCommand}
	supportedNotifications = {synthIndexReached, synthDoneSpeaking}

	# nO voice numbers 0-7, names per the datasheet's Table 7. Unlike the
	# DoubleTalk PC's eight, none of these are aliases: all eight presets below
	# are distinct.
	_voices = {
		"0": VoiceInfo("0", "Perfect Paul", "en"),
		"1": VoiceInfo("1", "Vader", "en"),
		"2": VoiceInfo("2", "Big Bob", "en"),
		"3": VoiceInfo("3", "Precise Pete", "en"),
		"4": VoiceInfo("4", "Ricochet Randy", "en"),
		"5": VoiceInfo("5", "Biff", "en"),
		"6": VoiceInfo("6", "Skip", "en"),
		"7": VoiceInfo("7", "Robo Robert", "en"),
	}

	# Firmware voice presets, keyed by nO voice id, in CARD-NATIVE units:
	# (pitch 0-99, articulation 0-9, formant 0-9, tone 0-2, expression 0-9,
	# reverb 0-9, word delay 0-15).
	#
	# These are not guesses: each row was read back out of the emulated chip
	# with the Interrogate command (12?) after selecting that voice. Selecting
	# nO loads them, which is what gives each voice its character - Vader's
	# pitch 10 and reverb 3, Skip's formant 9, Robo Robert's flat 0 expression
	# and its word delay of 1.
	_voicePresets = {
		"0": (50, 5, 5, 1, 5, 0, 0),  # Perfect Paul
		"1": (10, 4, 0, 1, 6, 3, 0),  # Vader
		"2": (40, 5, 3, 0, 5, 0, 0),  # Big Bob
		"3": (60, 6, 6, 2, 4, 0, 0),  # Precise Pete
		"4": (40, 5, 5, 1, 5, 9, 0),  # Ricochet Randy
		"5": (50, 6, 0, 0, 7, 0, 0),  # Biff
		"6": (15, 6, 9, 0, 7, 0, 0),  # Skip
		"7": (80, 5, 7, 1, 0, 6, 1),  # Robo Robert
	}
	# Index into a _voicePresets row.
	_P_PITCH, _P_ARTIC, _P_FORMANT, _P_TONE, _P_EXPR, _P_REVERB, _P_DELAY = range(7)

	# The rate ladder: (Protocol Options Register value, nS speed) from slowest
	# to fastest, 20 positions.
	#
	# The chip has two speech-rate scales, selected by POR bit 7 (V86). With
	# V86 set - the power-on default, 128G - nS 0-9 runs about 173 to 395 wpm.
	# With it clear (0G) the chip emulates RC Systems' earlier V8600 module and
	# the same nS 0-9 runs about 116 to 242 wpm. The two overlap, so this table
	# is the union of both, sorted by measured utterance length: it turns two
	# coarse ten-step scales into one monotonic twenty-step one covering
	# 116-395 wpm, which is both slower and finer than either alone.
	#
	# Interleaving the two is safe because V86 changes nothing else that this
	# driver uses: interrogating all eight voices under 0G and under 128G
	# returns identical presets. Its only other documented effect is on which
	# characters the status messages use, and the driver accepts both sets.
	# Durations were measured on one fixed sentence per rung.
	_RATE_LADDER = (
		(0, 0), (0, 1), (0, 2), (0, 3), (0, 4),
		(128, 0), (0, 5), (0, 6), (128, 1), (0, 7),
		(128, 2), (128, 3), (0, 8), (128, 4), (0, 9),
		(128, 5), (128, 6), (128, 7), (128, 8), (128, 9),
	)
	# Slider position of (128, 1), the chip's own power-on rate.
	_RATE_DEFAULT = 45

	# POR bit 0 (STM), OR'd into every value above. See _prefix. Re-timing the
	# whole ladder with the bit set changed 19 of the 20 rungs by not one
	# sample, and the twentieth by two out of 53875.
	_STM = 1

	# nX tone, Table 8.
	_tones = {
		"0": StringParameterInfo("0", "Bass"),
		"1": StringParameterInfo("1", "Normal"),
		"2": StringParameterInfo("2", "Treble"),
	}

	# PFR filter-mode field (nB bits 1-0), Table 8. The card's default is
	# "Some", which is also what suits a screen reader that does its own
	# symbol processing.
	_punctuations = {
		"0": StringParameterInfo("0", "All"),
		"1": StringParameterInfo("1", "Most (all but CR, LF, space)"),
		"2": StringParameterInfo("2", "Some ($%&#@=+*^|\\<>)"),
		"3": StringParameterInfo("3", "None"),
	}

	# Reconstruction low-pass corners offered by the modeled output stage.
	# 3000 is the default and is the datasheet's own reference circuit
	# (Figure 7, "Low Cost 3 kHz Low-Pass Filter/Power Amplifier") - what a
	# finished RC8650 product sounded like. "Off" is the bare D/A: the
	# unfiltered 10 kHz sample-and-hold staircase, complete with its imaging
	# hiss, which is what the AO pins themselves put out. 4800 is the ceiling
	# the library allows, below the 5008 Hz Nyquist frequency.
	_filters = {
		"0": StringParameterInfo("0", "Off (unfiltered D/A)"),
		"2000": StringParameterInfo("2000", "Muffled (2 kHz)"),
		"2500": StringParameterInfo("2500", "Warm (2.5 kHz)"),
		"3000": StringParameterInfo("3000", "Datasheet (3 kHz)"),
		"3800": StringParameterInfo("3800", "Bright (3.8 kHz)"),
		"4800": StringParameterInfo("4800", "Widest (4.8 kHz)"),
	}

	@classmethod
	def check(cls):
		return os.path.isfile(os.path.join(_DIR, _dllName())) and _findFirmware() is not None

	def __init__(self):
		self._rc = _Rc8650DLL()
		# Serializes EVERY ctypes call into the (not thread-safe) engine across
		# the main thread (cancel/terminate/settings) and the synth thread.
		self._libLock = threading.Lock()
		# rc8650_read_s16 returns signed 16-bit mono through the modeled output
		# stage, which is exactly the WAVE_FORMAT_PCM layout WavePlayer wants
		# (16-bit PCM is signed little-endian), so its bytes go straight
		# through.
		# NVDA 2025.1 moved the output device setting from the "speech" config
		# section to "audio" (also changing its value from a device name to an
		# endpoint ID). Each era's WavePlayer expects its own era's value, so
		# read whichever key this NVDA has.
		try:
			outputDevice = config.conf["audio"]["outputDevice"]
		except KeyError:
			outputDevice = config.conf["speech"]["outputDevice"]
		self._player = nvwave.WavePlayer(
			channels=1,
			samplesPerSec=int(self._rc.sample_rate),
			bitsPerSample=16,
			outputDevice=outputDevice,
		)
		self._rate = self._RATE_DEFAULT
		self._pitch = 50
		self._volume = 60  # -> nV 5, the card default
		self._voice = "0"
		self._filter = "3000"
		self._punctuation = "2"
		self._numbers = True
		self._leadingzeros = True
		self._years = True
		# True only while NVDA is restoring saved settings (see loadSettings).
		# It guards _set_voice: a config restore must NOT snap the seven
		# voice-linked settings to the voice preset (that would clobber the
		# user's saved per-voice values); an interactive voice change does.
		self._restoring = False
		# The seven voice-linked settings, initialised to voice 0's preset so
		# that at startup _prefix emits nothing for them and the firmware
		# preset shows through untouched.
		self._applyPreset("0")
		# Next chip marker number to hand out, rolling through MARKER_COUNT.
		# Which NVDA index each one stands for travels with its utterance
		# rather than living here - see speak() and _synthLoop.
		self._nextMark = 0
		self._queue = queue.Queue()
		# Cancellation is a generation counter rather than a flag, because a
		# flag has a window that loses utterances. cancel() and speak() both
		# run on NVDA's main thread, back to back, while the synthesis thread
		# runs free: if that thread has already taken an utterance off the
		# queue but has not yet cleared the flag, it clears the cancel that
		# arrived in between and speaks something NVDA has abandoned - and the
		# utterance NVDA actually wanted is stuck behind it.
		#
		# A counter cannot be un-set. Each utterance is stamped with the
		# generation current when NVDA asked for it, and the thread abandons it
		# the moment the counter moves on. int assignment and comparison are
		# atomic under the GIL, so no lock is needed to read it.
		self._generation = 0
		self._dict = None
		self._inlinePhonemes = False
		self._loadDictionaries()
		self._thread = threading.Thread(target=self._synthLoop, daemon=True)
		self._thread.start()
		with self._libLock:
			self._rc.lib.rc8650_set_lowpass_hz(self._rc.handle, int(self._filter))

	def terminate(self):
		self.cancel()
		self._queue.put(None)
		self._thread.join(timeout=5)
		self._player.close()
		# Only unload the DLL if the synthesis thread is really gone.
		# _synthLoop caches lib/handle in locals and _libLock does not help
		# here: close() runs holding the lock, so a worker parked on it
		# acquires the lock the moment close() returns and calls straight into
		# the freed image. A timed-out join leaks a daemon thread; unloading
		# anyway would turn that leak into an access violation that takes NVDA
		# down with it.
		unload = not self._thread.is_alive()
		if not unload:
			log.warning("Synthesis thread still running; leaving rc8650 DLL loaded")
		with self._libLock:
			# The engine borrows the dictionary, so detach before freeing it.
			if self._dict and unload:
				try:
					self._rc.lib.rc8650_set_dictionary(self._rc.handle, None, 0)
					self._rc.lib.rcdict_free(self._dict)
				except Exception:
					log.exception("rc8650: freeing the dictionary failed")
				self._dict = None
			self._rc.close(unload=unload)

	# --- pronunciation dictionaries -----------------------------------------

	def _loadDictionaries(self):
		"""(Re)load the user's rcdict files into the engine.

		Files and load order come from dictfiles; rules are first-match-wins in
		that order, so the file at the top of the list wins. Format and a worked
		example: rcdict.h and example.dict.

		Returns (rules, files) for a caller that wants to report what happened.
		(0, 0) is a perfectly good answer and means there are none; None means
		the attempt did not get far enough to say. Deliberately quiet either
		way: having no dictionaries is the normal case, and every failure path
		here leaves the synth working exactly as it did before dictionaries
		existed. A dictionary must never be the reason a screen reader goes
		quiet.
		"""
		try:
			from . import dictfiles
			paths = dictfiles.orderedPaths()
		except Exception:
			log.exception("rc8650: could not look for dictionaries")
			return None

		lib = self._rc.lib
		new = None
		total = 0
		if paths or self._inlinePhonemes:
			try:
				new = lib.rcdict_new(self._rc.rcdict_rc8650)
				for path in paths:
					try:
						# The library's own char* path, so the ANSI code page -
						# the same encoding its fopen will decode it with.
						total += lib.rcdict_add_file(
							new, path.encode("mbcs"), None, None)
					except Exception:
						log.exception("rc8650: could not load %s" % path)
			except Exception:
				log.exception("rc8650: building the dictionary failed")
				new = None

		# Attach the new one before freeing the old, so there is no moment at
		# which the engine holds a dangling pointer - even though both this and
		# _expand run on NVDA's main thread and cannot overlap today.
		old, self._dict = self._dict, new
		try:
			with self._libLock:
				lib.rc8650_set_dictionary(
					self._rc.handle, new, 1 if self._inlinePhonemes else 0)
		except Exception:
			log.exception("rc8650: attaching the dictionary failed")
		if old:
			try:
				lib.rcdict_free(old)
			except Exception:
				log.exception("rc8650: freeing the old dictionary failed")
		if new is not None:
			log.info("rc8650: loaded %d dictionary rules from %d file(s)"
				 % (total, len(paths)))
		return (total, len(paths) if new is not None else 0)

	def reloadDictionaries(self):
		"""Re-read the dictionary files, for the settings panel.

		This is what makes editing a .dict file a matter of saving it rather
		than restarting the synthesizer.
		"""
		return self._loadDictionaries()

	# --- saved-settings hygiene ---------------------------------------------

	def _clampSavedSettings(self):
		# NVDA validates saved values against the driver's CURRENT spec the
		# moment the base loadSettings reads them, so a value saved by a build
		# whose range was different raises VdtValueTooSmallError and the whole
		# synth fails to load. Pull such values into range in the raw (not yet
		# validated) profile dicts before the base class reads them.
		#
		# The raw dicts are written directly, behind config.conf's back, so
		# nothing is marked dirty and the stale value stays in the file - that
		# is deliberate. The repair is idempotent and cheap, and not rewriting
		# the user's config is the smaller footprint of the two. Only the
		# loaded profile stack is reachable here; an inactive manual profile
		# gets the same treatment when it is activated, since NVDA reloads
		# settings then.
		#
		# Nothing in here may raise: the whole point is that the synth loads.
		try:
			for profile in config.conf.profiles:
				try:
					raw = profile["speech"][self.name]
				except KeyError:
					continue
				for setting in self.supportedSettings:
					self._clampSavedSetting(raw, setting)
		except Exception:
			log.debugWarning("Could not clamp saved settings", exc_info=True)

	@staticmethod
	def _clampSavedSetting(raw, setting):
		# maxVal is checked as well as minVal: a range narrowed at the top
		# would fail the same way, from the other end. The string and boolean
		# settings have neither and are left alone.
		minVal = getattr(setting, "minVal", None)
		maxVal = getattr(setting, "maxVal", None)
		if (minVal is None and maxVal is None) or setting.id not in raw:
			return
		# Stored as strings, so compare numerically and write back a string to
		# keep the raw section homogeneous with everything else on disk.
		try:
			value = int(raw[setting.id])
		except (TypeError, ValueError):
			log.debugWarning("Ignoring non-numeric saved %s: %r" % (setting.id, raw[setting.id]))
			return
		if minVal is not None and value < minVal:
			raw[setting.id] = str(minVal)
		elif maxVal is not None and value > maxVal:
			raw[setting.id] = str(maxVal)

	def loadSettings(self, onlyChanged=False):
		self._clampSavedSettings()
		# NVDA restores saved settings by first changing the voice and THEN
		# restoring each other setting (SynthDriver.loadSettings applies
		# "voice" before the rest of supportedSettings). If _set_voice snapped
		# the voice-linked settings to the firmware preset during this, it
		# would overwrite the user's saved per-voice values a moment before
		# they are restored - and worse, an unchanged setting is skipped on an
		# onlyChanged profile switch, so the snap could stick. Guard the whole
		# restore so _set_voice does NOT snap here. Interactive voice changes
		# happen outside loadSettings (settings ring / Voice Settings dialog ->
		# changeVoice), where _restoring is False, so those still snap.
		self._restoring = True
		try:
			super().loadSettings(onlyChanged)
		finally:
			self._restoring = False

	# --- settings ------------------------------------------------------------

	def _applyPreset(self, voice):
		# Snap the seven voice-linked settings to a voice's firmware preset, in
		# the units each setting is presented in. They round-trip back to the
		# same card values in _prefix, so an untouched voice emits only the nO
		# select and its preset shows through exactly.
		preset = self._voicePresets[voice]
		self._pitch = self._cardPitchToNvda(preset[self._P_PITCH])
		self._articulation = preset[self._P_ARTIC]
		self._formant = preset[self._P_FORMANT]
		self._tone = str(preset[self._P_TONE])
		self._inflection = self._card0to9ToNvda(preset[self._P_EXPR])
		self._reverb = preset[self._P_REVERB]
		self._worddelay = preset[self._P_DELAY]

	def _get_voice(self):
		return self._voice

	def _set_voice(self, value):
		if value not in self._voices:
			return
		self._voice = value
		if self._restoring:
			# Config restore / init: honor the saved per-voice settings, which
			# the base loadSettings applies right after this. Do not snap.
			return
		# Interactive voice change: snap the voice-linked settings so the
		# sliders (which NVDA re-reads via the getters after changeVoice, both
		# in the Voice Settings dialog and the settings ring) show exactly what
		# the card will produce for this voice.
		self._applyPreset(value)

	def _getAvailableVoices(self):
		return self._voices

	def _get_rate(self):
		return self._rate

	def _set_rate(self, value):
		self._rate = value

	def _get_pitch(self):
		return self._pitch

	def _set_pitch(self, value):
		self._pitch = value

	def _get_inflection(self):
		return self._inflection

	def _set_inflection(self, value):
		self._inflection = value

	def _get_volume(self):
		return self._volume

	def _set_volume(self, value):
		self._volume = value

	def _get_availableTones(self):
		return self._tones

	def _get_tone(self):
		return self._tone

	def _set_tone(self, value):
		if value in self._tones:
			self._tone = value

	def _get_articulation(self):
		return self._articulation

	def _set_articulation(self, value):
		self._articulation = value

	def _get_formant(self):
		return self._formant

	def _set_formant(self, value):
		self._formant = value

	def _get_reverb(self):
		return self._reverb

	def _set_reverb(self, value):
		self._reverb = value

	def _get_worddelay(self):
		return self._worddelay

	def _set_worddelay(self, value):
		self._worddelay = value

	def _get_availablePunctuations(self):
		return self._punctuations

	def _get_punctuation(self):
		return self._punctuation

	def _set_punctuation(self, value):
		if value in self._punctuations:
			self._punctuation = value

	def _get_numbers(self):
		return self._numbers

	def _set_numbers(self, value):
		self._numbers = bool(value)

	def _get_leadingzeros(self):
		return self._leadingzeros

	def _set_leadingzeros(self, value):
		self._leadingzeros = bool(value)

	def _get_years(self):
		return self._years

	def _set_years(self, value):
		self._years = bool(value)

	def _get_availableFilters(self):
		return self._filters

	def _get_filter(self):
		return self._filter

	def _set_filter(self, value):
		if value not in self._filters:
			return
		self._filter = value
		with self._libLock:
			self._rc.lib.rc8650_set_lowpass_hz(self._rc.handle, int(value))

	# --- unit conversion -----------------------------------------------------

	@staticmethod
	def _mapPitch(pct):
		# NVDA pitch 0-100 -> card nP 0-99 (both default mid-range: 50 -> 50).
		return max(0, min(99, int(round(pct * 99 / 100))))

	@staticmethod
	def _cardPitchToNvda(p):
		# The inverse, chosen so it round-trips: _mapPitch(_cardPitchToNvda(p))
		# == p for every preset pitch (10->10, 15->15, 40->40, 50->51->50,
		# 60->61->60, 80->81->80).
		return int(round(p * 100 / 99))

	# Volume and inflection are card 0-9 shown on a 10-100 slider in steps of
	# 10: ten stops for ten card values, so every arrow key is one card step
	# and no two positions collapse onto the same value. The obvious 0-100
	# range would give eleven stops for ten values, leaving 90 and 100 both
	# meaning 9 - a dead step at the top of the slider.

	@staticmethod
	def _map0to9(pct):
		# NVDA slider 10-100 -> card 0-9 (10 -> 0, 60 -> 5, 100 -> 9). Clamped
		# rather than trusted, so a hand-edited or stale config value cannot
		# produce a negative card value and a malformed command.
		return max(0, min(9, pct // 10 - 1))

	@staticmethod
	def _card0to9ToNvda(v):
		return (v + 1) * 10

	def _mapRate(self, pct):
		# NVDA rate slider -> a rung of _RATE_LADDER. The slider runs 5-100 in
		# steps of 5: twenty stops for the ladder's twenty rungs.
		return self._RATE_LADDER[max(0, min(len(self._RATE_LADDER) - 1, pct // 5 - 1))]

	def _pfr(self):
		# Punctuation Filter Register (Table 8): bits 1-0 filter mode, bit 2
		# numbers mode, bit 3 leading-zero suppression, bit 4 years mode.
		#
		# Note the two inversions the datasheet defines: LZS = 1 means *do not*
		# suppress leading zeroes, and YM = 0 means read four-digit numbers as
		# years. Leading zeros default to spoken here, unlike the chip's own
		# 6B default: on screen "007" is content, and a screen reader that says
		# "seven" has dropped two characters the user can see.
		return (int(self._punctuation) & 3) \
			| (4 if self._numbers else 0) \
			| (8 if self._leadingzeros else 0) \
			| (0 if self._years else 16)

	# --- building the chip's command stream ----------------------------------

	def _prefix(self):
		# Command format (datasheet, "The Command Character"): each command is
		# <CTRL+A><number string><command character>, and nothing is executed
		# or spoken until a CR arrives.
		#
		# Voice (nO) MUST come first. Selecting a voice reloads the chip's
		# formant, pitch, tone, expression, articulation, reverb and word delay
		# from that voice's firmware preset - verified by setting all seven
		# away from their defaults, issuing nO and interrogating - so any of
		# those sent before it would be clobbered.
		#
		# WYSIWYG emission: because nO already loads the preset, a voice-linked
		# setting still sitting at its preset needs no command at all, and
		# omitting it lets the firmware preset show through exactly. Each of
		# the seven is therefore emitted only when the user has moved it OFF
		# this voice's preset, and then absolutely, never re-flattened to some
		# global default.
		#
		# Speed, volume and the two registers are emitted UNCONDITIONALLY. The
		# same test shows nO does not reload them: the chip simply keeps
		# whatever it was last given. Omitting one at its default would
		# therefore not mean "the card is at 5", it would mean "leave the card
		# wherever it happens to be" - so moving the volume slider down and
		# back would leave the card quiet at a nominally default setting.
		voice = self._voice
		preset = self._voicePresets[voice]
		por, speed = self._mapRate(self._rate)

		# STM (bit 0) makes the chip transmit a one-byte message when its
		# output starts and another when it stops. That is what the library
		# ends an utterance on - see rc8650_set_status_messages - and it is
		# the difference between knowing an utterance has finished and
		# guessing it from silence. It costs nothing else: every rung of the
		# rate ladder was re-timed with the bit set and came back sample for
		# sample identical.
		#
		# The Protocol Options Register also goes FIRST, before the voice,
		# which reads oddly next to the datasheet's rule that the voice comes
		# before the parameter commands. In the other order this firmware
		# emits a 232-sample burst - about 23 ms, peaking at 5% of full scale,
		# so an audible blip - before it settles down and speaks, and then
		# pauses for up to 149k instructions to finish parsing. The burst is
		# what is being avoided here.
		#
		# (That pause used to make the utterance disappear altogether, which
		# is how the ordering was found; the disappearance was the pump
		# reading the pause as the end of the utterance, and is fixed in the
		# library. The blip is the part that is really about the ordering.)
		#
		# Putting nG first is safe: the datasheet's ordering rule is about the
		# voice parameters that nO reloads, and the register is not one of them
		# - interrogating the chip after an nO shows POR untouched. nS still
		# lands after both, which is what actually matters, because the
		# register selects the speed scale that nS then indexes into.
		parts = ["\x01%dG" % (por | self._STM)]
		parts.append("\x01%sO" % voice)
		parts.append("\x01%dS" % speed)
		parts.append("\x01%dV" % self._map0to9(self._volume))
		parts.append("\x01%dB" % self._pfr())

		pitch = self._mapPitch(self._pitch)
		if pitch != preset[self._P_PITCH]:
			parts.append("\x01%dP" % pitch)
		if int(self._tone) != preset[self._P_TONE]:
			parts.append("\x01%sX" % self._tone)
		if self._articulation != preset[self._P_ARTIC]:
			parts.append("\x01%dA" % self._articulation)
		if self._map0to9(self._inflection) != preset[self._P_EXPR]:
			parts.append("\x01%dE" % self._map0to9(self._inflection))
		if self._formant != preset[self._P_FORMANT]:
			parts.append("\x01%dF" % self._formant)
		if self._reverb != preset[self._P_REVERB]:
			parts.append("\x01%dR" % self._reverb)
		if self._worddelay != preset[self._P_DELAY]:
			parts.append("\x01%dT" % self._worddelay)
		return "".join(parts)

	def _prosody(self, command):
		# NVDA's prosody commands are relative to the current setting and are
		# always followed by a reset (offset 0), e.g. pitch up for a capital
		# and back down after. Both directions are emitted as ABSOLUTE chip
		# commands computed from the base setting, so the reset restores the
		# real value - including a preset value that _prefix deliberately never
		# sent - without having to re-select the voice.
		offset = command.offset
		if isinstance(command, PitchCommand):
			value = self._pitch if offset == 0 else min(100, max(0, self._pitch + offset))
			return "\x01%dP" % self._mapPitch(value)
		if isinstance(command, VolumeCommand):
			value = self._volume if offset == 0 else min(100, max(10, self._volume + offset))
			return "\x01%dV" % self._map0to9(value)
		if isinstance(command, RateCommand):
			value = self._rate if offset == 0 else min(100, max(5, self._rate + offset))
			por, speed = self._mapRate(value)
			# Keep STM set: this rewrites the whole register, and dropping the
			# bit mid-utterance would silence the end-of-output message the
			# library is waiting for.
			return "\x01%dG\x01%dS" % (por | self._STM, speed)
		return ""

	def _expand(self, text):
		"""Run the pronunciation dictionary over one utterance's bytes.

		Returns the text unchanged when nothing is loaded, which is the common
		case, and on any failure - a dictionary must never be the reason a
		screen reader goes quiet.
		"""
		if not self._dict and not self._inlinePhonemes:
			return text
		try:
			lib, h = self._rc.lib, self._rc.handle
			need = lib.rc8650_expand(h, text, len(text), None, 0)
			if need <= 0:
				return text
			buf = ctypes.create_string_buffer(need + 1)
			lib.rc8650_expand(h, text, len(text), buf, need + 1)
			return buf.raw[:need]
		except Exception:
			log.exception("rc8650: dictionary expansion failed")
			return text

	@staticmethod
	def _split(text):
		# The chip's input buffer is 2 KB and librc8650's input queue drops
		# what does not fit, so a long utterance is broken into several. Splits
		# fall on a space where possible, so a word is never cut in half; each
		# piece becomes its own CR-terminated utterance, which costs a sentence
		# boundary's worth of prosody at the seam and nothing else. Only
		# genuinely long text (roughly a minute of speech) is ever affected.
		pieces = []
		while len(text) > MAX_UTTERANCE_BYTES:
			cut = text.rfind(b" ", MAX_UTTERANCE_BYTES // 2, MAX_UTTERANCE_BYTES)
			if cut <= 0:
				cut = MAX_UTTERANCE_BYTES
			pieces.append(text[:cut])
			text = text[cut:].lstrip(b" ")
		if text:
			pieces.append(text)
		return pieces

	def speak(self, speechSequence):
		if not any(isinstance(item, str) and item.strip() for item in speechSequence):
			# Nothing to say: NVDA sends empty and whitespace-only sequences
			# routinely (a blank line, an index on its own). Sending one to the
			# chip means it never starts its D/A, and the pump then has to wait
			# out its whole idle budget before it can tell "still thinking"
			# from "nothing to say" - dead air, for no speech. Report the
			# indexes and be done. Checked before anything is built, so no
			# marker number is spent on text that is never sent.
			self._queue.put(((), [
				(None, item.index) for item in speechSequence
				if isinstance(item, IndexCommand)], self._generation))
			return
		parts = [self._prefix()]
		marks = []
		for item in speechSequence:
			if isinstance(item, str):
				# Printable ASCII only: the firmware reads control bytes as
				# commands, so a stray CTRL+A, CR or CTRL+X in the text would
				# be executed rather than spoken. This also guarantees the
				# encode below cannot fail.
				parts.append(re.sub(r"[^\x20-\x7e]", " ", item))
			elif isinstance(item, IndexCommand):
				# An index marker (nI, Table 20) planted in the text. The chip
				# transmits the marker's number once it has spoken the text up
				# to it - measured against the audio, each one arrives in the
				# silence before the word it marks, up to 137 ms ahead of it
				# and never behind - so the index is reported as that part of
				# the utterance plays rather than after the whole thing.
				#
				# nI takes a decimal number string in the command and sends
				# back a one-byte BINARY value, which is why the number has to
				# stay inside MARKER_COUNT and why librc8650 hands markers
				# back through their own call rather than the serial stream.
				mark = self._nextMark
				self._nextMark = (self._nextMark + 1) % MARKER_COUNT
				marks.append((mark, item.index))
				parts.append("\x01%dI" % mark)
			elif isinstance(item, (PitchCommand, VolumeCommand, RateCommand)):
				parts.append(self._prosody(item))
		text = "".join(parts).encode("ascii", "replace")
		# EXPAND BEFORE SPLITTING, not after. A dictionary entry can turn one
		# word into forty characters of phonemes plus the two mode switches, so
		# a piece that fitted the chip's 2 KB input buffer before expansion may
		# not afterwards - and librc8650's input ring drops the overflow
		# without a word. Expanding first means _split measures what is
		# actually going to be sent.
		text = self._expand(text)
		# A split falls on a space (see _split) and a marker command contains
		# none, so no piece can ever be cut through the middle of one.
		self._queue.put((self._split(text), marks, self._generation))

	def cancel(self):
		self._generation += 1
		try:
			while True:
				self._queue.get_nowait()
		except queue.Empty:
			pass
		with self._libLock:
			# The chip's own Stop (CTRL+X): clears its input buffer and stops
			# whatever it is saying. librc8650 drops undelivered audio with it,
			# and delivers the stop to the chip before returning - so the next
			# utterance, which NVDA usually queues immediately, is not written
			# in behind an undelivered one.
			#
			# It also drops the markers the chip had already sent back for the
			# audio being thrown away, and closes the gap those samples left in
			# rc8650_samples_read - so the next utterance's marker positions
			# are still positions in the same stream the pump is measuring.
			self._rc.lib.rc8650_stop(self._rc.handle)
		# Nothing to undo for the indexes NVDA has just abandoned: an
		# utterance's markers belong to its queue item, which the generation
		# bump above has already written off.
		self._player.stop()

	def pause(self, switch):
		self._player.pause(switch)

	# --- synthesis thread ----------------------------------------------------

	def _synthLoop(self):
		lib = self._rc.lib
		h = self._rc.handle
		# 16-bit samples: a c_char buffer of 2 bytes each, cast to int16* for
		# the call; buf.raw[:n*2] is then the little-endian PCM to feed.
		buf = ctypes.create_string_buffer(SAMPLES_PER_CHUNK * 2)
		buf16 = ctypes.cast(buf, ctypes.POINTER(ctypes.c_int16))
		done = ctypes.c_int(0)
		marks = (_Rc8650IndexMark * MARKERS_PER_READ)()
		while True:
			item = self._queue.get()
			if item is None:
				return
			pieces, owed, gen = item
			try:
				if gen != self._generation:
					# Cancelled between NVDA queueing it and this thread
					# picking it up.
					continue
				# Markers the chip has sent back whose audio has not been fed
				# to the player yet: (sample position, marker number).
				pending = []
				# What this utterance still owes NVDA: marker number -> index,
				# for the markers it actually sent to the chip. Per utterance
				# rather than driver-wide, so a marker number that has rolled
				# all the way round while this one is still playing cannot
				# resolve to a newer utterance's index. Entries leave as they
				# are reported.
				remaining = dict((m, i) for m, i in owed if m is not None)
				for piece in pieces:
					if gen != self._generation:
						break
					with self._libLock:
						# Nothing is spoken until a CR or a NUL arrives; this
						# uses NUL. The two are interchangeable as terminators,
						# but with the punctuation filter set to All the chip
						# speaks CR, LF and space - including the CR that ends
						# the utterance, which measured as half a second of
						# unwanted speech tacked onto every single one. NUL is
						# not in that set, so it terminates silently, and in
						# every other filter mode the two are indistinguishable.
						lib.rc8650_write(h, piece, len(piece))
						lib.rc8650_write(h, b"\x00", 1)
					while gen == self._generation:
						with self._libLock:
							n = lib.rc8650_read_s16(h, buf16, SAMPLES_PER_CHUNK,
								ctypes.byref(done))
							raw = buf.raw[:n * 2] if n else b""
							# Both of these belong to the read that just ran, so
							# they are taken under the same lock: the marker
							# call is non-blocking and only drains what that
							# read produced, and samples_read is the library's
							# own count of what it has handed over - the clock
							# the marker positions are quoted against, and
							# exactly the amount of audio fed to the player
							# below by the time this chunk has gone in.
							nm = lib.rc8650_read_index_marks(h, marks,
								MARKERS_PER_READ)
							pending.extend(
								(marks[i].sample_pos, marks[i].value)
								for i in range(nm))
							chunkEnd = lib.rc8650_samples_read(h)
						if not n:
							# Drained above first: the marker for the last
							# words of an utterance can arrive on the read that
							# returns no audio, and breaking before collecting
							# it would leave it to the sweep below.
							break
						# A marker at or before the end of this chunk refers to
						# audio that is in this feed, so it is reported when
						# this feed finishes PLAYING rather than now - feeding
						# runs ahead of the speakers by however much the player
						# has buffered. Anything past the chunk end stays
						# pending: the chip can transmit a marker before the
						# samples around it have been handed over.
						fired = [m for m in pending if m[0] <= chunkEnd]
						pending = [m for m in pending if m[0] > chunkEnd]
						# Struck off here, not in the callback, so the sweep
						# below can tell what is still owed without waiting on
						# the player thread.
						reached = []
						for _, mark in fired:
							index = remaining.pop(mark, None)
							if index is not None:
								reached.append(index)

						def onDone(reached=reached):
							for index in reached:
								synthIndexReached.notify(synth=self, index=index)

						self._player.feed(raw, onDone=onDone if reached else None)
				if gen == self._generation:
					# idle() returns when the audio has actually finished
					# playing, so the sweep below runs against the end of the
					# speech rather than the end of the rendering, which runs
					# ahead of it.
					self._player.idle()
				if gen == self._generation:
					# Re-checked: idle() blocks for the length of the audio, and
					# a cancel arriving during it means NVDA has moved on. It
					# does not want the indexes for what it just abandoned.
					#
					# Whatever this utterance is still owed, in the order NVDA
					# gave it. Anything the chip reported has already been
					# struck off as it played, so this sweep is the backstop for
					# the rest: a marker in text the chip declined to speak, one
					# lost to a full ring, or - marker None - an index from a
					# sequence with no speech in it at all, which never went to
					# the chip. NVDA's say all advances on these notifications,
					# so an index that goes unreported does not just cost
					# highlighting, it stops the reading.
					for mark, index in owed:
						if mark is None or remaining.pop(mark, None) is not None:
							synthIndexReached.notify(synth=self, index=index)
					synthDoneSpeaking.notify(synth=self)
			except Exception:
				log.error("rc8650 synth thread", exc_info=True)
