"""Check NVDA-style driver class creation without a DLL or firmware.

usage: test_import.py DRIVER_DIR
"""
import os
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nvdastub

driverDir = os.path.abspath(sys.argv.pop(1))


class DriverImportTests(unittest.TestCase):
	def test_duplicate_auto_property_is_rejected(self):
		with self.assertRaisesRegex(TypeError, "supportedSettings is already a class attribute"):
			class InvalidDriver(metaclass=nvdastub._AutoPropertyType):
				def _get_supportedSettings(self):
					return ()

				supportedSettings = property(_get_supportedSettings)

	def test_driver_import_and_per_instance_settings(self):
		with tempfile.TemporaryDirectory() as configPath:
			nvdastub.install(configPath)
			sys.path.insert(0, os.path.dirname(driverDir))
			import rc8650

			# Avoid starting an engine: this regression occurs during class
			# creation, before any firmware or native code is used.
			first = rc8650.SynthDriver.__new__(rc8650.SynthDriver)
			second = rc8650.SynthDriver.__new__(rc8650.SynthDriver)
			first._settings = (object(),)
			second._settings = (object(), object())
			self.assertIs(first.supportedSettings, first._settings)
			self.assertIs(second.supportedSettings, second._settings)


if __name__ == "__main__":
	unittest.main()
