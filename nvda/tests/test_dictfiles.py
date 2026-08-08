"""Exercise dictfiles.py outside NVDA, with the modules it imports stubbed.

The interesting behaviour is all in mergeOrder: what happens when the configured
order and the folder disagree. That is worth a test because every one of those
disagreements is a real situation - a file deleted by hand, a file dropped in by
hand, a config written under a different spelling on a case-insensitive
filesystem.

usage: test_dictfiles.py DRIVER_DIR
"""
import os
import sys
import tempfile

# The driver package is imported from the tree itself, so do not scatter
# __pycache__ directories through it - they would end up in the add-on.
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import nvdastub  # noqa: E402

configPath = tempfile.mkdtemp()
nvda = nvdastub.install(configPath)

sys.path.insert(0, os.path.abspath(sys.argv[1]))
import dictfiles  # noqa: E402

failures = []


def check(name, got, want):
	if got != want:
		failures.append("%s\n  got  %r\n  want %r" % (name, got, want))
		print("FAIL %s" % name)
	else:
		print("ok   %s" % name)


def setOrder(names):
	# Written straight into the stub config: the point here is dictfiles' own
	# merge, not NVDA's configobj validation.
	nvda.config.conf.setdefault(dictfiles.CONFIG_SECTION, {})["dictionaries"] = list(names)


folder = dictfiles.folderPath(create=True)


def touch(name):
	open(os.path.join(folder, name), "w").close()


# No configuration at all: sorted folder order, which is what the add-on did
# before the order was configurable, and what a user who never opens the
# settings panel goes on getting.
touch("50-shared.dict")
touch("00-mine.dict")
touch("notes.txt")
check("unconfigured: sorted, non-.dict ignored",
	dictfiles.orderedNames(), ["00-mine.dict", "50-shared.dict"])

# A configured order wins, even against sorting. This is the whole point of the
# panel: rules are first-match-wins in load order, so the order IS the priority.
setOrder(["50-shared.dict", "00-mine.dict"])
check("configured order wins",
	dictfiles.orderedNames(), ["50-shared.dict", "00-mine.dict"])

# A file dropped into the folder by hand is appended, not lost.
touch("zz-new.dict")
touch("aa-new.dict")
check("unlisted files appended in sorted order",
	dictfiles.orderedNames(),
	["50-shared.dict", "00-mine.dict", "aa-new.dict", "zz-new.dict"])

# A file named in the configuration but no longer there simply drops out.
setOrder(["gone.dict", "00-mine.dict", "50-shared.dict"])
check("missing files drop out",
	dictfiles.orderedNames(),
	["00-mine.dict", "50-shared.dict", "aa-new.dict", "zz-new.dict"])

# Case: the config may hold whatever spelling the file was added under, but the
# folder is the authority on the real name.
setOrder(["00-MINE.DICT", "50-Shared.Dict"])
check("case-insensitive match, folder spelling returned",
	dictfiles.orderedNames()[:2], ["00-mine.dict", "50-shared.dict"])

# A duplicated entry collapses onto the first, which is the one that would have
# won anyway.
setOrder(["zz-new.dict", "zz-new.dict", "00-mine.dict"])
check("duplicates collapse",
	dictfiles.orderedNames(),
	["zz-new.dict", "00-mine.dict", "50-shared.dict", "aa-new.dict"])

# Full paths are matched by basename, so a config written by some earlier idea
# of this still resolves.
setOrder([os.path.join("C:\\somewhere", "50-shared.dict"), "00-mine.dict"])
check("full paths matched by basename",
	dictfiles.orderedNames()[:2], ["50-shared.dict", "00-mine.dict"])

# mergeOrder is what the settings panel calls to re-sync a list it is holding
# without discarding an arrangement the user has not applied yet.
check("mergeOrder keeps a working order and appends the rest",
	dictfiles.mergeOrder(["aa-new.dict"]),
	["aa-new.dict", "00-mine.dict", "50-shared.dict", "zz-new.dict"])

# No folder at all: not an error, and the commonest state there is.
nvda.globalVars.appArgs.configPath = tempfile.mkdtemp()
check("no folder yet", dictfiles.orderedNames(), [])
check("no folder yet, paths", dictfiles.orderedPaths(), [])

print()
if failures:
	print("\n".join(failures))
	print("%d failures" % len(failures))
	sys.exit(1)
print("0 failures")
