"""Inspect the IPA without extracting or executing its contents."""
import json
import plistlib
import sys
import zipfile

APP = "Payload/MBBooks.app/"
# The reader cannot render books without these bundled scripts.
REQUIRED_RESOURCES = ("reader.js", "epub-reading-system.js", "frame.js", "Assets.car")


def validate(path, expected_version=None, expected_build=None):
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            raise ValueError("IPA has a corrupt ZIP entry")
        info = plistlib.loads(archive.read("Payload/MBBooks.app/Info.plist"))
        assert info["CFBundleIdentifier"] == "com.mbbooks.MBBooks", "Wrong bundle ID"
        assert info["CFBundleExecutable"] == "MBBooks", "Wrong executable"
        assert info["CFBundleSupportedPlatforms"] == ["iPhoneOS"], "Not a device build"
        assert set(info["UIDeviceFamily"]) == {1, 2}, "Expected iPhone and iPad support"
        assert archive.getinfo("Payload/MBBooks.app/MBBooks").file_size > 0, "Missing executable"
        names = set(archive.namelist())
        for resource in REQUIRED_RESOURCES:
            assert APP + resource in names, f"Missing {resource}"
        types = {item for document in info.get("CFBundleDocumentTypes", [])
                 for item in document.get("LSItemContentTypes", [])}
        assert "org.idpf.epub-container" in types, "EPUB files must open in the app"
        assert info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon"), "Missing app icon"
        if expected_version:
            assert info["CFBundleShortVersionString"] == expected_version, "Wrong marketing version"
        if expected_build:
            assert info["CFBundleVersion"] == expected_build, "Wrong build number"
        return info


if __name__ == "__main__":
    result = validate(*sys.argv[1:])
    print(json.dumps({key: result[key] for key in (
        "CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"
    )}, indent=2))
