import importlib.util
import pathlib
import plistlib
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location(
    "validate_ipa", pathlib.Path(__file__).with_name("validate-ipa.py")
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class IPAValidationTests(unittest.TestCase):
    def fixture(self, directory, **overrides):
        info = {
            "CFBundleIdentifier": "com.mbbooks.MBBooks",
            "CFBundleExecutable": "MBBooks",
            "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "UIDeviceFamily": [1, 2],
            "CFBundleShortVersionString": "0.2.0",
            "CFBundleVersion": "42",
        }
        info.update(overrides)
        path = pathlib.Path(directory) / "book.ipa"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("Payload/MBBooks.app/Info.plist", plistlib.dumps(info))
            archive.writestr("Payload/MBBooks.app/MBBooks", b"fixture executable")
        return path

    def test_valid_device_bundle_and_embedded_versions(self):
        with tempfile.TemporaryDirectory() as directory:
            module.validate(self.fixture(directory), "0.2.0", "42")

    def test_rejects_simulator_and_unexpected_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            for override in (
                {"CFBundleSupportedPlatforms": ["iPhoneSimulator"]},
                {"CFBundleIdentifier": "other.app"},
                {"UIDeviceFamily": [1]},
            ):
                with self.subTest(override=override), self.assertRaises(AssertionError):
                    module.validate(self.fixture(directory, **override))

    def test_rejects_wrong_marketing_version_and_build_number(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self.fixture(directory)
            for version, build in [("0.3.0", "42"), ("0.2.0", "43")]:
                with self.subTest(version=version, build=build), self.assertRaises(AssertionError):
                    module.validate(path, version, build)


if __name__ == "__main__":
    unittest.main()
