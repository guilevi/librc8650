# SPDX-License-Identifier: BSD-3-Clause
#
# BSD-3 inside an otherwise GPL-3 add-on, and deliberately so: the doubletalk-pc
# add-on carries the same panel (globalPlugins/doubletalkpcDictionaries.py) and
# that tree is BSD-3 throughout. The two differ only in the names, so a fix to
# one belongs in the other - which is only possible while the licence lets it
# travel in both directions. Same reasoning as rcdict itself; see
# DICTIONARY-PLAN.md, "the licence direction is one-way".
#
# "RC8650 dictionaries" in NVDA's Settings dialog: which pronunciation
# dictionary files load, in what order, and a way to reload them without
# restarting the synthesizer.
#
# Why a global plugin and not the synth driver. A driver module is loaded when
# its synthesizer is selected and unloaded when it is not, so a settings
# category registered there would appear and disappear with the synthesizer -
# and worse, could be pulled out from under an open Settings dialog. Global
# plugins live for the whole session, which is what a settings category needs.
#
# What the panel is actually for. rcdict matches first-match-wins in load order,
# so a rule in a later file cannot override an earlier one - it can only add.
# The single thing a user needs control of, then, is the ORDER, and there is no
# way to express it in a folder of files except by naming them so they sort the
# way you want. Hence a list with Move up / Move down, and hence the order
# living in NVDA's configuration rather than in the filenames.
#
# Everything here is keyboard-first: the buttons keep the focus when they act
# (so Move up can be pressed four times without chasing the selection around),
# and anything that happens without focus moving is spoken with ui.message,
# because a wx selection changed in code raises no event for NVDA to announce.

import os
import shutil

import wx

import globalPluginHandler
import globalVars
import gui
import synthDriverHandler
import ui
from gui import guiHelper
from gui.settingsDialogs import NVDASettingsDialog, SettingsPanel
from logHandler import log

# The driver package owns the rule about which files load and in what order,
# because the driver has to work whether or not this plugin does - and never
# the other way round. Caught rather than allowed to propagate so that a
# half-installed add-on costs a log line and this one category, instead of
# taking the whole global plugin down with a traceback at import time.
try:
	from synthDrivers.rc8650 import dictfiles
except ImportError:
	dictfiles = None

#: The synthesizer these dictionaries belong to (SynthDriver.name).
SYNTH_NAME = "rc8650"

#: What NVDA's own settings panels wrap their descriptions at.
PANEL_DESCRIPTION_WIDTH = 544


def _count(n, singular, plural):
	"""'1 file' / '2 files', because "1 files" reads as a bug."""
	return "%d %s" % (n, singular if n == 1 else plural)


