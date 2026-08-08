"""Drive the real rc8650 NVDA driver against the real emulator.

Same job as the doubletalk-pc tests: the refactor of _loadDictionaries into
"build the new one, attach it, then free the old" is the sort of change that
looks right and leaves the engine holding nothing, so it is checked by
speaking.

usage: test_dictionaries.py DRIVER_DIR SHARED_LIBRARY FIRMWARE

Run it through run.sh, which finds all three.
"""
import ctypes
import os
import shutil
import sys
import tempfile

# The driver package is imported from the tree itself, so do not scatter
# __pycache__ directories through it - they would end up in the add-on.
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import nvdastub  # noqa: E402

driverDir, dylib, firmware = sys.argv[1:4]

configPath = tempfile.mkdtemp()
dictFolder = os.path.join(configPath, "rc8650")
os.makedirs(dictFolder)

nvda = nvdastub.install(configPath)

staging = tempfile.mkdtemp()
package = os.path.join(staging, "rc8650")
shutil.copytree(driverDir, package)
shutil.copyfile(firmware, os.path.join(package, "rc8650_m4_valid.srec"))
shutil.copyfile(dylib, os.path.join(package, "rc8650_64.dll"))
sys.path.insert(0, staging)

import rc8650  # noqa: E402

failures = []


def check(name, condition, detail=""):
	if condition:
		print("ok   %s" % name)
	else:
		failures.append("%s %s" % (name, detail))
		print("FAIL %s %s" % (name, detail))


def quiesce(driver):
	"""Stop the synthesis thread so the test owns the queue.

	The driver starts a daemon thread that blocks on _queue.get(), so a test
	that inspects what speak() queued is racing it - and losing that race means
	the emulator renders the whole utterance, which for the split test below is
	minutes of speech nobody is listening to. A None on the queue is the
	driver's own way of telling the thread to return.
	"""
	driver._queue.put(None)
	driver._thread.join(timeout=5)
	assert not driver._thread.is_alive(), "synthesis thread did not stop"
	return driver


def render(driver, sequence):
	"""speak() and return the pieces it queued, joined."""
	driver.speak(sequence)
	pieces, marks, generation = driver._queue.get_nowait()
	return b"".join(pieces)


def writeDict(name, body):
	with open(os.path.join(dictFolder, name), "w") as f:
		f.write(body)


IndexCommand = nvda.commands.IndexCommand

# ONE driver for the whole file. librc8650's emulator core keeps file-scope
# state and refuses a second engine per process; the driver copes by unloading
# the DLL on terminate, which cannot happen here because FreeLibrary is a stub.
# So everything below reloads dictionaries under a single instance, which is
# also the path the settings panel uses.

# --- nothing loaded ---------------------------------------------------------

driver = quiesce(rc8650.SynthDriver())
plain = render(driver, ["I use NVDA."])
check("no dictionary: text passes through", b"I use NVDA." in plain, repr(plain))
check("no dictionary: nothing loaded", driver._dict is None)

# --- one dictionary ---------------------------------------------------------

writeDict("50-shared.dict", "#!rcdict 1\n#!case insensitive\nword\t\tNVDA\tenn vee dee ay\n")
check("reload picks up a new file", driver.reloadDictionaries() is not None)
check("dictionary loaded", driver._dict is not None)
spoken = render(driver, ["I use NVDA."])
check("substitution happens in speak()", b"enn vee dee ay" in spoken, repr(spoken))
check("prefix intact", spoken.startswith(b"\x01"), repr(spoken[:12]))

withIndex = render(driver, ["I use ", IndexCommand(7), "NVDA."])
check("index marker survives", b"I" in withIndex and b"enn vee dee ay" in withIndex,
	repr(withIndex))

# --- expand happens BEFORE split -------------------------------------------
#
# The rule the whole design rests on. A word that expands well past its own
# length, repeated until the result crosses MAX_UTTERANCE_BYTES, must produce
# pieces that are all within the limit - which is only true if _split measured
# the expanded text.

writeDict("00-long.dict",
	"#!rcdict 1\n#!case insensitive\nword\t\tzz\t" + ("very " * 12) + "long\n")
driver.reloadDictionaries()
driver.speak([" ".join(["zz"] * 60)])
pieces, marks, generation = driver._queue.get_nowait()
check("expanded text is split into several pieces", len(pieces) > 1, len(pieces))
check("every piece is within the chip's limit",
	all(len(p) <= rc8650.MAX_UTTERANCE_BYTES for p in pieces),
	max(len(p) for p in pieces))
check("the expansion actually happened",
	all(b"zz" not in p for p in pieces), repr(pieces[0][:80]))

# --- ordering ---------------------------------------------------------------

writeDict("00-long.dict", "#!rcdict 1\n#!case insensitive\nword\t\tNVDA\tmy own version\n")
result = driver.reloadDictionaries()
check("reload reports counts", result is not None and result[1] == 2, repr(result))
spoken = render(driver, ["I use NVDA."])
check("first file in load order wins", b"my own version" in spoken, repr(spoken))

# --- the chip really says something else ------------------------------------


def samples(driver, sequence):
	driver.speak(sequence)
	pieces, marks, generation = driver._queue.get_nowait()
	lib, h = driver._rc.lib, driver._rc.handle
	buf = ctypes.create_string_buffer(1024 * 2)
	buf16 = ctypes.cast(buf, ctypes.POINTER(ctypes.c_int16))
	out = bytearray()
	for piece in pieces:
		lib.rc8650_write(h, piece, len(piece))
		lib.rc8650_write(h, b"\x00", 1)
		while True:
			n = lib.rc8650_read_s16(h, buf16, 1024, None)
			if n == 0:
				break
			out.extend(buf.raw[:n * 2])
	return bytes(out)


writeDict("00-long.dict", "#!rcdict 1\n#!case insensitive\nword\t\tNVDA\t[EH N V IY D IY EY]\n")
os.remove(os.path.join(dictFolder, "50-shared.dict"))
driver.reloadDictionaries()
spoken = render(driver, ["I use NVDA."])
check("phoneme span is wrapped in the mode switches",
	b"\x01D" in spoken and b"\x01T" in spoken, repr(spoken))
withDict = samples(driver, ["I use NVDA."])

# Reloading with the folder empty must DETACH, not leave the old rules in place
# - which is the part of the free-the-old-one-after ordering that could go
# wrong silently.
os.remove(os.path.join(dictFolder, "00-long.dict"))
check("reload with nothing left reports zero", driver.reloadDictionaries() == (0, 0))
check("dictionary detached", driver._dict is None)
without = samples(driver, ["I use NVDA."])
driver.terminate()

check("the chip really speaks something different",
	len(withDict) > 1000 and len(without) > 1000 and withDict != without,
	"%d vs %d samples" % (len(withDict) // 2, len(without) // 2))

print()
if failures:
	print("%d failures" % len(failures))
	sys.exit(1)
print("0 failures")
