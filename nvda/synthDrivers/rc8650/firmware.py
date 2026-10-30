# Which firmware image the driver runs.
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# librc8650 runs whatever RC Systems firmware it is handed: the five RC8650
# v2.60 builds RCStudio ships, the RC8660 v3.44, and whatever turns up later.
# This module answers the two questions both halves of the add-on ask - which
# images are there, and which one is chosen - without loading the library, so
# the settings panel can list images while another synth is running, and the
# driver can find its image before it has a DLL to ask.
#
# Images live in <nvda config>/rc8650/firmware/, beside the dictionaries, so
# that updating the add-on - which replaces its whole folder - does not take
# them with it. Images in the driver's own folder are still found, which is
# where the add-on has always looked and where a personal build bundles one.
#
# Each image identifies itself: the firmware's 13-byte header at 0xA0000
# carries the version (bytes 4-5, packed BCD, low byte first), the model byte
# (6) and the family (7: 0x04 RC8650, 0x05 RC8660). That is read straight out
# of the S-record text here, so the list says what each file is whatever it is
# called. tools/rcstudio2srec.py makes images from RCStudio's own files and
# names them after the same header.

import gzip
import os

import config
import globalVars
from logHandler import log

CONFIG_SECTION = "rc8650"
FOLDER_NAME = "rc8650"
SUBFOLDER = "firmware"
EXTENSIONS = (".srec", ".srec.gz")

#: The image the add-on looked for before there was a choice. Still preferred
#: when nothing has been chosen, so an existing install keeps its voice.
LEGACY_NAMES = (
	"rc8650_m4_valid.srec",
	"rc8650_m4_valid.srec.gz",
	"rc8650.srec",
	"rc8650.srec.gz",
)

_CONFIG_SPEC = {
	# A file name in the firmware folder, or an absolute path to one anywhere
	# else. Empty means "the default": see chosen().
	"firmware": "string(default='')",
}

_DRIVER_DIR = os.path.dirname(__file__)
_FAMILIES = {0x04: "RC8650", 0x05: "RC8660"}


def initConfig():
	"""Declare our keys, alongside whatever else the section already holds."""
	section = config.conf.spec.setdefault(CONFIG_SECTION, {})
	for key, value in _CONFIG_SPEC.items():
		if key not in section:
			section[key] = value


def folderPath(create=False):
	path = os.path.join(globalVars.appArgs.configPath, FOLDER_NAME, SUBFOLDER)
	if create:
		os.makedirs(path, exist_ok=True)
	return path


class Image:
	"""One firmware image on disk, and what its header says it is."""

	def __init__(self, path, chip, version, model):
		self.path = path
		self.name = os.path.basename(path)
		self.chip = chip  # "RC8650", "RC8660", or "family 0xNN"
		self.version = version  # "2.60"
		self.model = model

	@property
	def label(self):
		return "%s firmware %s, model %d (%s)" % (
			self.chip, self.version, self.model, self.name)

	def __repr__(self):
		return "<Image %s>" % self.label


def readText(path):
	"""The S-record text of an image, transparently gunzipped."""
	opener = gzip.open if path.endswith(".gz") else open
	with opener(path, "rb") as f:
		return f.read()


def identify(path):
	"""Read an image's header without booting it; None if it has none.

	Only the eight bytes at 0xA0000-0xA0007 are wanted, so records are parsed
	until they are all found and no further - the image is ~900 KB of text and
	the header is in its first few records.
	"""
	try:
		text = readText(path)
	except (OSError, EOFError):
		log.debugWarning("rc8650: cannot read %s" % path, exc_info=True)
		return None
	header = {}
	for line in text.splitlines():
		if len(line) < 10 or line[:1] != b"S" or line[1:2] not in b"123":
			continue
		try:
			addressBytes = int(line[1:2]) + 1
			count = int(line[2:4], 16)
			address = int(line[4:4 + 2 * addressBytes], 16)
			data = bytes.fromhex(line[4 + 2 * addressBytes:2 + 2 * count].decode("ascii"))
		except ValueError:
			continue
		for offset, byte in enumerate(data):
			if 0xA0000 <= address + offset < 0xA0008:
				header[address + offset - 0xA0000] = byte
		if len(header) == 8:
			break
	if len(header) != 8 or header[0] != 0xFE:
		return None
	family = header[7]
	return Image(
		path,
		_FAMILIES.get(family, "family 0x%02X" % family),
		"%x.%02x" % (header[5], header[4]),
		header[6])


def _candidates():
	seen = set()
	for folder in (folderPath(), _DRIVER_DIR):
		try:
			names = sorted(os.listdir(folder), key=str.lower)
		except OSError:
			continue
		for name in names:
			if not name.lower().endswith(EXTENSIONS) or name.lower() in seen:
				continue
			seen.add(name.lower())
			yield os.path.join(folder, name)


def catalog():
	"""Every usable image, the firmware folder's first, each once by name."""
	images = []
	for path in _candidates():
		image = identify(path)
		if image:
			images.append(image)
		else:
			log.debugWarning("rc8650: %s is not a firmware image" % path)
	return images


def _resolve(entry):
	if not entry:
		return None
	if os.path.isabs(entry):
		return entry if os.path.isfile(entry) else None
	for folder in (folderPath(), _DRIVER_DIR):
		path = os.path.join(folder, entry)
		if os.path.isfile(path):
			return path
	return None


def chosenEntry():
	initConfig()
	try:
		return config.conf[CONFIG_SECTION]["firmware"]
	except KeyError:
		return ""


def chosen():
	"""The image to run, or None if there is none at all.

	The configured one if it is still there; otherwise the image the add-on
	has always looked for; otherwise the first in the catalog. Falling back
	rather than failing is deliberate: a screen reader whose chosen image was
	deleted should still talk.
	"""
	path = _resolve(chosenEntry())
	if path:
		return path
	for name in LEGACY_NAMES:
		path = _resolve(name)
		if path:
			return path
	images = catalog()
	return images[0].path if images else None


def choose(path):
	"""Make path the image to run. Stored by name when it is in one of the
	two folders searched, so a portable configuration keeps working."""
	initConfig()
	folder = os.path.dirname(os.path.abspath(path))
	inSearched = any(
		os.path.normcase(folder) == os.path.normcase(os.path.abspath(f))
		for f in (folderPath(), _DRIVER_DIR))
	config.conf[CONFIG_SECTION]["firmware"] = os.path.basename(path) if inSearched else path