class DictionariesPanel(SettingsPanel):
	# The name of this category in NVDA's Settings dialog.
	title = "RC8650 dictionaries"

	panelDescription = (
		"Pronunciation dictionaries for the RC8650 (emulated) "
		"synthesizer. Rules are tried from the top of the list downwards and "
		"the first match wins, so a file higher in the list overrides one "
		"below it."
	)

	def makeSettings(self, settingsSizer):
		sHelper = guiHelper.BoxSizerHelper(self, sizer=settingsSizer)

		# The same sentence as panelDescription, which is only ever an
		# accessible description; this is the one a sighted user reads.
		description = sHelper.addItem(
			wx.StaticText(self, label=self.panelDescription))
		description.Wrap(self.scaleSize(PANEL_DESCRIPTION_WIDTH))

		#: The working order. Held here rather than read back out of the list
		#: control so that a move is a list operation and not a screen-scrape.
		self._names = dictfiles.orderedNames()

		self._listBox = sHelper.addLabeledControl(
			"Dictionary &files, in the order they are loaded",
			wx.ListBox,
			choices=self._names,
		)
		self._listBox.Bind(wx.EVT_LISTBOX, self.onSelectionChanged)

		bHelper = guiHelper.ButtonHelper(wx.HORIZONTAL)
		# Mnemonics chosen to clear the dialog's own OK / Cancel / Apply, which
		# take O, C and A.
		self._addButton = bHelper.addButton(self, label="A&dd...")
		self._removeButton = bHelper.addButton(self, label="&Remove")
		self._upButton = bHelper.addButton(self, label="Move &up")
		self._downButton = bHelper.addButton(self, label="Move dow&n")
		self._reloadButton = bHelper.addButton(self, label="Re&load dictionaries")
		sHelper.addItem(bHelper)

		self._addButton.Bind(wx.EVT_BUTTON, self.onAdd)
		self._removeButton.Bind(wx.EVT_BUTTON, self.onRemove)
		self._upButton.Bind(wx.EVT_BUTTON, lambda evt: self._move(-1))
		self._downButton.Bind(wx.EVT_BUTTON, lambda evt: self._move(1))
		self._reloadButton.Bind(wx.EVT_BUTTON, self.onReload)

		sHelper.addItem(wx.StaticText(
			self,
			label="Dictionary files are kept in: %s" % dictfiles.folderPath(),
		))

		self._selectIndex(0)

	def onPanelActivated(self):
		# The folder can have changed since the panel was built - a file dropped
		# in by hand, or an editor saving a new one - and the panel may well
		# have been built at the start of the session. Re-merge rather than
		# reload, so an order the user has arranged but not yet applied is not
		# thrown away by walking out of the category and back in.
		#
		# The selection is restored by NAME rather than by index, because the
		# merge can insert above it.
		index = self._listBox.GetSelection()
		current = self._names[index] if 0 <= index < len(self._names) else None
		self._names = dictfiles.mergeOrder(self._names)
		self._rebuild(self._names.index(current) if current in self._names else 0)
		super(DictionariesPanel, self).onPanelActivated()

	# --- the list -------------------------------------------------------------

	def _rebuild(self, select=0):
		self._listBox.Set(self._names)
		self._selectIndex(select)

	def _selectIndex(self, index):
		if self._names:
			index = max(0, min(index, len(self._names) - 1))
			self._listBox.SetSelection(index)
		self._updateButtons()

	def _updateButtons(self):
		index = self._listBox.GetSelection()
		has = index != wx.NOT_FOUND
		self._removeButton.Enable(has)
		self._upButton.Enable(has and index > 0)
		self._downButton.Enable(has and index < len(self._names) - 1)

	def onSelectionChanged(self, evt):
		self._updateButtons()

	def _move(self, delta):
		index = self._listBox.GetSelection()
		if index == wx.NOT_FOUND:
			return
		target = index + delta
		if target < 0 or target >= len(self._names):
			return
		self._names[index], self._names[target] = \
			self._names[target], self._names[index]
		self._rebuild(target)
		# Focus stays on the button so the move can be repeated, which means
		# nothing announces the new position by itself.
		ui.message("%s, %d of %d"
			% (self._names[target], target + 1, len(self._names)))

	# --- adding and removing --------------------------------------------------

	def onAdd(self, evt):
		with wx.FileDialog(
			self,
			message="Select pronunciation dictionaries to add",
			wildcard="Pronunciation dictionaries (*%s)|*%s|All files (*.*)|*.*"
				% (dictfiles.EXTENSION, dictfiles.EXTENSION),
			style=wx.FD_OPEN | wx.FD_FILE_MUST_EXIST | wx.FD_MULTIPLE,
		) as dialog:
			if dialog.ShowModal() != wx.ID_OK:
				return
			chosen = dialog.GetPaths()

		added = []
		for source in chosen:
			name = self._install(source)
			if name and name.lower() not in [n.lower() for n in self._names]:
				self._names.append(name)
				added.append(name)
			elif name:
				# Already in the list: replacing the file on disk is the whole
				# of the change, and its place in the order is left alone.
				added.append(name)
		if not added:
			return
		index = [n.lower() for n in self._names].index(added[-1].lower())
		self._rebuild(index)
		ui.message("Added %s" % _count(len(added), "dictionary", "dictionaries"))

	def _install(self, source):
		"""Copy one file into the dictionary folder. Returns its name, or None.

		Copied rather than referenced where it lies, so that the folder is the
		whole answer to "which dictionaries do I have" - and so that a
		dictionary handed over on a memory stick still works next week. The
		copy is the one to edit afterwards.
		"""
		try:
			folder = dictfiles.folderPath(create=True)
		except OSError:
			log.exception("rc8650: could not create the dictionary folder")
			gui.messageBox(
				"Could not create the dictionary folder %s."
					% dictfiles.folderPath(),
				"Error", wx.OK | wx.ICON_ERROR, self)
			return None

		name = os.path.basename(source)
		destination = os.path.join(folder, name)
		if os.path.normcase(os.path.abspath(source)) == \
				os.path.normcase(os.path.abspath(destination)):
			# Adding a file that is already installed. Not an error, and not a
			# copy either - copying a file onto itself truncates it.
			return name
		if os.path.exists(destination) and gui.messageBox(
			"%s is already in the dictionary folder. Replace it?" % name,
			"Replace dictionary",
			wx.YES_NO | wx.NO_DEFAULT | wx.ICON_WARNING, self,
		) != wx.YES:
			return None
		try:
			shutil.copyfile(source, destination)
		except (OSError, shutil.Error):
			log.exception("rc8650: could not copy %s" % source)
			gui.messageBox("Could not copy %s into the dictionary folder." % name,
				"Error", wx.OK | wx.ICON_ERROR, self)
			return None
		return name

	def onRemove(self, evt):
		index = self._listBox.GetSelection()
		if index == wx.NOT_FOUND:
			return
		name = self._names[index]
		# Deleting is what removal has to mean here: the folder is scanned for
		# anything the saved order has not seen, so a file merely dropped from
		# the list would be picked straight back up. Said plainly rather than
		# hidden, which is why this confirmation names the folder.
		if gui.messageBox(
			"Remove %s?\n\nThe file will be deleted from %s." % (name, dictfiles.folderPath()),
			"Remove dictionary",
			wx.YES_NO | wx.NO_DEFAULT | wx.ICON_WARNING, self,
		) != wx.YES:
			return
		try:
			os.remove(os.path.join(dictfiles.folderPath(), name))
		except OSError:
			log.exception("rc8650: could not delete %s" % name)
			gui.messageBox("Could not delete %s." % name,
				"Error", wx.OK | wx.ICON_ERROR, self)
			return
		del self._names[index]
		self._rebuild(index)
		ui.message("Removed %s" % name)

	# --- applying -------------------------------------------------------------

	def onSave(self):
		dictfiles.setOrder(self._names)
		self._reloadSynth()

	def onReload(self, evt):
		"""Re-read the files, so editing one does not mean restarting the synth.

		The folder is re-scanned first, so this also picks up a file written
		since the panel was opened; and the order is saved first, because a user
		who presses this expects the arrangement in front of them to be the one
		that takes effect, and applying a different order from the one shown
		would be the worst of both.
		"""
		self._names = dictfiles.mergeOrder(self._names)
		self._rebuild(self._listBox.GetSelection())
		dictfiles.setOrder(self._names)
		result = self._reloadSynth()
		if result is None:
			ui.message(
				"Dictionaries will be loaded when the RC8650 "
				"synthesizer is next started.")
			return
		rules, files = result
		ui.message("Loaded %s from %s"
			% (_count(rules, "rule", "rules"),
				_count(files, "file", "files")))

	def _reloadSynth(self):
		"""Ask the running synthesizer to re-read its dictionaries.

		Returns (rules, files) - (0, 0) is a perfectly good answer, meaning the
		folder is empty - or None if this synthesizer is not the one speaking,
		which is an ordinary thing for it not to be and no reason to complain:
		the files are read when it next starts.
		"""
		synth = synthDriverHandler.getSynth()
		if synth is None or getattr(synth, "name", None) != SYNTH_NAME:
			return None
		try:
			return synth.reloadDictionaries()
		except Exception:
			log.exception("rc8650: reloading dictionaries failed")
			return None


class GlobalPlugin(globalPluginHandler.GlobalPlugin):
	def __init__(self):
		super(GlobalPlugin, self).__init__()
		# On the secure desktop there is nothing to configure and nowhere to
		# save it, and a file picker there is a hole rather than a feature.
		if globalVars.appArgs.secure:
			return
		if dictfiles is None:
			log.error("rc8650: the synth driver's dictfiles module is "
				"missing, so the dictionaries settings category is not "
				"available. Reinstall the add-on.")
			return
		dictfiles.initConfig()
		if DictionariesPanel not in NVDASettingsDialog.categoryClasses:
			NVDASettingsDialog.categoryClasses.append(DictionariesPanel)

	def terminate(self):
		try:
			NVDASettingsDialog.categoryClasses.remove(DictionariesPanel)
		except ValueError:
			pass
		super(GlobalPlugin, self).terminate()
