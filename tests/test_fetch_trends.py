import importlib.util
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = REPO_ROOT / "scripts" / "fetch_trends.py"
SPEC = importlib.util.spec_from_file_location("fetch_trends", MODULE_PATH)
FETCH_TRENDS = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(FETCH_TRENDS)


class FetchTrendsTest(unittest.TestCase):
    def test_refresh_counts_only_successful_regions(self):
        responses = {
            "US": (["one", "two"], ""),
            "JP": ([], ""),
        }
        updated = []

        with mock.patch.object(
            FETCH_TRENDS,
            "fetch_trends",
            side_effect=lambda region: responses[region],
        ), mock.patch.object(
            FETCH_TRENDS,
            "update_file",
            side_effect=lambda region, words, fallback: updated.append((region, words)),
        ):
            count = FETCH_TRENDS.refresh_regions(["US", "JP"], sleep_fn=lambda _: None)

        self.assertEqual(count, 1)
        self.assertEqual(updated, [("US", ["one", "two"])])

    def test_update_keeps_new_words_first_and_removes_duplicates(self):
        file_mock = mock.mock_open(read_data="old\nduplicate\n")
        with mock.patch("builtins.open", file_mock), mock.patch(
            "os.path.exists", return_value=True
        ), mock.patch("os.makedirs"):
            FETCH_TRENDS.update_file("US", ["new", "duplicate"])

        file_mock().write.assert_called_once_with("new\nduplicate\nold\n")


if __name__ == "__main__":
    unittest.main()
