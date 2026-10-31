"""The firmware catalog, and the real driver on each image it lists.

usage: test_firmware.py DRIVER_DIR SHARED_LIBRARY IMAGE [IMAGE ...]

The catalog is checked in this process. Each image then gets a process of its
own, because librc8650's emulator core allows one engine per process and the
stub cannot unload the library between them - which is also how NVDA itself
switches firmware: the old driver instance goes, a new one boots the new image.

Run it through run.sh.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import nvdastub  # noqa: E402

failures = []


def check(name, condition, detail=""):
	if condition:
		print("ok   %s" % name)
	else:
		failures.append("%s %s" % (name, detail))
		print("FAIL %s %s" % (name, detail))


def stage(driverDir, dylib, configPath, images, besideDriver=()):
	"""A copy of the driver package with the host library as its DLL, and the
	given images in the firmware folder (or beside the driver)."""
	staging = tempfile.mkdtemp()
	package = os.path.join(staging, "rc8650")
	shutil.copytree(driverDir, package)
	shutil.copyfile(dylib, os.path.join(package, "rc8650_64.dll"))
	folder = os.path.join(configPath, "rc8650", "firmware")
	os.makedirs(folder, exist_ok=True)
	for image in images:
		shutil.copyfile(image, os.path.join(folder, os.path.basename(image)))
	for image, name in besideDriver:
		shutil.copyfile(image, os.path.join(package, name))
	sys.path.insert(0, staging)
	return package


def one(driverDir, dylib, image):
	"""Boot the driver on one image and check it took that image's shape."""
	configPath = tempfile.mkdtemp()
	nvda = nvdastub.install(configPath)
	stage(driverDir, dylib, configPath, [image])
	nvda.config.conf["rc8650"] = {"firmware": os.path.basename(image)}
	import rc8650  # noqa: E402
	from rc8650 import firmware

	info = firmware.identify(image)
	name = os.path.basename(image)
	driver = rc8650.SynthDriver()
	settings = dict((s.id, s) for s in driver.supportedSettings)
	voices = driver._getAvailableVoices()
	chip = driver.chip
	print("     %s: RC%d, %d voices (%s ... %s), formant 0-%d, %d rate steps of %d%%"
		% (name, chip, len(voices), voices["0"].displayName,
			voices[str(len(voices) - 1)].displayName,
			settings["formant"].maxVal, len(driver._RATE_LADDER), driver._rateStep))

	check("%s: the driver runs the chosen image" % name,
		os.path.basename(driver._rc.firmwarePath) == name, driver._rc.firmwarePath)
	check("%s: chip matches the image header" % name,
		"RC%d" % chip == info.chip, "%s vs %s" % (chip, info.chip))
	if chip == 8650:
		check("%s: eight voices, Perfect Paul to Robo Robert" % name,
			len(voices) == 8 and voices["7"].displayName == "Robo Robert")
		check("%s: formant 0-9, default 5" % name,
			settings["formant"].maxVal == 9 and settings["formant"].defaultVal == 5)
		check("%s: twenty rate rungs in 5%% steps" % name,
			len(driver._RATE_LADDER) == 20 and driver._rateStep == 5)
		check("%s: Skip's preset formant is 9" % name, driver._voicePresets["6"][2] == 9)
	elif chip == 8660:
		check("%s: eleven voices, up to Gretchen" % name,
			len(voices) == 11 and voices["10"].displayName == "Gretchen")
		check("%s: formant 0-99, default 50" % name,
			settings["formant"].maxVal == 99 and settings["formant"].defaultVal == 50)
		check("%s: fourteen rate rungs, all on the V86 scale" % name,
			len(driver._RATE_LADDER) == 14
			and all(por == 0x80 for por, _ in driver._RATE_LADDER))
	# The power-on rung is where the slider starts, and it maps back to itself.
	check("%s: default rate maps to the chip's own power-on rung" % name,
		driver._mapRate(driver._RATE_DEFAULT)
		== driver._RATE_LADDER[driver._rc.profile.rate_default])
	# Every slider position maps to a rung, top and bottom included.
	check("%s: rate slider covers the ladder end to end" % name,
		driver._mapRate(0) == driver._RATE_LADDER[0]
		and driver._mapRate(100) == driver._RATE_LADDER[-1])

	# The last voice, at the top of the formant range: the commands a switch
	# of chip makes possible.
	last = str(len(voices) - 1)
	driver._voice = last
	driver._applyPreset(last)
	driver._formant = settings["formant"].maxVal
	prefix = driver._prefix()
	check("%s: prefix selects voice %s and formant %d" % (name, last, driver._formant),
		("\x01%sO" % last) in prefix and ("\x01%dF" % driver._formant) in prefix
		or driver._formant == driver._voicePresets[last][2], repr(prefix))

	# And it speaks, through the real synthesis thread.
	done = nvda.synthDriverHandler.synthDoneSpeaking
	before = len(done.notified)
	driver.speak(["Hello from the", nvda.commands.IndexCommand(1), "emulated chip."])
	deadline = time.time() + 60
	while len(done.notified) == before and time.time() < deadline:
		time.sleep(0.05)
	fed = len(driver._player.fed) // 2
	reached = [n["index"] for n in nvda.synthDriverHandler.synthIndexReached.notified]
	check("%s: speaks (%d samples) and reports its index" % (name, fed),
		fed > 5000 and 1 in reached, "fed %d, indexes %r" % (fed, reached))

	# Every voice, through the driver's own prefix, sounds like itself. The
	# prefix used to send 129G, which clears the RC8660's R50 bit and makes it
	# an RC8650 - where nO wraps voices 8-10 onto 0-2, so Alvin spoke as Vader.
	# Comparing audio rather than the prefix is what catches that.
	por = int(prefix.split("\x01")[1].rstrip("G"))
	check("%s: nG keeps the power-on R50 bit (%dG, power-on %d)"
		% (name, por, driver._rc.profile.por_default),
		por & 0x10 == driver._rc.profile.por_default & 0x10, repr(prefix))
	heard = {}
	for v in sorted(voices, key=int):
		driver._voice = v
		driver._applyPreset(v)
		start = len(driver._player.fed)
		before = len(done.notified)
		driver.speak(["The quick brown fox."])
		deadline = time.time() + 60
		while len(done.notified) == before and time.time() < deadline:
			time.sleep(0.05)
		heard.setdefault(bytes(driver._player.fed[start:]), []).append(voices[v].displayName)
	same = [names for names in heard.values() if len(names) > 1]
	check("%s: all %d voices sound different" % (name, len(voices)),
		not same, "identical audio: %r" % same)

	# Each resampling: the player follows the output rate, and every D/A
	# sample becomes output_rate / D/A rate output samples - the nominal
	# rate for the staircase, a BookPort's faster one for that. Measured
	# against the chip's own sample count, since the same sentence twice
	# need not come out the same length.
	ratios = {}
	driver._player.fed.clear()
	lib, h = driver._rc.lib, driver._rc.handle
	for mode, rate, dac in (("staircase", 48000, 10017), ("bookport", 48000, 10486),
			("smooth", 10017, 10017)):
		driver._set_resampling(mode)
		before = len(done.notified)
		startDac = lib.rc8650_samples_read(h)
		driver.speak(["One two three."])
		deadline = time.time() + 60
		while len(done.notified) == before and time.time() < deadline:
			time.sleep(0.05)
		player = driver._player
		dacSamples = lib.rc8650_samples_read(h) - startDac
		out = len(player.fed) // 2
		player.fed.clear()
		ratios[mode] = out / float(max(dacSamples, 1))
		check("%s: %s resampling plays at %d Hz, %.4f samples per D/A sample"
			% (name, mode, rate, ratios[mode]),
			player.samplesPerSec == rate and dacSamples > 5000
			and abs(ratios[mode] / (rate / float(dac)) - 1) < 0.002,
			"%r Hz, %d D/A samples, %d out" % (player.samplesPerSec, dacSamples, out))

	driver.adoptFirmwareDefaults()
	check("%s: adoptFirmwareDefaults starts from the voice's preset" % name,
		driver._formant == driver._voicePresets[driver._voice][2]
		and driver._rate == driver._RATE_DEFAULT)
	driver.terminate()


