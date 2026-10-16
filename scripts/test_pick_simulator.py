import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location(
    "pick_simulator", pathlib.Path(__file__).with_name("pick-simulator.py")
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PickSimulatorTests(unittest.TestCase):
    def test_prefers_newest_runtime_and_standard_iphone(self):
        devices = {
            "com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
                {"name": "iPhone 16", "udid": "OLD", "isAvailable": True},
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                {"name": "iPad Pro 11-inch (M5)", "udid": "PAD", "isAvailable": True},
                {"name": "iPhone 17 Pro", "udid": "PRO", "isAvailable": True},
                {"name": "iPhone 17", "udid": "STANDARD", "isAvailable": True},
                {"name": "iPhone 18", "udid": "GONE", "isAvailable": False},
            ],
            "com.apple.CoreSimulator.SimRuntime.watchOS-26-5": [
                {"name": "iPhone-ish Watch", "udid": "WATCH", "isAvailable": True},
            ],
        }
        self.assertEqual(module.pick(devices), "platform=iOS Simulator,id=STANDARD")

    def test_fails_without_iphones(self):
        with self.assertRaises(SystemExit):
            module.pick({"com.apple.CoreSimulator.SimRuntime.iOS-26-5": []})


if __name__ == "__main__":
    unittest.main()
