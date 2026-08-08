# Which pronunciation dictionaries load, and in what order.
#
# SPDX-License-Identifier: BSD-3-Clause
#
# BSD-3 inside an otherwise GPL-3 add-on, and deliberately so: the doubletalk-pc
# add-on carries the same module (synthDrivers/doubletalkpc/dictfiles.py) and
# that tree is BSD-3 throughout. The two differ only in the constants below, so
# a fix to one belongs in the other - which is only possible while the licence
# lets it travel in both directions. Same reasoning as rcdict itself; see
# DICTIONARY-PLAN.md, "the licence direction is one-way".
#
# Two halves of the add-on need the same answer: the synth driver, which loads
# the files, and the settings panel, which lets the user arrange them. It lives
# here rather than with the panel because the driver has to work whether or not
# the panel ever loads - never the other way round.
#
# The rule in one sentence: the dictionaries are the .dict files in
# <nvda config>/rc8650/, loaded in the order stored in NVDA's configuration,
# with anything that order has not seen yet appended in sorted order.
#
# That last clause is what keeps dropping a file into the folder working. It is
# how dictionaries worked before there was a panel, and it is how a user who
# never opens the panel goes on using them.
#
# Everything else follows from rcdict's one hard rule: matching is
# first-match-wins in LOAD ORDER, so a later file cannot override an earlier one
# - it can only add. Order is therefore not a cosmetic preference, it is the
# only setting there is, which is why it is worth a config key and four buttons.

import os

import config
import globalVars
from logHandler import log

#: Section in NVDA's configuration, and the folder under <nvda config>. Same
#: name for both, on purpose: one thing to tell a user to look for.
CONFIG_SECTION = "rc8650"
FOLDER_NAME = "rc8650"

EXTENSION = ".dict"

#: string_list rather than a single delimited string because a Windows path can
#: contain almost anything, including whatever separator would have been picked.
_CONFIG_SPEC = {
	"dictionaries": "string_list(default=list())",
}


def initConfig():
	"""Declare our configuration section.

	Idempotent and safe to call from anywhere; both the driver and the settings
	panel call it before touching config, because whichever of them runs first
	cannot know that the other has.
	"""
	if CONFIG_SECTION not in config.conf.spec:
		config.conf.spec[CONFIG_SECTION] = _CONFIG_SPEC


def folderPath(create=False):
	"""The folder dictionaries live in, created on demand.

	Not created unless asked for: a user with no dictionaries should not find an
	empty folder in their configuration wondering what it wants from them.
	"""
	path = os.path.join(globalVars.appArgs.configPath, FOLDER_NAME)
	if create and not os.path.isdir(path):
		os.makedirs(path)
	return path


def installedNames():
	"""Every dictionary file in the folder, sorted, whatever the order says."""
	try:
		return sorted(
			f for f in os.listdir(folderPath())
			if f.lower().endswith(EXTENSION)
		)
	except OSError:
		# No folder yet is the normal case, not a problem to report.
		return []


def mergeOrder(preferred):
	"""The installed files, ordered by C{preferred}, unlisted ones appended.

	Names in C{preferred} that are not installed drop out, and names that are
	installed but unlisted are appended in sorted order. Matching is
	case-insensitive but the folder's own spelling is what comes back, because
	the filesystem is the authority on that and the config may hold whatever the
	file was called when it was added.

	Duplicates in C{preferred} collapse to the first occurrence, which is the
	one that would have won anyway.
	"""
	remaining = dict((n.lower(), n) for n in installedNames())
	ordered = []
	for name in preferred:
		real = remaining.pop(os.path.basename(name).lower(), None)
		if real is not None:
			ordered.append(real)
	ordered.extend(sorted(remaining.values()))
	return ordered


def orderedNames():
	"""The dictionary file names to load, in load order."""
	return mergeOrder(savedOrder())


def orderedPaths():
	"""The dictionary files to load, in load order, as full paths."""
	folder = folderPath()
	return [os.path.join(folder, name) for name in orderedNames()]


def savedOrder():
	"""The order stored in the configuration. Empty if it has never been set."""
	initConfig()
	try:
		return list(config.conf[CONFIG_SECTION]["dictionaries"])
	except Exception:
		# A config written by some other version, or a section that somehow did
		# not take the spec. Falling back to the sorted folder is exactly the
		# behaviour this add-on had before the order was configurable.
		log.debugWarning("rc8650: could not read the dictionary order",
			exc_info=True)
		return []


def setOrder(names):
	"""Store the load order. Names only; the folder supplies the rest."""
	initConfig()
	config.conf[CONFIG_SECTION]["dictionaries"] = [
		os.path.basename(n) for n in names
	]