def catalogChecks(driverDir, dylib, images):
	configPath = tempfile.mkdtemp()
	nvda = nvdastub.install(configPath)
	# One image under the add-on's old fixed name beside the driver, the rest
	# in the firmware folder, one of them gzipped.
	import gzip
	inFolder = list(images[1:])
	gz = None
	if inFolder:
		gz = os.path.join(tempfile.mkdtemp(), os.path.basename(inFolder[-1]) + ".gz")
		with open(inFolder[-1], "rb") as src, gzip.open(gz, "wb") as dst:
			dst.write(src.read())
		inFolder[-1] = gz
	package = stage(driverDir, dylib, configPath, inFolder,
		besideDriver=[(images[0], "rc8650_m4_valid.srec")])
	open(os.path.join(configPath, "rc8650", "firmware", "notes.srec"), "w").write("S0030000FC\n")
	from rc8650 import firmware

	listed = firmware.catalog()
	print("     catalog: " + "; ".join(image.label for image in listed))
	check("catalog: every image found once, the stray file skipped",
		len(listed) == len(images), [i.name for i in listed])
	check("catalog: the firmware folder comes first",
		not inFolder or os.path.dirname(listed[0].path) == firmware.folderPath())
	if gz:
		check("catalog: a .srec.gz is read through",
			any(i.name.endswith(".gz") for i in listed))
	check("nothing chosen: the add-on's old file name is preferred",
		os.path.basename(firmware.chosen()) == "rc8650_m4_valid.srec")
	nvda.config.conf["rc8650"] = {}
	if inFolder:
		firmware.choose(listed[0].path)
		check("choose: stored by name for an image in the folder",
			nvda.config.conf["rc8650"]["firmware"] == listed[0].name)
		check("chosen: the configured image", firmware.chosen() == listed[0].path)
	nvda.config.conf["rc8650"]["firmware"] = "deleted.srec"
	check("a chosen image that has gone falls back rather than failing",
		firmware.chosen() is not None)


def main():
	if sys.argv[1] == "--one":
		one(*sys.argv[2:5])
	else:
		driverDir, dylib = sys.argv[1:3]
		images = sys.argv[3:]
		catalogChecks(driverDir, dylib, images)
		for image in images:
			result = subprocess.run(
				[sys.executable, os.path.abspath(__file__), "--one",
					driverDir, dylib, image])
			if result.returncode:
				failures.append("%s (exit %d)" % (os.path.basename(image), result.returncode))
	if failures:
		print("%d failure(s)" % len(failures))
		sys.exit(1)
	print("0 failures")


if __name__ == "__main__":
	main()
