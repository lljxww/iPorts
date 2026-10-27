import importlib.util
import plistlib
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "release.py"
SPEC = importlib.util.spec_from_file_location("release", SCRIPT)
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class ReleaseVersionTests(unittest.TestCase):
    def test_accepts_stable_tags_and_preserves_the_requested_version(self):
        for version in ("0.8.0", "1.2.3", "10.20.30", "9999.99.99"):
            with self.subTest(version=version):
                self.assertEqual(release.version_from_tag("v" + version), version)

    def test_rejects_ambiguous_tags_prereleases_and_invalid_bundle_versions(self):
        for tag in (
            "1.2.3", "v1.2", "v01.2.3", "v1.02.3", "v1.2.03", "v-1.2.3",
            "v1.2.3-beta.1", "v1.2.3+build", "v1.2.3\n", "v1.2.3/other",
            "v10000.0.0", "v1.100.0", "v1.0.100", "v1.2.3;echo unsafe",
        ):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.version_from_tag(tag)

    def test_an_older_or_repeated_release_cannot_replace_latest(self):
        self.assertTrue(release.should_be_latest("v0.8.0", ""))
        self.assertTrue(release.should_be_latest("v0.10.0", "v0.9.9"))
        self.assertTrue(release.should_be_latest("v1.0.0", "v0.99.99"))
        self.assertFalse(release.should_be_latest("v0.8.0", "v0.10.0"))
        self.assertFalse(release.should_be_latest("v0.8.0", "v0.8.0"))

    def test_stamps_both_versions_and_preserves_update_configuration(self):
        with tempfile.TemporaryDirectory() as temporary:
            plist_path = Path(temporary) / "Info.plist"
            original = {"CFBundleVersion": "8", "SUFeedURL": "https://example.com/appcast.xml"}
            plist_path.write_bytes(plistlib.dumps(original))
            release.set_version(plist_path, "1.2.3")
            actual = plistlib.loads(plist_path.read_bytes())
            self.assertEqual(actual["CFBundleVersion"], "1.2.3")
            self.assertEqual(actual["CFBundleShortVersionString"], "1.2.3")
            self.assertEqual(actual["SUFeedURL"], original["SUFeedURL"])

    def test_invalid_version_does_not_modify_the_application_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            plist_path = Path(temporary) / "Info.plist"
            original = plistlib.dumps({"CFBundleVersion": "0.8.0"})
            plist_path.write_bytes(original)
            with self.assertRaises(ValueError):
                release.set_version(plist_path, "1.2.3-beta")
            self.assertEqual(plist_path.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
