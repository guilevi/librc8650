# SPDX-License-Identifier: GPL-3.0-or-later
#
# "RC8650 firmware" in NVDA's Settings dialog: which firmware image the
# emulated synthesizer runs.
#
# librc8650 runs whichever RC Systems firmware it is given - the five RC8650
# v2.60 builds RCStudio ships, the RC8660 v3.44, and whatever later revision is
# dropped in - and the driver takes its voices and ranges from the image it is
# running. So switching is a matter of choosing the image and restarting the
# synthesizer on it, which is what OK does here.
#
# A global plugin for the same reason the dictionaries category is one: a
# category registered by the driver would come and go with the synthesizer.
#
# Add copies the image into <nvda config>/rc8650/firmware/, unlike the
# dictionaries panel, which references files where they lie. A dictionary is
# something the user edits; a firmware image never changes, and keeping it
# beside the configuration is what lets it survive an update of the add-on,
# which replaces the add-on's whole folder.

import os
import shutil

import wx

import globalPluginHandler
import globalVars
import synthDriverHandler
import ui
from gui import guiHelper
from gui.settingsDialogs import NVDASettingsDialog, SettingsPanel
from logHandler import log

try:
	from synthDrivers.rc8650 import firmware
except ImportError:
	firmware = None

SYNTH_NAME = "rc8650"
PANEL_DESCRIPTION_WIDTH = 544


class FirmwarePanel(SettingsPanel):
	title = "RC8650 firmware"

	panelDescription = (
		"The firmware image the RC8650 / RC8660 (emulated) synthesizer runs. "
		"Each image is RC Systems' own firmware for one chip and board model; "
		"the voices and settings follow whichever is chosen. Images are RC "
		"Systems' copyrighted code and are not included: tools/rcstudio2srec.py "
		"in librc8650 makes them from RCStudio's files."
	)

	def makeSettings(self, settingsSizer):
		sHelper = guiHelper.BoxSizerHelper(self, sizer=settingsSizer)
		description = sHelper.addItem(
			wx.StaticText(self, label=self.panelDescription))
		description.Wrap(self.scaleSize(PANEL_DESCRIPTION_WIDTH))

		self._images = []
		self._listBox = sHelper.addLabeledControl(
			"&Firmware image", wx.ListBox, choices=[])

		bHelper = guiHelper.ButtonHelper(wx.HORIZONTAL)
		self._addButton = bHelper.addButton(self, label="A&dd image...")
		self._folderButton = bHelper.addButton(self, label="Open firmware fo&lder")
		sHelper.addItem(bHelper)
		self._addButton.Bind(wx.EVT_BUTTON, self.onAdd)
		self._folderButton.Bind(wx.EVT_BUTTON, self.onOpenFolder)

		sHelper.addItem(wx.StaticText(
			self,
			label="Images are kept in %s. One placed there by hand appears "
				"here the next time this page is opened." % firmware.folderPath(),
		))
		self._refresh()

	def onPanelActivated(self):
		# A file may have been dropped into the folder since the panel was built.
		self._refresh(keep=self._selectedPath())
		super().onPanelActivated()

	def _selectedPath(self):
		index = self._listBox.GetSelection()
		if 0 <= index < len(self._images):
			return self._images[index].path
		return None

	def _refresh(self, keep=None):
		self._images = firmware.catalog()
		self._listBox.Set([image.label for image in self._images])
		want = os.path.normcase(keep or firmware.chosen() or "")
		for index, image in enumerate(self._images):
			if os.path.normcase(image.path) == want:
				self._listBox.SetSelection(index)
				return
		if self._images:
			self._listBox.SetSelection(0)

	def onAdd(self, evt):
		with wx.FileDialog(
			self,
			"Add a firmware image",
			wildcard="Firmware images (*.srec;*.srec.gz)|*.srec;*.srec.gz",
			style=wx.FD_OPEN | wx.FD_FILE_MUST_EXIST,
		) as dialog:
			if dialog.ShowModal() != wx.ID_OK:
				return
			source = dialog.GetPath()
		image = firmware.identify(source)
		if image is None:
			ui.message("%s is not an RC8650 or RC8660 firmware image"
				% os.path.basename(source))
			return
		try:
			target = os.path.join(firmware.folderPath(create=True),
				os.path.basename(source))
			if os.path.normcase(os.path.abspath(source)) != os.path.normcase(target):
				shutil.copyfile(source, target)
		except OSError:
			log.exception("rc8650: copying %s failed" % source)
			ui.message("Could not copy the image into the firmware folder")
			return
		self._refresh(keep=target)
		ui.message("Added %s" % image.label)

	def onOpenFolder(self, evt):
		try:
			os.startfile(firmware.folderPath(create=True))
		except Exception:
			log.exception("rc8650: opening the firmware folder failed")

	def onSave(self):
		path = self._selectedPath()
		if not path or os.path.normcase(path) == os.path.normcase(firmware.chosen() or ""):
			return
		firmware.choose(path)
		synth = synthDriverHandler.getSynth()
		if synth is None or getattr(synth, "name", None) != SYNTH_NAME:
			return
		# One engine per process: the running one has to go before the new
		# image can boot, and a fresh instance is also what brings the new
		# chip's voices and ranges with it.
		oldChip = getattr(synth, "chip", None)
		if not synthDriverHandler.setSynth(SYNTH_NAME):
			ui.message("The firmware could not be started; check NVDA's log")
			return
		synth = synthDriverHandler.getSynth()
		if getattr(synth, "chip", None) != oldChip:
			# A formant of 5 is the RC8650's default and the bottom of the
			# RC8660's range; settings saved for one chip mean something else
			# on the other. Start the new one from its own presets.
			try:
				synth.adoptFirmwareDefaults()
				synth.saveSettings()
			except Exception:
				log.exception("rc8650: resetting settings for the new chip failed")


class GlobalPlugin(globalPluginHandler.GlobalPlugin):
	def __init__(self):
		super(GlobalPlugin, self).__init__()
		if globalVars.appArgs.secure:
			return
		if firmware is None:
			log.error("rc8650: the synth driver's firmware module is missing, "
				"so the firmware settings category is not available. "
				"Reinstall the add-on.")
			return
		firmware.initConfig()
		if FirmwarePanel not in NVDASettingsDialog.categoryClasses:
			NVDASettingsDialog.categoryClasses.append(FirmwarePanel)

	def terminate(self):
		try:
			NVDASettingsDialog.categoryClasses.remove(FirmwarePanel)
		except ValueError:
			pass
		super(GlobalPlugin, self).terminate()
